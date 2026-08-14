//
//  HostScoringDashboard.swift
//  GamesRoom
//
//  Track P0.4 — iPad host scoring surface.
//
//  Replaces the phone-shaped scroll + `HostScoreEntrySheet` modal
//  on iPad landscape (regular width). Hosts see one big chip grid
//  per member, a big − / + round index, a single accent "Log
//  round" button, and a standings strip with running totals at
//  the bottom — all reachable at table distance, no sheet to
//  dismiss between rounds.
//
//  Why a dedicated surface (F-MVP-05 V2 minimal)
//  --------------------------------------------
//  The V0.8 vision's live-play row demands "one tap per scoring
//  event" on iPad; the previous member picker was a phone-form
//  pattern (scroll + tap + confirm). Chips at 160pt min + a
//  56pt submit button + an at-table standings strip are
//  tappable from across the table, and multi-winner is cheap
//  because the scoring contract already emits multi-entry
//  `[ScoreEntry]` arrays and `record_round_score` loops over
//  every entry with no single-winner validation.
//
//  Gate is owned by the parent (`RoomDetailView`); this view
//  only renders when the gate holds. The Casino pack's
//  member-driven vision scan flow (`ChipScanSheet`) is unchanged.
//
//  V0.34b: round-logging wired in. `rounds` mirrors the per-event
//  log; the next round index is reseeded from `rounds.nextRoundIndex`
//  after every save, delete, or edit-cancel. The session timeline
//  shows below the submit bar (capped at 240pt so the fixed VStack
//  layout holds), and the host can tap any row to correct it or
//  delete it.
//

import SwiftUI

struct HostScoringDashboard: View {

    let room: Room
    let event: Event
    let onClose: () -> Void

    @Environment(\.horizontalSizeClass) private var hSize
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var scoringService: ScoringService

    @State private var selectedMemberIds: Set<UUID> = []
    @State private var roundIndex: Int = 1
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?
    @State private var rounds: [EventRound] = []
    @State private var editingRound: EventRound?
    @State private var roundToDelete: EventRound?

    private var members: [Member] {
        roomService.cachedMembers(roomId: room.id)
    }

    private var leaderboard: [LeaderboardEntry] {
        roomService.cachedLeaderboard(roomId: room.id)
    }

    private var packDisplayName: String {
        PackRegistry.shared.definition(for: event.packSlug)?.displayName ?? event.packSlug
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Layout.sectionSpacing)
                .background(Theme.Palette.background)

            Divider()
                .overlay(Theme.Palette.hairline)

