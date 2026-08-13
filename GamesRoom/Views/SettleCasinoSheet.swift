//
//  SettleCasinoSheet.swift
//  GamesRoom
//
//  Track P0.5 — virtual-only Casino settle sheet.
//
//  Member-facing surface for entering the chips returned at the
//  end of a Casino round. The V0.8 virtual-only Casino path
//  records the net delta per member via the new
//  `record_round_score` RPC (migration 035) — the camera/Vision
//  pipeline is intentionally not exercised by this slice.
//
//  Pinned default: the stepper shows the member's open
//  withdrawal for the event (from the
//  `get_my_open_withdrawal(p_event_id)` RPC, migration 040),
//  falling back to 0 when no withdrawal exists. The slider
//  ranges from 0 upward in 10-pt increments so the member can
//  return more than they withdrew if they had pre-existing
//  points. Save calls
//  `ScoringService.recordRoundInput(roomId:eventId:packSlug:input:)`
//  with a `.withdrawReturn(roundIndex:perMember:)` input —
//  single-member edition since the host pre-aggregates in V0.8.
//

import SwiftUI

struct SettleCasinoSheet: View {

    let eventId: UUID
    let roomId: UUID
    let withdrawn: Int
    /// V0.46 integration fix — the member "Settle manually" path
    /// must NOT post through `record_round_score` (host-only RPC,
    /// migration 035 raises "Only the host can record a round").
    /// Members settle via `record_member_scan` (migration 030) with
    /// `source: .manual`, which computes net = returned − withdrawn
    /// and writes the member's own ledger row. Hosts keep the
    /// aggregate `recordRoundInput` path.
    var isHost: Bool = true

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scoringService: ScoringService
    @EnvironmentObject private var casinoService: CasinoService
    @EnvironmentObject private var authService: AuthService

    @State private var returned: Int = 0
    @State private var roundIndex: Int = 1
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("Withdrawn")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                        Spacer()
                        Text("\(withdrawn) pts")
                            .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    HStack {
                        Text("Return")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text("\(returned) pts")
                            .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                            .foregroundStyle(netColor)
                    }
                    HStack {
                        Text("Net")
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text("\(netDelta >= 0 ? "+" : "")\(netDelta) pts")
                            .font(Theme.Typography.title.monospacedDigit())
                            .foregroundStyle(netColor)
                    }
                    Stepper(
                        "Returned: \(returned) pts",
                        value: $returned,
                        in: 0...max(0, returned + 200),
                        step: 10
                    )
                } header: {
                    Text("Round")
                } footer: {
                    Text("Zero means you walked away even. Counts as a forfeiture against your season score.")
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
            .navigationTitle("Settle round")
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
                    .disabled(isSaving)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Computed

    private var netDelta: Int { returned - withdrawn }

    private var netColor: Color {
        if netDelta > 0 { return Theme.Palette.accent }
        if netDelta < 0 { return Theme.Palette.primaryText.opacity(0.55) }
        return Theme.Palette.primaryText
    }

    // MARK: - Async

    private func save() async {
        guard !isSaving else { return }
        guard let memberId = authService.currentUserId else {
            errorMessage = "Couldn't identify the current user."
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if isHost {
                let input = PackScoringInput.withdrawReturn(
                    roundIndex: roundIndex,
                    perMember: [
                        MemberNet(
                            memberId: memberId,
                            withdrawnPoints: Int64(withdrawn),
                            returnedPoints: Int64(returned)
                        )
                    ]
                )
                _ = try await scoringService.recordRoundInput(
                    roomId: roomId,
                    eventId: eventId,
                    packSlug: CasinoPack.slug,
                    input: input
                )
            } else {
                // Member manual settle — route through the
                // member-writable `record_member_scan` RPC so the
                // ledger row is attributed to the member, not the
                // host. `returned` is the chips the member brought
                // back; the server computes net = returned − withdrawn.
                let snapshot = VisionSnapshot(
                    stacks: [],
                    totalValue: returned,
                    confidenceAvg: 0,
                    discarded: false,
                    photoHash: nil
                )
                _ = try await casinoService.submitMemberScan(
                    eventId: eventId,
                    visionAmount: Int64(returned),
                    visionSnapshot: snapshot,
                    confidence: nil,
                    source: .manual
                )
            }
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}