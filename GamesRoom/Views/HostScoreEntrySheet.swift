//
//  HostScoreEntrySheet.swift
//  GamesRoom
//
//  Track P0.4 — host-side scoring entry.
//
//  Presented from `RoomDetailView`'s at-play slot when the host
//  wants to record a round for a `single_winner` pack (CAH,
//  Monopoly Deal, Pluto Chess). The chip tray shows every member
//  in the cached roster; tapping a chip selects that member as a
//  winner, tapping again deselects. Submitting routes through
//  `ScoringService.recordRoundInput(...)` with a `.singleWinner`
//  input for one winner or a `.multiWinner` input for several.
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
//  sheet is only presented for `single_winner` packs.
//

import SwiftUI

struct HostScoreEntrySheet: View {

    let eventId: UUID
    let roomId: UUID
    let packSlug: String
    let packDisplayName: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var scoringService: ScoringService

    @State private var selectedMemberIds: Set<UUID> = []
    @State private var roundIndex: Int = 1
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    private var members: [Member] {
        roomService.cachedMembers(roomId: roomId)
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
                } header: {
                    Text("Winners")
                } footer: {
                    Text("\(packDisplayName) — \(winPointsText). Tap a member to mark them as a winner; tap again to remove.")
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
                    Image(systemName: "checkmark")
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
        let points = PackRegistry.shared.winPoints(for: packSlug)
        return points == 1 ? "1 point per winner" : "\(points) points per winner"
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving, !selectedMemberIds.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let winPoints = PackRegistry.shared.winPoints(for: packSlug)
            let input: PackScoringInput
            if selectedMemberIds.count == 1, let soleWinner = selectedMemberIds.first {
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
