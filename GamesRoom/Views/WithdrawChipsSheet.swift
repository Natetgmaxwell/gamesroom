//
//  WithdrawChipsSheet.swift
//  GamesRoom
//
//  Track P0.5 — virtual-only Casino withdraw sheet.
//
//  Member-facing surface for entering a chip withdrawal amount.
//  Loads the member's current `points_balance` via
//  `CasinoService.loadWithdrawalBalance(eventId:userId:)` and
//  pins the slider/stepper to that bound so the host never sees
//  an "insufficient balance" rejection for a value the slider
//  couldn't have produced.
//
//  Save calls `CasinoService.withdraw(eventId:roomId:amount:)`,
//  which routes through the existing migration 025 RPC
//  (`withdraw_casino_chips`). On success the sheet dismisses;
//  the parent view's refresh cycle reads the new balance + the
//  upcoming settle flow.
//
//  Why a stepper instead of a slider
//  ---------------------------------
//  Slider UX gets weird at table-distance touch targets. A stepper
//  in 10-pt increments (matching `withdraw_default`) keeps the
//  intent obvious and gives the member a clear "10 / 20 / 30…"
//  rhythm. The slider vs. stepper decision was an open question
//  in the V0.7.1 brief — the stepper is the explicit choice for
//  the P0.5 virtual-only path.
//

import SwiftUI

struct WithdrawChipsSheet: View {

    let eventId: UUID
    let roomId: UUID
    var onDone: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var casinoService: CasinoService
    @EnvironmentObject private var authService: AuthService

    @State private var balance: Int = 0
    @State private var amount: Int = 10
    @State private var isLoadingBalance: Bool = true
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if isLoadingBalance {
                    Section {
                        HStack {
                            ProgressView()
                                .tint(Theme.Palette.accent)
                            Text("Checking your balance…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                    }
                } else {
                    Section {
                        HStack {
                            Text("Available")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Spacer()
                            Text("\(balance) pts")
                                .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        Stepper(
                            "Withdraw: \(amount) pts",
                            value: $amount,
                            in: 10...max(10, balance),
                            step: 10
                        )
                    } header: {
                        Text("Withdraw")
                    } footer: {
                        Text("Bring \(amount) pts to the table. Wins are added, losses are deducted when you scan your stack.")
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
            .refreshable {
                await loadBalance()
            }
            .navigationTitle("Withdraw chips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Withdraw") {
                        Task { await save() }
                    }
                    .disabled(isSaving || isLoadingBalance || amount > balance)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
        .task {
            await loadBalance()
        }
    }

    // MARK: - Async

    private func loadBalance() async {
        defer { isLoadingBalance = false }
        guard let userId = authService.currentUserId else {
            // No session — collapse balance to 0 so the slider
            // renders as disabled. The parent view will dismiss
            // the sheet on the next auth state change.
            balance = 0
            return
        }
        balance = await casinoService.loadWithdrawalBalance(
            eventId: eventId,
            userId: userId
        )
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await casinoService.withdraw(
                eventId: eventId,
                roomId: roomId,
                amount: amount
            )
            Haptics.success()
            dismiss()
            onDone?()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}