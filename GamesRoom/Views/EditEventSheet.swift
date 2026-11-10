//
//  EditEventSheet.swift
//  GamesRoom
//
//  S3.4 — the host's night editor.
//
//  One sheet for the four things a host can change about a night:
//  its name, when it happens, where it happens and what the table
//  needs to know. The name goes through `update_event_name`, the
//  time through `update_event_played_at`, the venue and the note
//  through `update_event_member_fields`.
//
//  The bottom of the sheet is the way out: `Cancel this night` asks
//  first, then calls `cancel_event`, which gives every seat deposit
//  back before the night goes away. A cancelled night costs nobody
//  their deposit.
//
//  Presented from the BriefingSlot's "Edit details" affordance.
//  Empty fields clear the stored value.
//

import SwiftUI

struct EditEventSheet: View {
    let event: Event

    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var playedAt: Date
    @State private var venue: String
    @State private var note: String
    @State private var isSaving: Bool = false
    @State private var isCancelling: Bool = false
    @State private var errorMessage: String?
    @State private var showCancelConfirm: Bool = false

    init(event: Event) {
        self.event = event
        _name = State(initialValue: event.name)
        _playedAt = State(initialValue: event.playedAt)
        _venue = State(initialValue: event.venue ?? "")
        _note = State(initialValue: event.hostNote ?? "")
    }

    /// A night that has already started cannot be moved: the server
    /// refuses a date in the past.
    private var hasStarted: Bool {
        event.playedAt <= Date()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                }

                if hasStarted {
                    Section {
                        LabeledContent("When") {
                            Text(event.playedAt, format: .dateTime.weekday().day().month().hour().minute())
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                        }
                    } header: {
                        Text("When")
                    } footer: {
                        Text("A night cannot be moved once it has started.")
                    }
                } else {
                    Section {
                        DatePicker(
                            "When",
                            selection: $playedAt,
                            in: Date()...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .tint(Theme.Palette.accent)
                    } header: {
                        Text("When")
                    }
                }

                Section {
                    TextField("Venue", text: $venue)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Venue")
                } footer: {
                    Text("Leave blank to clear.")
                }

                Section {
                    TextField(
                        "Note for the table",
                        text: $note,
                        axis: .vertical
                    )
                    .lineLimit(2...4)
                    .onChange(of: note) { _, newValue in
                        if newValue.count > 280 {
                            note = String(newValue.prefix(280))
                        }
                    }
                } header: {
                    Text("Note")
                } footer: {
                    Text("A short note for the table: venue quirks, what to bring, house rules. \(note.count)/280")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.loss)
                    }
                }

                // S3.4 — the destructive way out. It sits at the
                // bottom of the sheet, away from the fields, and it
                // asks before it cancels: a night is a plan for
                // other people.
                Section {
                    Button(role: .destructive) {
                        showCancelConfirm = true
                    } label: {
                        HStack {
                            Text("Cancel this night")
                                .font(Theme.Typography.body.weight(.semibold))
                            Spacer()
                            if isCancelling {
                                ProgressView()
                                    .tint(Theme.Palette.loss)
                            }
                        }
                    }
                    .disabled(isCancelling || isSaving)
                } footer: {
                    Text("Cancels the night for everyone in the room.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Edit night")
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
                    .disabled(isSaving || isCancelling)
                    .tint(Theme.Palette.accent)
                }
            }
            .confirmationDialog(
                "Cancel \(event.name)?",
                isPresented: $showCancelConfirm,
                titleVisibility: .visible
            ) {
                Button("Cancel this night", role: .destructive) {
                    Task { await cancelNight() }
                }
                Button("Keep it", role: .cancel) {}
            } message: {
                Text("Everyone's seat and deposit goes back.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVenue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "The night needs a name."
            return
        }
        do {
            // fx30 — moving a night keeps its name in step with its time
            // when the name is still the generated default. The old
            // default is read off the OLD `playedAt`; the new one off
            // the picker. A name the host typed is never touched.
            let timeChanged = !hasStarted && abs(playedAt.timeIntervalSince(event.playedAt)) > 1
            let stillTheOldDefault = trimmedName == event.name
                && event.name == EventDefaultName.name(for: event.playedAt)
            let resolvedName = timeChanged && stillTheOldDefault
                ? EventDefaultName.name(for: playedAt)
                : trimmedName
            if resolvedName != event.name {
                try await roomService.updateEventName(eventId: event.id, name: resolvedName)
            }
            if timeChanged {
                try await roomService.updateEventPlayedAt(eventId: event.id, playedAt: playedAt)
            }
            if trimmedVenue != (event.venue ?? "") || trimmedNote != (event.hostNote ?? "") {
                try await roomService.updateEventMemberFields(
                    eventId: event.id,
                    note: trimmedNote.isEmpty ? nil : trimmedNote,
                    venue: trimmedVenue.isEmpty ? nil : trimmedVenue
                )
            }
            await roomService.eventDidChange(eventId: event.id)
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    private func cancelNight() async {
        guard !isCancelling else { return }
        isCancelling = true
        errorMessage = nil
        defer { isCancelling = false }
        do {
            try await roomService.cancelEvent(eventId: event.id)
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
