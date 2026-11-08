//
//  ArrivalCard.swift
//  GamesRoom
//
//  V0.85 — host-only arrival card at session start (migration
//  085). The seat deposit reframes the V0.84 C3 no-show tax: a
//  deposit needs only a reclaim, so the card asks about held
//  deposits whose members never tapped "I'm here".
//
//  Rendered in `RoomDetailView.scrollBody` when the room is
//  live (active event whose `playedAt <= now`, not settled),
//  `room.seatDepositTrigger == .escrow`, the caller is the
//  host, and the candidate list is non-empty. One row per
//  unresolved candidate; the host decides per row in
//  isolation. The substrate line is "the host always decides;
//  the system never decides alone" (Carnegie 3.1 — don't
//  argue; 4.5 — save face).
//
//  The copy is the mascot's, never a neutral system message.
//  `ArrivalPromptVoice.promptLine(mascotName:displayName:
//  depositAmount:)` is the source of truth for the header text
//  (per the locked directive "the mascot is the only system
//  voice").
//
//  S3.7 — the card waits for the grace window. Before the
//  window closes the host gets one grey line ("Arrivals open
//  at 7:40pm") and no rows at all: a member who is two
//  minutes late is parking, not a no-show. Inside the window
//  each row offers two plain text actions: a grey "Give it
//  back" (the deposit goes back — the default, and the answer
//  most of the time) and a red "Keep" (the deposit is
//  forfeited, so it asks first: "Keep Sam's 200 CC?").
//
//  The old row had a filled "Forfeit" button (one tap, no
//  confirmation, no undo) plus "Skip: texted" and "Skip:
//  away", which both did the same thing on the server. Now
//  there is one action per row that gives the deposit back
//  and one that burns it behind a confirmation.
//
//  Give it back calls `roomService.waiveSeatDeposit(...)`;
//  Keep calls `roomService.forfeitSeatDeposit(...)`. Both
//  remove the row from the service's cached candidate list
//  so the next render omits it. Errors surface via the
//  existing `seatActionError` alert pattern.
//

import SwiftUI

struct ArrivalCard: View {
    let room: Room
    let event: Event
    let candidates: [SeatDepositCandidate]
    /// S3.7 — the safe answer: the deposit goes back to the member.
    let onGiveBack: (SeatDepositCandidate) async -> Void
    /// S3.7 — the deposit is burned, so the row asks first.
    let onKeep: (SeatDepositCandidate) async -> Void
    /// S3.7 — the candidate the host is about to keep the
    /// deposit of. `nil` means no confirmation is up.
    @State private var pendingKeep: SeatDepositCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            // v1.2.4 S4.4 — one card shape. The title-size icon+text
            // header is now the app's `SectionTitle`, and the grey
            // explainer is no longer printed on the card: it rides the
            // header's accessibility hint instead, so sighted hosts
            // read the card and VoiceOver hosts get the same line.
            SectionTitle(text: "Arrivals")
                .accessibilityHint("Held deposits waiting on a check-in. You decide what comes back.")
            VStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                    if candidate.id != candidates.last?.id {
                        Divider()
                            .overlay(Theme.Palette.hairline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            keepDialogTitle,
            isPresented: Binding(
                get: { pendingKeep != nil },
                set: { if !$0 { pendingKeep = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Keep", role: .destructive) {
                guard let candidate = pendingKeep else { return }
                pendingKeep = nil
                Task { await onKeep(candidate) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// S3.7 — "Keep Sam's 200 CC?" The amount and the name come
    /// from the candidate row, so the host is confirming the
    /// exact deposit they are about to burn.
    private var keepDialogTitle: String {
        guard let candidate = pendingKeep else { return "Keep the deposit?" }
        return "Keep \(candidate.displayName)'s \(candidate.depositAmount) CC?"
    }

    @ViewBuilder
    private func candidateRow(_ candidate: SeatDepositCandidate) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            Text(
                ArrivalPromptVoice.promptLine(
                    mascotName: room.mascotName,
                    displayName: candidate.displayName,
                    depositAmount: candidate.depositAmount
                )
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.primaryText)
            HStack(spacing: Theme.Layout.cardLineGap) {
                Button {
                    Task { await onGiveBack(candidate) }
                } label: {
                    Text("Give it back")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Give back \(candidate.displayName)'s \(candidate.depositAmount) CC deposit"))
                Spacer(minLength: 8)
                Button {
                    pendingKeep = candidate
                } label: {
                    Text("Keep")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.loss)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Keep \(candidate.displayName)'s \(candidate.depositAmount) CC deposit"))
            }
        }
        // v1.2.4 S4.4 — the row's own 16pt inset is gone: the card
        // insets its content by 16 already, so the row text used to
        // sit 32pt in from the card edge while every other card sits
        // at 16.
    }
}

// MARK: - ArrivalGrace
//
//  S3.7 — when the arrival card opens.
//
//  The server stamps every arrival candidate with `within_grace`
//  (`now() < played_at + grace minutes`), so the room can ask the
//  server whether the window is still open. The candidate list is
//  cached and loaded when the room page opens, so a row can still
//  say "in grace" long after the window closed: our own clock is
//  the second half of the gate, and the card opens as soon as
//  either half says so.
//
//  The window runs from the night's start time for the room's
//  grace minutes (`rooms.seat_deposit_grace_minutes`, copied onto
//  the event when it is created).
//
enum ArrivalGrace {
    /// The moment the grace window closes.
    static func opensAt(playedAt: Date, graceMinutes: Int) -> Date {
        playedAt.addingTimeInterval(Double(max(0, graceMinutes)) * 60)
    }

    /// True once the host may decide: the server says the window
    /// has passed, or our own clock says it has (a stale row).
    static func isOpen(
        candidates: [SeatDepositCandidate],
        playedAt: Date,
        graceMinutes: Int,
        now: Date = Date()
    ) -> Bool {
        if !candidates.contains(where: \.withinGrace) { return true }
        return now >= opensAt(playedAt: playedAt, graceMinutes: graceMinutes)
    }

    /// "Arrivals open at 7:40pm" — the quiet stand-in for the
    /// card while the window is still open.
    static func caption(playedAt: Date, graceMinutes: Int) -> String {
        "Arrivals open at \(clockTime(opensAt(playedAt: playedAt, graceMinutes: graceMinutes)))"
    }

    /// "7:40pm" — 12-hour clock, lower-case meridiem, no space
    /// before it. The same shape as the rooms list's "Fri 7:30pm".
    static func clockTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        let hour12 = hour % 12 == 0 ? 12 : hour % 12
        let meridiem = hour < 12 ? "am" : "pm"
        let minuteText = minute < 10 ? "0\(minute)" : "\(minute)"
        return "\(hour12):\(minuteText)\(meridiem)"
    }
}
