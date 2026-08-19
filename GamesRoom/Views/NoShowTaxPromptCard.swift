//
//  NoShowTaxPromptCard.swift
//  GamesRoom
//
//  V0.84 C3 — host-only no-show tax prompt (migration 082).
//
//  Rendered in `RoomDetailView.scrollBody` when the room is
//  live (active event whose `playedAt <= now`, not settled),
//  `room.noShowTaxTrigger == .prompt`, the caller is the host,
//  and the candidate list is non-empty. The card surfaces one
//  row per claimed-but-absent member and lets the host decide
//  Apply / Skip (texted) / Skip (away) per row in isolation.
//  The substrate line is "the host always decides; the system
//  never decides alone" (Carnegie 3.1 — don't argue; 4.5 —
//  save face).
//
//  The prompt copy is the mascot's, never a neutral system
//  message. `NoShowTaxPromptVoice.promptLine(mascotName:
//  displayName: taxAmount:)` is the source of truth for the
//  header text — the Swift string interpolation always takes
//  the mascot name from the caller (per the locked directive
//  "the mascot is the only system voice").
//
//  Apply calls `roomService.applyNoShowTax(eventId:userId:
//  reason:)`; Skip (texted) / Skip (away) call
//  `roomService.skipNoShowTax(eventId:userId:reason:)`. Both
//  remove the row from the service's cached candidate list so
//  the next render omits it. Errors surface via the existing
//  `seatActionError` alert pattern.
//

import SwiftUI

struct NoShowTaxPromptCard: View {
    let room: Room
    let event: Event
    let candidates: [NoShowTaxCandidate]
    let onApply: (NoShowTaxCandidate) async -> Void
    let onSkipTexted: (NoShowTaxCandidate) async -> Void
    let onSkipAway: (NoShowTaxCandidate) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 8) {
                Image(systemName: Theme.Icon.handRaisedFill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("No-show tax")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
            Text("A claimed seat went empty. You decide what the room does with the chip.")
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
    private func candidateRow(_ candidate: NoShowTaxCandidate) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                NoShowTaxPromptVoice.promptLine(
                    mascotName: room.mascotName,
                    displayName: candidate.displayName,
                    taxAmount: candidate.taxAmount
                )
            )
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.primaryText)
            HStack(spacing: 8) {
                Button {
                    Task { await onApply(candidate) }
                } label: {
                    Text("Apply")
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
                .accessibilityLabel(Text("Apply \(candidate.taxAmount) CC no-show tax for \(candidate.displayName)"))
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
                .accessibilityLabel(Text("Skip no-show tax for \(candidate.displayName) — they were texted"))
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
                .accessibilityLabel(Text("Skip no-show tax for \(candidate.displayName) — they were away"))
            }
        }
        .padding(Theme.Layout.cardInset)
    }
}