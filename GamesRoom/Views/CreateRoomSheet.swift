//
//  CreateRoomSheet.swift
//  GamesRoom
//
//  Track P0.2 — host-side room creation.
//
//  Presented from `RoomPage`'s empty-state CTA when the signed-in
//  user has no rooms. Three inputs the host cares about for V0.8:
//
//    1. Room name — free text, trimmed, required (1–60 chars).
//    2. Mascot name — free text, trimmed, defaults to "Felty".
//    3. Mascot personality + political ideology — pickers, seeded
//       to the V0.8 defaults (professional / order). The host can
//       override; the Room page's mascot footer caption reflects
//       the choice immediately on next render.
//
//  Bonus defaults to 200 — the per-room migration 018 default.
//  The V0.26 feature toggles are seeded to V0.8 defaults (true
//  except calendarAutoAddHost). The host can edit every toggle
//  from Room Settings after creation; this sheet is the
//  happy-path minimum.
//
//  Save fires `RoomService.createRoom(...)`, which the service
//  layer routes through the store to either Supabase (production)
//  or the in-memory fake (previews / dev without Supabase).
//  Success dismisses the sheet and the parent `RoomPage` re-renders
//  with the new room at the top of the list (eager refresh in
//  the service).
//

import SwiftUI

struct CreateRoomSheet: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    @State private var name: String = ""
    @State private var mascotName: String = "Felty"
    @State private var mascotPersonality: MascotPersonality = .professional
    @State private var mascotIdeology: MascotPoliticalIdeology = .order
    @State private var joinStartingBonus: Int = 200

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Room name",
                        text: $name,
                        prompt: Text("Friday night card room")
                    )
                    .textInputAutocapitalization(.words)
                } header: {
                    Text("Name")
                } footer: {
                    Text("Anyone with the join code sees this. Keep it human-typable.")
                }

                Section {
                    TextField(
                        "Mascot name",
                        text: $mascotName,
                        prompt: Text("Felty")
                    )
                    Picker("Personality", selection: $mascotPersonality) {
                        ForEach(MascotPersonality.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    Picker("Politics", selection: $mascotIdeology) {
                        ForEach(MascotPoliticalIdeology.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                } header: {
                    Text("Mascot")
                } footer: {
                    Text("The mascot narrates recaps and surfaces briefings.")
                }

                Section {
                    Stepper(
                        "Starting bonus: \(joinStartingBonus) pts",
                        value: $joinStartingBonus,
                        in: 0...1000,
                        step: 50
                    )
                } header: {
                    Text("Operations")
                } footer: {
                    Text("Points each new member starts with. You can edit later from Room Settings.")
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
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await save() }
                    }
                    .disabled(isSaving || trimmedName.isEmpty)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Validation

    /// Trimmed room name — empty ⇒ the Create button is disabled.
    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Save

    private func save() async {
        guard !isSaving else { return }
        let resolvedName = trimmedName
        let resolvedMascot = mascotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else {
            errorMessage = "Give the room a name."
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            _ = try await roomService.createRoom(
                name: resolvedName,
                mascotName: resolvedMascot.isEmpty ? "Felty" : resolvedMascot,
                mascotPersonality: mascotPersonality,
                mascotPoliticalIdeology: mascotIdeology,
                joinStartingBonus: joinStartingBonus
            )
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}