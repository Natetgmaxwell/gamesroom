//
//  RoomSettingsSheet.swift
//  GamesRoom
//
//  Host-only room settings. Three sections:
//    1. Mascot       — name, personality, ideology, social-narration toggle
//    2. Operations   — maxSeats, memberInviteQuota, joinStartingBonus
//    3. Members      — per-member row with a remove button
//
//  Save is a stub in v0.8 — RoomService.updateRoom is wired in v0.8.1.
//  The hosts-only gate is enforced by the caller (RoomDetailView's
//  toolbar gear button is conditional on `isHost`).
//

import SwiftUI

struct RoomSettingsSheet: View {
    let room: Room

    @Environment(\.dismiss) private var dismiss

    // Form-level state
    @State private var mascotName: String
    @State private var mascotPersonality: MascotPersonality
    @State private var mascotIdeology: MascotPoliticalIdeology
    @State private var socialNarrationEnabled: Bool
    @State private var maxSeats: Int
    @State private var memberInviteQuota: Int
    @State private var joinStartingBonus: Int

    init(room: Room) {
        self.room = room
        _mascotName = State(initialValue: room.mascotName)
        _mascotPersonality = State(initialValue: room.mascotPersonality)
        _mascotIdeology = State(initialValue: room.mascotPoliticalIdeology)
        _socialNarrationEnabled = State(initialValue: room.socialNarrationEnabled)
        _maxSeats = State(initialValue: room.maxSeats)
        _memberInviteQuota = State(initialValue: 3)        // V0.7.1 default, v0.8 doesn't expose yet
        _joinStartingBonus = State(initialValue: room.joinStartingBonus)
    }

    var body: some View {
        NavigationStack {
            Form {
                mascotSection
                operationsSection
                membersSection
                Section {
                    Button("Save", action: save)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
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
                    Text(p.rawValue.capitalized).tag(p)
                }
            }
            Picker("Politics", selection: $mascotIdeology) {
                ForEach(MascotPoliticalIdeology.allCases, id: \.self) { p in
                    Text(p.rawValue.capitalized).tag(p)
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

    private var membersSection: some View {
        Section("Members") {
            // v0.8 stub — the roster list comes from RoomService.getRoomMembers.
            // Each row would expose: name, role chip, remove button (host only).
            Text("Roster list renders here in v0.8.1.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.5))
        }
    }

    // MARK: - Actions

    private func save() {
        // v0.8 stub — real impl calls RoomService.updateRoom in v0.8.1.
        dismiss()
    }
}

// MARK: - Room.maxSeats surface
//
// Room.swift doesn't currently expose maxSeats / memberInviteQuota —
// they're columns in the DB and surface as Feature Toggles for v0.26.
// v0.8 expects them inline on Room. The Settings sheet reads them
// from Room when present and writes them back via updateRoom in v0.8.1.
//
// To keep v0.8 parse-clean until the schema exposes maxSeats on Room,
// we add a non-conflicting computed accessor below.

extension Room {
    /// Room.maxSeats — defaults to 6 (the pre-v0.8 default). The
    /// schema column `rooms.max_seats` is read by RoomService into
    /// this in v0.8.1.
    var maxSeats: Int { 6 }
}
