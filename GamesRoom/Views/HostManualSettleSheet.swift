//
//  HostManualSettleSheet.swift
//  GamesRoom
//
//  V0.72 slice 3 — host-only manual settle fallback.
//
//  Degenerate case only (member can't scan: no camera, model down,
//  rate-limited). The member never types a count; the host enters
//  the final number by hand. The path uses DetectionSource.manual
//  and the migration 070 host carve-out in
//  record_member_scan / record_cah_tally, which admits the room
//  host past the `minimax_vision` provider gate when the snapshot
//  source is 'manual'.
//
//  Presented from `RoomDetailView`'s tertiary "Enter count by hand"
//  CTA on the at-play Witness Slot (host only). On submit, the
//  folded envelope carries `source: "manual"` so the server-side
//  gate in migration 070 admits the call.
//

import SwiftUI

struct HostManualSettleSheet: View {

    let eventId: UUID
    let roomId: UUID
    let isCAH: Bool
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var casinoService: CasinoService
    @EnvironmentObject private var scoringService: ScoringService

    @State private var selectedMemberId: UUID?
    @State private var amountText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    private var members: [Member] {
        roomService.cachedMembers(roomId: roomId)
    }

    private var parsedAmount: Int? {
        let trimmed = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value >= 0, value < 100_000 else { return nil }
        return value
    }

    private var canSubmit: Bool {
        selectedMemberId != nil && parsedAmount != nil && !isSubmitting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    memberChipTray
                } header: {
                    Text("Member")
                } footer: {
                    Text("Pick the member whose count you're entering.")
                }

                Section {
                    HStack {
                        TextField(
                            isCAH ? "Card count" : "Points on table",
                            text: $amountText
                        )
                        .keyboardType(.numberPad)
                        .onChange(of: amountText) { _, newValue in
                            amountText = newValue.filter { $0.isNumber }
                        }
                    }
                } header: {
                    Text("Count")
                } footer: {
                    Text("Host-only fallback for when a member can't scan. The count is final and logged.")
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
            .navigationTitle("Enter count by hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(!canSubmit)
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
        let isSelected = selectedMemberId == member.userId
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
        if selectedMemberId == memberId {
            selectedMemberId = nil
        } else {
            selectedMemberId = memberId
        }
    }

    private func initial(for member: Member) -> String {
        String(member.displayName.prefix(1)).uppercased()
    }

    // MARK: - Save

    private func save() async {
        guard !isSubmitting, let memberId = selectedMemberId, let amount = parsedAmount else {
            return
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let snapshot = VisionSnapshot(
            stacks: [],
            totalValue: amount,
            confidenceAvg: 0,
            discarded: false,
            photoHash: nil
        )

        do {
            if isCAH {
                _ = try await scoringService.recordCAHTally(
                    eventId: eventId,
                    cardCount: Int64(amount),
                    visionSnapshot: snapshot,
                    onBehalfOf: memberId,
                    source: "manual"
                )
            } else {
                _ = try await casinoService.submitMemberScan(
                    eventId: eventId,
                    visionAmount: Int64(amount),
                    visionSnapshot: snapshot,
                    confidence: nil,
                    source: .manual,
                    memberId: memberId
                )
            }
            Haptics.success()
            onDone()
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
            Haptics.warning()
        }
    }
}
