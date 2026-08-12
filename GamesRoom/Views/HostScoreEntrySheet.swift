//
//  HostScoreEntrySheet.swift
//  GamesRoom
//
//  Track P0.4 — host-side scoring entry.
//
//  Presented from `RoomDetailView`'s at-play slot when the host
//  wants to record a round for a `single_winner` pack (Monopoly
//  Deal, Pluto Chess) or the new `count_based` pack (Cards
//  Against Humanity). The chip tray shows every member in the
//  cached roster; tapping a chip selects that member as a
//  winner, tapping again deselects. Submitting routes through
//  `ScoringService.recordRoundInput(...)` with a `.singleWinner`
//  input for one winner, `.multiWinner` for several, or
//  `.countBased` for CAH.
//
//  V0.34 — count-based scoring. The sheet branches on the pack's
//  `scoringType`:
//   - `.singleWinner` / `.multiWinner`: chip tray is multi-select
//     (tapping toggles), stepper picks round index, payout is
//     `effectiveWinPoints`.
//   - `.countBased` (CAH): chip tray is single-select (the
//     judge's pick is the only winner), steppers pick round index
//     + cards won (default 1, range 1...20). The round's score is
//     the cards-won count; the session-end tally RPC
    //     (`record_cah_tally`, migration 055) replaces the per-round
    //     entries with the member's scanned count.
//
//  Why a chip tray (F-MVP-05 V2 minimal, scope decision
//  2026-08-10)
//  -------------------
//  The V0.8 vision's live-play row demands "one tap per scoring
//  event" on iPad; the previous member picker was a phone-form
//  pattern (scroll + tap + confirm). Chips are tappable at table
//  distance, and multi-winner is cheap because the scoring
//  contract already emits multi-entry `[ScoreEntry]` arrays and
//  `record_round_score` (migration 035) loops over every entry
//  with no single-winner validation.
//
//  The Casino path uses `SettleCasinoSheet` (P0.5) instead; this
//  sheet is only presented for `single_winner` and `count_based`
//  packs.
//

import SwiftUI

struct HostScoreEntrySheet: View {

    let eventId: UUID
    let roomId: UUID
    let packSlug: String
    let packDisplayName: String
    /// V0.35B — room-configured default cards-won (CAH's points-per-card
    /// in the count-based model). Seeds the host's per-round "Cards won"
    /// stepper so a room with a configured default opens the stepper at
    /// that value instead of 1.
    let defaultCardCount: Int

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var scoringService: ScoringService

    @State private var selectedMemberIds: Set<UUID> = []
    @State private var roundIndex: Int = 1
    /// V0.34 — for count-based scoring packs (CAH) the host also
    /// enters the number of cards the winner takes per round. Default
    /// 1; range 1...20 covers any reasonable CAH per-round count.
    /// V0.35B — initial value seeded from the room's configured
    /// points-per-card (see `defaultCardCount`); floored at 1 so the
    /// stepper stays in its valid range.
    @State private var cardCount: Int

    init(eventId: UUID, roomId: UUID, packSlug: String, packDisplayName: String, defaultCardCount: Int) {
        self.eventId = eventId
        self.roomId = roomId
        self.packSlug = packSlug
        self.packDisplayName = packDisplayName
        self.defaultCardCount = defaultCardCount
        _cardCount = State(initialValue: max(1, defaultCardCount))
    }

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var members: [Member] {
        roomService.cachedMembers(roomId: roomId)
    }

    /// V0.34 — count-based scoring is a new family. The pack's
    /// `scoringType` is the discriminator; resolved via the pack
    /// registry so the sheet's input form branches accordingly.
    private var isCountBased: Bool {
        PackRegistry.shared.definition(for: packSlug)?.scoringType == .countBased
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if members.isEmpty {
                        HStack {
                            ProgressView()
                                .tint(Theme.Palette.accent)
                            Text("Loading members…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                    } else {
                        memberChipTray
                    }
                    Stepper(
                        "Round index: \(roundIndex)",
                        value: $roundIndex,
                        in: 1...50
                    )
                    // V0.34 — count-based packs (CAH) get a
                    // "cards won" stepper below the round index.
                    // The judge's pick keeps the black card; the
                    // host enters how many cards the winner takes
                    // (usually 1).
                    if isCountBased {
                        Stepper(
                            "Cards won: \(cardCount)",
                            value: $cardCount,
                            in: 1...20
                        )
                    }
                } header: {
                    Text("Winners")
                } footer: {
                    if isCountBased {
                        Text("The judge's pick wins the round and keeps the black card. Enter how many cards the winner takes (usually 1).")
                    } else {
                        Text("\(packDisplayName) — \(winPointsText). Tap a member to mark them as a winner; tap again to remove.")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Score a round")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task { await save() }
                    }
                    .disabled(isSaving || selectedMemberIds.isEmpty)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Chip tray

    private var memberChipTray: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 12)],
            spacing: 12
        ) {
            ForEach(members) { member in
                memberChip(member)
            }
        }
        .padding(.vertical, 4)
    }

    private func memberChip(_ member: Member) -> some View {
        let isSelected = selectedMemberIds.contains(member.userId)
        return Button {
            toggle(member.userId)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.Palette.accent : Theme.Palette.surface)
                        .frame(width: 28, height: 28)
                    Text(initial(for: member))
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? Theme.Palette.background : Theme.Palette.primaryText)
                }
                Text(member.displayName)
                    .font(Theme.Typography.caption)
                    .lineLimit(1)
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: Theme.Icon.checkmark)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.Palette.accent.opacity(0.14) : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Theme.Palette.accent : Theme.Palette.hairline, lineWidth: isSelected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(member.displayName), \(isSelected ? "selected" : "not selected")")
    }

    private func toggle(_ memberId: UUID) {
        // V0.34 — count-based scoring is single-select: tapping a
        // member selects only them, tapping the selected member
        // deselects. There is no multi-winner for CAH (the judge's
        // pick is the only winner each round).
        if isCountBased {
            if selectedMemberIds.contains(memberId) {
                selectedMemberIds.remove(memberId)
            } else {
                selectedMemberIds = [memberId]
            }
            return
        }
        if selectedMemberIds.contains(memberId) {
            selectedMemberIds.remove(memberId)
        } else {
            selectedMemberIds.insert(memberId)
        }
    }

    private func initial(for member: Member) -> String {
        String(member.displayName.prefix(1)).uppercased()
    }

    private var winPointsText: String {
        let points = effectiveWinPoints
        return points == 1 ? "1 point per winner" : "\(points) points per winner"
    }

    /// 2026-08-10 feedback round — the payout the round submits is
    /// the room's configured override when one exists, otherwise the
    /// pack's static default. The host edits payouts from the pack
    /// shelf; this sheet reads the same effective value.
    private var effectiveWinPoints: Int {
        roomService.effectiveWinPoints(roomId: roomId, packSlug: packSlug)
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving, !selectedMemberIds.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let winPoints = effectiveWinPoints
            let input: PackScoringInput
            if isCountBased, let soleWinner = selectedMemberIds.first {
                // V0.34 — count-based scoring routes through
                // `.countBased` so the resolver emits a `cards_won`
                // entry and the record_round_score ledger row carries
                // the round's cards-won metadata. The session-end
                // tally RPC (record_cah_tally, migration 055) replaces
                // these per-round entries with the member's scanned
                // count.
                input = .countBased(
                    roundIndex: roundIndex,
                    winnerMemberId: soleWinner,
                    cardCount: cardCount
                )
            } else if selectedMemberIds.count == 1, let soleWinner = selectedMemberIds.first {
                input = .singleWinner(
                    roundIndex: roundIndex,
                    winnerMemberId: soleWinner,
                    winPoints: winPoints
                )
            } else {
                input = .multiWinner(
                    roundIndex: roundIndex,
                    winnerMemberIds: Array(selectedMemberIds).sorted { $0.uuidString < $1.uuidString },
                    winPoints: winPoints
                )
            }
            _ = try await scoringService.recordRoundInput(
                roomId: roomId,
                eventId: eventId,
                packSlug: packSlug,
                input: input
            )
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
