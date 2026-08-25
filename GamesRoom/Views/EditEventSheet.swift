//
//  EditEventSheet.swift
//  GamesRoom
//
//  Track W2.4 — member-side event edit.
//
//  Any room member can edit the event's pre-play note + venue
//  while the event is still in the future. The RPC
//  (`update_event_member_fields`, migration 050) derives room
//  scope from `events.id` (F-IDENT-01) — the caller's membership
//  claim is never trusted for scope.
//
//  Presented from the BriefingSlot's "Edit details" affordance.
//  Empty fields clear the stored value.
//

import SwiftUI

struct EditEventSheet: View {
    let event: Event

    @EnvironmentObject private var roomService: RoomService
    @Environment(\.dismiss) private var dismiss

    @State private var note: String
    @State private var venue: String
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(event: Event) {
        self.event = event
        _note = State(initialValue: event.hostNote ?? "")
        _venue = State(initialValue: event.venue ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Venue quirks, what to bring, house rules. \(note.count)/280")
                }

                Section {
                    TextField("Venue", text: $venue)
                        .textInputAutocapitalization(.words)
                } header: {
                    Text("Venue")
                } footer: {
                    Text("Leave blank to clear.")
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
            .navigationTitle("Edit event")
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
                    .disabled(isSaving)
                    .tint(Theme.Palette.accent)
                }
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
        do {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedVenue = venue.trimmingCharacters(in: .whitespacesAndNewlines)
            try await roomService.updateEventMemberFields(
                eventId: event.id,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                venue: trimmedVenue.isEmpty ? nil : trimmedVenue
            )
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