            memberChipGrid
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Layout.sectionSpacing)

            Divider()
                .overlay(Theme.Palette.hairline)

            submitBar
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Layout.sectionSpacing)
                .background(Theme.Palette.surface)

            Divider()
                .overlay(Theme.Palette.hairline)

            ScrollView(.vertical, showsIndicators: false) {
                SessionRoundTimeline(
                    rounds: rounds,
                    members: members,
                    onEdit: { startEditing($0) },
                    onDelete: { round in roundToDelete = round }
                )
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Layout.sectionSpacing)
            }
            .frame(maxHeight: 240)

            Divider()
                .overlay(Theme.Palette.hairline)

            standingsStrip
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, Theme.Layout.cardInset)
                .background(Theme.Palette.background)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .tint(Theme.Palette.accent)
        .task {
            rounds = await roomService.loadEventRounds(eventId: event.id)
            roundIndex = rounds.nextRoundIndex
        }
        .confirmationDialog(
            "Delete round \(roundToDelete?.roundIndex ?? 0)?",
            isPresented: Binding(
                get: { roundToDelete != nil },
                set: { if !$0 { roundToDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: roundToDelete
        ) { round in
            Button("Delete", role: .destructive) {
                Task {
                    await deleteRound(round)
                    roundToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                roundToDelete = nil
            }
        } message: { _ in
            Text("This reverses the score change for everyone in the round.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Layout.cardInset) {
            VStack(alignment: .leading, spacing: 4) {
                Text(room.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(packDisplayName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                if let editingRound {
                    HStack(spacing: Theme.Layout.cardInset) {
                        Text("Editing round \(editingRound.roundIndex)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        Button("Cancel") {
                            cancelEdit()
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
            roundControl
            Button {
                onClose()
            } label: {
                Image(systemName: Theme.Icon.xmark)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.Palette.surface)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close scoring dashboard"))
        }
    }

    private var roundControl: some View {
        HStack(spacing: Theme.Layout.cardInset) {
            Button {
                if roundIndex > 1 { roundIndex -= 1 }
            } label: {
                Image(systemName: "minus")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.background)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(roundIndex > 1 ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(roundIndex <= 1)
            .accessibilityLabel(Text("Previous round"))

            Text("\(roundIndex)")
                .font(Theme.Typography.title)
                .monospacedDigit()
                .foregroundStyle(Theme.Palette.primaryText)
                .frame(minWidth: 56)

            Button {
                if roundIndex < 50 { roundIndex += 1 }
            } label: {
                Image(systemName: "plus")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.background)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(roundIndex < 50 ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(roundIndex >= 50)
            .accessibilityLabel(Text("Next round"))
        }
    }

    // MARK: - Member chip grid

    private var memberChipGrid: some View {
        Group {
            if members.isEmpty {
                VStack(spacing: Theme.Layout.cardInset) {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Loading members…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                LazyVGrid(
                    columns: [GridItem(
                        .adaptive(minimum: Theme.Layout.scoringChipMin(for: hSize)),
                        spacing: 16
                    )],
                    spacing: 16
                ) {
                    ForEach(members) { member in
                        memberChip(member)
                    }
                }
            }
        }
    }

    private func memberChip(_ member: Member) -> some View {
        let isSelected = selectedMemberIds.contains(member.userId)
        return Button {
            toggle(member.userId)
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.Palette.accent : Theme.Palette.surface)
                        .frame(width: 64, height: 64)
                    Text(initial(for: member))
                        .font(Theme.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(isSelected ? Theme.Palette.background : Theme.Palette.primaryText)
                    if isSelected {
                        Circle()
                            .stroke(Theme.Palette.accent, lineWidth: 2)
                            .frame(width: 64, height: 64)
                        Image(systemName: Theme.Icon.checkmark)
                            .font(Theme.Typography.caption)
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.Palette.background)
                            .offset(x: 22, y: -22)
                            .background(
                                Circle()
                                    .fill(Theme.Palette.primaryText)
                                    .frame(width: 22, height: 22)
                            )
                    }
                }
                Text(member.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, Theme.Layout.cardInset)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Theme.Palette.accent.opacity(0.14) : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
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

    // MARK: - Submit

    private var submitBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                Task { await save() }
            } label: {
                Text("Log round")
                    .font(Theme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.Palette.background)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(canSubmit ? Theme.Palette.accent : Theme.Palette.accent.opacity(0.35))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            if let errorMessage {
                Text(errorMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(.red.opacity(0.85))
            }
        }
    }

    private var canSubmit: Bool {
        !isSaving && !selectedMemberIds.isEmpty
    }

    // MARK: - Standings strip

    private var standingsStrip: some View {
        Group {
            if leaderboard.isEmpty {
                Text("No scores yet")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Layout.cardInset) {
                        ForEach(leaderboard) { entry in
                            standingsChip(entry)
                        }
                    }
                }
            }
        }
    }

    private func standingsChip(_ entry: LeaderboardEntry) -> some View {
        let name = entry.displayName.isEmpty
            ? (memberName(for: entry.userId) ?? "Member")
            : entry.displayName
        return HStack(spacing: 6) {
            Text(name)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(1)
            Text("\(entry.seasonScore)")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Theme.Palette.hairline, lineWidth: 0.5)
        )
    }

    private func memberName(for userId: UUID) -> String? {
        members.first(where: { $0.userId == userId })?.displayName
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving, !selectedMemberIds.isEmpty else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let winPoints = roomService.effectiveWinPoints(roomId: room.id, packSlug: event.packSlug)
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
                roomId: room.id,
                eventId: event.id,
                packSlug: event.packSlug,
                input: input,
                correctionOf: editingRound?.id
            )
            _ = await roomService.loadLeaderboard(roomId: room.id)
            rounds = await roomService.loadEventRounds(eventId: event.id)
            roundIndex = rounds.nextRoundIndex
            selectedMemberIds.removeAll()
            editingRound = nil
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    // MARK: - Edit + delete

    /// Seed the form from a previously-logged round so the host can
    /// adjust the winners. `roundIndex` is restored from the round
    /// itself; the next save passes `editingRound.id` through as
    /// `correctionOf` so the server records a re-submission rather
    /// than a fresh row.
    private func startEditing(_ round: EventRound) {
        editingRound = round
        roundIndex = round.roundIndex
        selectedMemberIds = Set(round.entries.map(\.memberId))
    }

    /// Exit edit mode without saving. Reseeds `roundIndex` from the
    /// current log so the next logged round continues the monotonic
    /// sequence, and clears any partial chip selection.
    private func cancelEdit() {
        editingRound = nil
        roundIndex = rounds.nextRoundIndex
        selectedMemberIds.removeAll()
    }

    /// Reverse a previously-recorded round: subtracts the deltas,
    /// deletes the round's transactions, and removes the row.
    /// Reseeds `roundIndex` from the log on success and clears edit
    /// state if the deleted round was being corrected.
    private func deleteRound(_ round: EventRound) async {
        do {
            try await scoringService.deleteRound(
                roomId: room.id,
                eventId: event.id,
                roundIndex: round.roundIndex
            )
            _ = await roomService.loadLeaderboard(roomId: room.id)
            rounds = await roomService.loadEventRounds(eventId: event.id)
            roundIndex = rounds.nextRoundIndex
            if editingRound?.id == round.id { editingRound = nil }
            selectedMemberIds.removeAll()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
