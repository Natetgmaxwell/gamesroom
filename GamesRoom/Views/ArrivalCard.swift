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
//  unresolved candidate; the host decides Forfeit / Skip
//  (texted) / Skip (away) per row in isolation. The substrate
//  line is "the host always decides; the system never decides
//  alone" (Carnegie 3.1 — don't argue; 4.5 — save face).
//
//  The copy is the mascot's, never a neutral system message.
//  `ArrivalPromptVoice.promptLine(mascotName:displayName:
//  depositAmount:)` is the source of truth for the header text
//  (per the locked directive "the mascot is the only system
//  voice").
//
//  Forfeit calls `roomService.forfeitSeatDeposit(eventId:
//  memberId:)`; Skip calls `roomService.waiveSeatDeposit(...)`.
//  Both remove the row from the service's cached candidate list
//  so the next render omits it. Errors surface via the existing
//  `seatActionError` alert pattern.
//

import SwiftUI

struct ArrivalCard: View {
    let room: Room
    let event: Event
    let candidates: [SeatDepositCandidate]
    let onForfeit: (SeatDepositCandidate) async -> Void
    let onSkipTexted: (SeatDepositCandidate) async -> Void
    let onSkipAway: (SeatDepositCandidate) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 8) {
                Image(systemName: Theme.Icon.handRaisedFill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Arrivals")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
            Text("Held deposits waiting on a check-in. You decide what comes back.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            VStack(spacing: 0) {
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                    if candidate.id != candidates.last?.id {
                        Divider()
                            .overlay(Theme.Palette.hairline)
                    }
                }
            }
            .background(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func candidateRow(_ candidate: SeatDepositCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                ArrivalPromptVoice.promptLine(
                    mascotName: room.mascotName,
                    displayName: candidate.displayName,
                    depositAmount: candidate.depositAmount
                )
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.primaryText)
            HStack(spacing: 8) {
                Button {
                    Task { await onForfeit(candidate) }
                } label: {
                    Text("Forfeit")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Theme.Palette.accent)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Forfeit \(candidate.displayName)'s \(candidate.depositAmount) CC seat deposit"))
                Button {
                    Task { await onSkipTexted(candidate) }
                } label: {
                    Text("Skip — texted")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.Palette.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Return \(candidate.displayName)'s deposit — they were texted"))
                Button {
                    Task { await onSkipAway(candidate) }
                } label: {
                    Text("Skip — away")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Theme.Palette.accent, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Return \(candidate.displayName)'s deposit — they were away"))
            }
        }
        .padding(Theme.Layout.cardInset)
    }
}
