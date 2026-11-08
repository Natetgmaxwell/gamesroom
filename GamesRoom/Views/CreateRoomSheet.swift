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
//  v1.1 — Create sits in the toolbar (`.confirmationAction`, as in
//  JoinRoomSheet); mascot + bonus fold into a collapsed "Customise"
//  section. Success fires `Haptics.success()`.
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
//  Success dismisses the sheet and the parent `RoomPage` opens the
//  new room (S3.6 — the host lands in the room they just made, not
//  back on the list).
//

import SwiftUI

struct CreateRoomSheet: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    /// S3.6 — called with the new room's id once the room exists,
    /// so the parent can open it straight away instead of dropping
    /// the host back on the rooms list.
    var onCreated: ((UUID) -> Void)?

    @State private var name: String = ""
    @State private var mascotName: String = "Tally"
    @State private var mascotPersonality: MascotPersonality = .professional
    @State private var mascotIdeology: MascotPoliticalIdeology = .order
    @State private var joinStartingBonus: Int = 200

    @State private var showCustomise: Bool = false
    @State private var isSaving: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

                // v1.1 — one screen: the defaults work, so the
                // mascot and starting bonus fold into "Customise".
                Section {
                    Button {
                        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                            showCustomise.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Customise")
                                .foregroundStyle(Theme.Palette.primaryText)
                            Spacer()
                            Text("\(resolvedMascotName) · \(joinStartingBonus) pts")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Image(systemName: Theme.Icon.chevronRight)
                                .font(Theme.Typography.caption.weight(.semibold))
                                .foregroundStyle(Theme.Palette.tertiaryText)
                                .rotationEffect(.degrees(showCustomise ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                    }
                    .accessibilityValue(Text(showCustomise ? "Expanded" : "Collapsed"))
                } footer: {
                    if !showCustomise {
                        Text("Mascot and starting bonus. Change them any time in Room settings.")
                    }
                }

                if showCustomise {
                    MascotConfigSection(
                        name: $mascotName,
                        personality: $mascotPersonality,
                        ideology: $mascotIdeology
                    )

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
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .formStyle(.grouped)
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
                    Button("Create") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || isSaving)
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

    private var resolvedMascotName: String {
        let trimmed = mascotName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Tally" : trimmed
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
            let roomId = try await roomService.createRoom(
                name: resolvedName,
                mascotName: resolvedMascot.isEmpty ? "Tally" : resolvedMascot,
                mascotPersonality: mascotPersonality,
                mascotPoliticalIdeology: mascotIdeology,
                joinStartingBonus: joinStartingBonus
            )
            Haptics.success()
            dismiss()
            // S3.6 — the sheet closes first, then the parent opens
            // the new room. Pushing while the sheet is still on
            // screen gets swallowed by the dismissal.
            try? await Task.sleep(nanoseconds: 400_000_000)
            onCreated?(roomId)
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}