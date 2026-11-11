//
//  GladYouCameSection.swift
//  GamesRoom
//
//  1.2.5 Task 4 — "Glad you came", the recap's part. One quiet section
//  that sits under Tonight's Star on a settled night's recap:
//
//    * the recipient's line, if anyone told them:
//        "Connor and Sam were glad you came."
//    * for someone who held a seat, inside the 24 h recap window, the
//      one grey caption "Who were you glad to see?", which opens the
//      sheet of that night's table.
//
//  Self-contained on purpose: the recap (`CeremonialCard`) inserts it
//  with one line and passes nothing but the night and the viewer. It
//  reads the table from `RoomService`'s RSVP cache and the notes from
//  `GladStore`. Every rule lives in `GladYouCame` (Models), every phase
//  comes from `NightPhaseResolver`.
//
//  Privacy: it shows the viewer only their own sent names and the
//  names of the people who told them. No count, no host view, nothing
//  about who did not get one.
//

import SwiftUI

struct GladYouCameSection: View {
    let event: Event
    let viewerId: UUID?

    @EnvironmentObject private var roomService: RoomService

    @State private var notes: [GladNote] = []
    @State private var phase: GladSendPhase = .idle
    @State private var showingSheet = false
    @State private var commitTask: Task<Void, Never>?

    private var store: GladStore { GladStores.current }

    private var rsvps: [EventRSVP] { roomService.cachedEventRSVPs(eventId: event.id) }

    private var table: [EventRSVP] { GladYouCame.table(rsvps: rsvps, viewerId: viewerId) }

    private var names: [UUID: String] {
        Dictionary(rsvps.map { ($0.memberId, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private var canSend: Bool {
        GladYouCame.canSend(
            phase: NightPhaseResolver.phase(for: event),
            viewerHadSeat: GladYouCame.hadSeat(viewerId, rsvps: rsvps)
        )
    }

    /// Told on the server, plus whatever is pending or just sent here.
    private var told: Set<UUID> {
        GladYouCame.alreadyTold(notes: notes, eventId: event.id, viewerId: viewerId)
            .union(phase.pendingOrSent)
    }

    private var receivedLine: String? {
        GladYouCame.receivedLine(notes: notes, eventId: event.id, viewerId: viewerId, names: names)
    }

    private var sentLine: String? {
        GladYouCame.sentLine(names: table.filter { told.contains($0.memberId) }.map(\.displayName))
    }

    /// Anyone at the table not told yet. When everyone has been told
    /// the caption has nothing left to offer and steps aside.
    private var anyoneLeft: Bool {
        table.contains { !told.contains($0.memberId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            if let receivedLine {
                Text(receivedLine)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("glad-received")
            }
            if canSend {
                if let sentLine {
                    HStack(spacing: 6) {
                        Text(sentLine)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .accessibilityIdentifier("glad-sent")
                        if phase.canUndo {
                            Button("Undo", action: undo)
                                .font(Theme.Typography.caption.weight(.semibold))
                                .foregroundStyle(Theme.Palette.accent)
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("glad-undo")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                if case .failed = phase {
                    Text("That didn't send. Try again.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .frame(maxWidth: .infinity)
                }
                if anyoneLeft {
                    SecondaryTextAction(title: GladYouCame.prompt) { showingSheet = true }
                        .accessibilityIdentifier("glad-prompt")
                }
            }
        }
        .sheet(isPresented: $showingSheet) {
            GladYouCameSheet(table: table, alreadyTold: told) { picked in
                send(picked)
            }
        }
        .task(id: event.id) { await load() }
    }

    // MARK: - Data

    private func load() async {
        _ = await roomService.loadEventRSVPs(eventId: event.id)
        guard let viewerId else { return }
        if let fetched = try? await store.fetchNotes(eventId: event.id, viewerId: viewerId) {
            notes = fetched
        }
    }

    /// Optimistic: the recap reads as sent from the tap; nothing leaves
    /// the phone until the 5 s Undo window has passed.
    private func send(_ picked: Set<UUID>) {
        let ids = GladYouCame.toSend(picked: picked, alreadyTold: told, table: table, viewerId: viewerId)
        guard !ids.isEmpty, let viewerId else { return }
        commitTask?.cancel()
        phase = phase.reduce(.send(ids))
        guard case .undoing = phase else { return }
        let eventId = event.id
        let store = self.store
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(GladSendPhase.undoWindow * 1_000_000_000))
            guard !Task.isCancelled, phase.canUndo else { return }
            phase = phase.reduce(.commitStarted)
            do {
                try await store.send(eventId: eventId, from: viewerId, to: ids)
                phase = phase.reduce(.succeeded)
                if let fetched = try? await store.fetchNotes(eventId: eventId, viewerId: viewerId) {
                    notes = fetched
                    phase = .idle
                }
            } catch {
                phase = phase.reduce(.failed)
            }
        }
    }

    private func undo() {
        commitTask?.cancel()
        commitTask = nil
        phase = phase.reduce(.undo)
    }
}

// MARK: - The sheet

/// The night's table, never the viewer. Tap any number of names, then
/// Send, the one primary button. People already told show as sent and
/// cannot be picked again.
struct GladYouCameSheet: View {
    let table: [EventRSVP]
    let alreadyTold: Set<UUID>
    let onSend: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<UUID> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Layout.cardGroupGap) {
                List {
                    Section {
                        ForEach(table) { seat in
                            row(seat)
                        }
                    } footer: {
                        Text("Only they'll see it.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .scrollContentBackground(.hidden)

                Button {
                    onSend(picked)
                    dismiss()
                } label: {
                    Text("Send")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(picked.isEmpty)
                .accessibilityIdentifier("glad-send")
                .padding(.horizontal, Theme.Layout.cardInset)
                .padding(.bottom, Theme.Layout.cardInset)
            }
            .background(Theme.Palette.background)
            .navigationTitle(GladYouCame.prompt)
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Theme.Palette.accent)
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("glad-sheet")
    }

    @ViewBuilder
    private func row(_ seat: EventRSVP) -> some View {
        let told = alreadyTold.contains(seat.memberId)
        let on = told || picked.contains(seat.memberId)
        Button {
            guard !told else { return }
            if picked.contains(seat.memberId) {
                picked.remove(seat.memberId)
            } else {
                picked.insert(seat.memberId)
            }
        } label: {
            HStack {
                Text(seat.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer()
                if told {
                    Text("Sent")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(on ? Theme.Palette.accent : Theme.Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(told)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("glad-row-\(seat.displayName)")
    }
}
