//
//  SessionRoundTimeline.swift
//  GamesRoom
//
//  W3.6 — in-session round timeline (presentation-only).
//
//  Shows the rounds logged tonight for a single event, oldest
//  first. Each row carries the pack icon, the round number, the
//  per-member signed delta, and a "corrected" chip when the row
//  is a re-submission. Tapping a row routes to the host-side
//  edit flow; the trash button routes to the host-side delete
//  flow. The view is presentation-only — callers own the
//  service calls and the dismissed-state rerender.
//
//  Usage:
//      SessionRoundTimeline(
//          rounds: roomService.cachedEventRounds(eventId: event.id),
//          members: roomService.cachedMembers(roomId: event.roomId),
//          onEdit: { round in isEditingRound = round },
//          onDelete: { round in roundToDelete = round }
//      )
//

import SwiftUI

struct SessionRoundTimeline: View {
    let rounds: [EventRound]
    let members: [Member]
    let onEdit: (EventRound) -> Void
    let onDelete: (EventRound) -> Void

    private var sortedRounds: [EventRound] {
        rounds.sorted { $0.roundIndex < $1.roundIndex }
    }

    private func displayName(for memberId: UUID) -> String {
        members.first { $0.userId == memberId }?.displayName ?? "Member"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.edgePadding) {
            header
            if sortedRounds.isEmpty {
                emptyState
            } else {
                rowsList
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Rounds tonight")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            Text("\(sortedRounds.count)")
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                .accessibilityLabel(Text("\(sortedRounds.count) rounds logged"))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: Rows

    private var rowsList: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedRounds.enumerated()), id: \.element.id) { index, round in
                if index > 0 {
                    Divider().overlay(Theme.Palette.hairline)
                }
                SessionRoundTimelineRow(
                    round: round,
                    displayName: displayName(for:),
                    onEdit: { onEdit(round) },
                    onDelete: { onDelete(round) }
                )
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        Text("No rounds logged yet")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }
}

// MARK: - Row

private struct SessionRoundTimelineRow: View {
    let round: EventRound
    let displayName: (UUID) -> String
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var iconName: String {
        PackRegistry.shared.definition(for: round.packSlug)?.iconSystemName ?? "gamecontroller.fill"
    }

    private var isCorrected: Bool { round.correctionOf != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 24)
            entriesBlock
            Spacer(minLength: 8)
            if isCorrected {
                correctedChip
            }
            deleteButton
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Tap to edit this round"))
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var entriesBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Round \(round.roundIndex)")
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            ForEach(round.entries) { entry in
                HStack(spacing: 6) {
                    Text(displayName(entry.memberId))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                    Text(deltaLabel(entry.pointsDelta))
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(deltaColor(entry.pointsDelta))
                }
            }
        }
    }

    private var correctedChip: some View {
        Text("corrected")
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .accessibilityLabel(Text("This round corrects a previous submission"))
    }

    private var deleteButton: some View {
        Button(action: onDelete) {
            Image(systemName: Theme.Icon.trashFill)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Delete round \(round.roundIndex)"))
    }

    // MARK: Helpers

    private func deltaLabel(_ delta: Int64) -> String {
        let prefix = delta > 0 ? "+" : ""
        return "\(prefix)\(delta)"
    }

    private func deltaColor(_ delta: Int64) -> Color {
        delta < 0 ? Theme.Palette.primaryText.opacity(0.6) : Theme.Palette.accent
    }

    private var accessibilityLabel: String {
        let entries = round.entries.map { entry in
            "\(displayName(entry.memberId)) \(deltaLabel(entry.pointsDelta))"
        }.joined(separator: ", ")
        let prefix = "Round \(round.roundIndex)"
        let correction = isCorrected ? ", corrected" : ""
        return entries.isEmpty ? "\(prefix)\(correction)" : "\(prefix), \(entries)\(correction)"
    }
}

#if DEBUG
#Preview("Timeline, mixed rounds") {
    let eventId = UUID()
    let roomId = UUID()
    let userId = UUID()
    let alice = UUID()
    let bob = UUID()
    let rounds: [EventRound] = [
        EventRound(
            id: UUID(), eventId: eventId, roomId: roomId,
            packSlug: "cards_against_humanity", roundIndex: 1,
            entries: [ScoreEntry(memberId: alice, pointsDelta: 1)],
            createdBy: userId, createdAt: Date()
        ),
        EventRound(
            id: UUID(), eventId: eventId, roomId: roomId,
            packSlug: "pluto_chess", roundIndex: 2,
            entries: [ScoreEntry(memberId: bob, pointsDelta: -2)],
            createdBy: userId, createdAt: Date(),
            correctionOf: UUID()
        ),
        EventRound(
            id: UUID(), eventId: eventId, roomId: roomId,
            packSlug: "monopoly_deal", roundIndex: 3,
            entries: [
                ScoreEntry(memberId: alice, pointsDelta: 1),
                ScoreEntry(memberId: bob, pointsDelta: 1)
            ],
            createdBy: userId, createdAt: Date()
        )
    ]
    let members: [Member] = [
        Member(
            id: "\(roomId.uuidString):\(alice.uuidString)",
            roomId: roomId, userId: alice, role: .member,
            joinedAt: Date(), displayName: "Alice"
        ),
        Member(
            id: "\(roomId.uuidString):\(bob.uuidString)",
            roomId: roomId, userId: bob, role: .member,
            joinedAt: Date(), displayName: "Bob"
        )
    ]
    return SessionRoundTimeline(
        rounds: rounds,
        members: members,
        onEdit: { _ in },
        onDelete: { _ in }
    )
    .sectionCard(.standard)
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("Timeline, empty") {
    SessionRoundTimeline(
        rounds: [],
        members: [],
        onEdit: { _ in },
        onDelete: { _ in }
    )
    .sectionCard(.standard)
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif
