//
//  RoomSettingsSheet.swift
//  GamesRoom
//
//  Host-only room settings. Three sections:
//
//    1. Mascot       — name, personality, ideology, narration toggle
//    2. Operations   — maxSeats, memberInviteQuota, joinStartingBonus
//    3. Feature toggles — briefing48hEnabled, calendarAutoAddHost,
//                        socialPreferencesEnabled
//
//  Save fires `RoomService.updateRoom(...)` with every form value
//  (per migration 020 + the V0.8 settings contract), surfaces the
//  server-canonical `Room` back into the rooms-list cache, and
//  dismisses on success. On failure the inline error replaces the
//  dismiss path so the host can edit and retry without losing
//  input. The host-only gate is enforced by the caller
//  (`RoomPage`'s settings gear is conditional on `room.userRole
//  .isHost`).
//

import SwiftUI

struct RoomSettingsSheet: View {
    let room: Room

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    // Form-level state — seeded from the `room` passed in.
    @State private var mascotName: String
    @State private var mascotPersonality: MascotPersonality
    @State private var mascotIdeology: MascotPoliticalIdeology
    @State private var socialNarrationEnabled: Bool
    @State private var maxSeats: Int
    @State private var memberInviteQuota: Int
    @State private var joinStartingBonus: Int
    @State private var briefing48hEnabled: Bool
    @State private var calendarAutoAddHost: Bool
    @State private var socialPreferencesEnabled: Bool

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(room: Room) {
        self.room = room
        _mascotName = State(initialValue: room.mascotName)
        _mascotPersonality = State(initialValue: room.mascotPersonality)
        _mascotIdeology = State(initialValue: room.mascotPoliticalIdeology)
        _socialNarrationEnabled = State(initialValue: room.socialNarrationEnabled)
        _maxSeats = State(initialValue: room.maxSeats)
        _memberInviteQuota = State(initialValue: room.memberInviteQuota)
        _joinStartingBonus = State(initialValue: room.joinStartingBonus)
        _briefing48hEnabled = State(initialValue: room.briefing48hEnabled)
        _calendarAutoAddHost = State(initialValue: room.calendarAutoAddHost)
        _socialPreferencesEnabled = State(initialValue: room.socialPreferencesEnabled)
    }

    var body: some View {
        NavigationStack {
            Form {
                mascotSection
                operationsSection
                featureTogglesSection
                membersSection
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                                    .tint(Theme.Palette.accent)
                            } else {
                                Text("Save")
                                    .font(Theme.Typography.body.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.accent)
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSaving)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Room settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Sections

    private var mascotSection: some View {
        Section("Mascot") {
            TextField("Name", text: $mascotName)
                .font(Theme.Typography.body)
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
            Toggle("Mascot narrates recaps", isOn: $socialNarrationEnabled)
        }
    }

    private var operationsSection: some View {
        Section("Operations") {
            Stepper("Max seats: \(maxSeats)", value: $maxSeats, in: 2...20)
            Stepper("Invite quota: \(memberInviteQuota)", value: $memberInviteQuota, in: 0...20)
            Stepper("Starting bonus: \(joinStartingBonus) pts", value: $joinStartingBonus, in: 0...1000, step: 50)
        }
    }

    private var featureTogglesSection: some View {
        Section("Features") {
            Toggle("48-hour briefing push", isOn: $briefing48hEnabled)
            Toggle("Auto-add to host calendar", isOn: $calendarAutoAddHost)
            Toggle("Members can set preferences", isOn: $socialPreferencesEnabled)
        }
    }

    private var membersSection: some View {
        Section("Members") {
            // v0.8 stub — the roster list comes from RoomService.getRoomMembers
            // (deferred to V0.8.1). Each row would expose: name, role chip,
            // remove button (host only).
            Text("Roster list renders here in v0.8.1.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.5))
        }
    }

    // MARK: - Actions

    /// Fires `RoomService.updateRoom(...)` with every form value.
    /// On success the rooms-list cache in `RoomService` is
    /// refreshed by the service, the sheet dismisses, and the host
    /// sees the new mascot name + operations immediately on the
    /// Rooms page. On failure the inline `errorMessage` replaces
    /// the dismiss path so the host can edit and retry without
    /// losing input.
    private func save() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        Task {
            defer { isSaving = false }
            do {
                _ = try await roomService.updateRoom(
                    id: room.id,
                    name: mascotName,
                    mascotName: mascotName,
                    mascotPersonality: mascotPersonality,
                    mascotPoliticalIdeology: mascotIdeology,
                    maxSeats: maxSeats,
                    memberInviteQuota: memberInviteQuota,
                    joinStartingBonus: joinStartingBonus,
                    socialNarrationEnabled: socialNarrationEnabled,
                    briefing48hEnabled: briefing48hEnabled,
                    calendarAutoAddHost: calendarAutoAddHost,
                    socialPreferencesEnabled: socialPreferencesEnabled
                )
                dismiss()
            } catch {
                errorMessage = (error as NSError).localizedDescription
            }
        }
    }
}