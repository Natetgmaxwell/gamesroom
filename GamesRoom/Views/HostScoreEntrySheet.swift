//
//  HostScoreEntrySheet.swift
//  GamesRoom
//
//  Track P0.4 — host-side single-winner scoring entry.
//
//  Presented from `RoomDetailView`'s at-play slot when the host
//  wants to record a round for a `single_winner` pack (CAH,
//  Monopoly Deal, Pluto Chess). The picker shows every member
//  in the cached roster; selecting a member + tapping Submit
//  routes through `ScoringService.recordRoundInput(...)` with a
//  `.singleWinner(roundIndex:winnerMemberId:winPoints:)` input.
//
//  Why a member picker
//  -------------------
//  P0.4's "host-only scoring controls render from the installed
//  pack definitions". Each pack has a fixed win-points value
//  (per the V0.8 brief: 1 point per round) — the host's job is
//  to identify the winner. Future packs with non-uniform
//  win-points will branch on `PackRegistry.winPoints(for:)`
//  here.
//
//  The Casino path uses `SettleCasinoSheet` (P0.5) instead; this
//  sheet refuses to render for the casino slug so the host can't
//  accidentally submit a single-winner round against a
//  `withdraw_return` pack.
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

    @State private var selectedMemberId: UUID?
    @State private var roundIndex: Int = 1
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if roomService.cachedMembers(roomId: roomId).isEmpty {
                        HStack {
                            ProgressView()
                                .tint(Theme.Palette.accent)
                            Text("Loading members…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                    } else {
                        Picker("Winner", selection: $selectedMemberId) {
                            Text("Pick the winner").tag(UUID?.none)
                            ForEach(roomService.cachedMembers(roomId: roomId), id: \.userId) { member in
                                Text("\(member.displayName) (\(member.role == .host ? "host" : "member"))")
                                    .tag(UUID?.some(member.userId))
                            }
                        }
                    }
                    Stepper(
                        "Round index: \(roundIndex)",
                        value: $roundIndex,
                        in: 1...50
                    )
                } header: {
                    Text("Round")
                } footer: {
                    Text("\(packDisplayName) — 1 point to the winner's season score.")
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
                    .disabled(isSaving || selectedMemberId == nil)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving, let winnerId = selectedMemberId else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let input = PackScoringInput.singleWinner(
                roundIndex: roundIndex,
                winnerMemberId: winnerId,
                winPoints: PackRegistry.shared.winPoints(for: packSlug)
            )
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