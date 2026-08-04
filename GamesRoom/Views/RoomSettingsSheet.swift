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

    // Host journal field (P1.5). Bounded to 280 chars at the SQL
    // layer (migration 036); the form view counts characters so the
    // host sees when they're approaching the cap.
    @State private var hostJournal: String

    // P1.1 — roster surface state. Loads the room's members on
    // appear so the host sees who's at the table without leaving
    // the settings sheet.
    @State private var roster: [Member] = []
    @State private var isRosterLoading: Bool = false

    // P0.2 — share-code surface state. Generated on demand from the
    // host's gear; not auto-shown so the host doesn't accidentally
    // share a stale code.
    @State private var shareCode: String?
    @State private var isGeneratingCode: Bool = false

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
        _hostJournal = State(initialValue: room.hostJournal ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                mascotSection
                operationsSection
                featureTogglesSection
                hostJournalSection
                shareCodeSection
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
        .task {
            // P1.1 — load the room's members on first appear so
            // the roster surface renders without a manual refresh.
            await loadRoster()
        }
    }

    // MARK: - Async actions (P1.1 roster + P0.2 share code)

    /// Loads the room's roster into the local `@State`. Calls the
    /// existing `RoomService.loadRoomMembers(roomId:)` which routes
    /// through the store to Supabase or the in-memory fake.
    private func loadRoster() async {
        isRosterLoading = true
        defer { isRosterLoading = false }
        roster = await roomService.loadRoomMembers(roomId: room.id)
    }

    /// Mints a fresh six-character join code via
    /// `RoomService.generateJoinCode(roomId:)`. Updates the
    /// `shareCode` `@State` so the settings sheet surfaces it.
    /// Throws on server errors (non-host writes) — those surface
    /// via the inline `errorMessage` path.
    private func generateShareCode() async {
        guard !isGeneratingCode else { return }
        isGeneratingCode = true
        defer { isGeneratingCode = false }
        do {
            let code = try await roomService.generateJoinCode(roomId: room.id)
            shareCode = code
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
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

    // P1.5 — host observation journal. One bounded text field
    // surfaced off the main path; member cannot edit.
    private var hostJournalSection: some View {
        Section {
            TextField(
                "Host notes for this room",
                text: $hostJournal,
                axis: .vertical
            )
            .lineLimit(2...6)
            .onChange(of: hostJournal) { _, newValue in
                // Hard-clamp to 280 chars at the form layer so the
                // host never sees a server rejection. Mirrors the
                // SQL `check (char_length(host_journal) <= 280)`.
                if newValue.count > 280 {
                    hostJournal = String(newValue.prefix(280))
                }
            }
        } header: {
            HStack {
                Text("Host journal")
                Spacer()
                Text("\(hostJournal.count)/280")
                    .font(Theme.Typography.footnote.monospacedDigit())
                    .foregroundStyle(hostJournal.count >= 260
                                     ? Theme.Palette.accent
                                     : Theme.Palette.primaryText.opacity(0.45))
            }
        } footer: {
            Text("A short note visible only to hosts — venue quirks, recurring house rules, who's hosting next.")
        }
    }

    // P0.2 — invite-code share surface. Host can mint a fresh
    // six-character code that any signed-in user can redeem to
    // join the room. Codes are case-insensitive on input and
    // single-use on the server.
    private var shareCodeSection: some View {
        Section {
            HStack {
                if isGeneratingCode {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Generating…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                } else if let shareCode {
                    Text(shareCode)
                        .font(Theme.Typography.title.monospaced())
                        .foregroundStyle(Theme.Palette.primaryText)
                        .tracking(2)
                } else {
                    Text("Tap to mint a fresh code")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                Spacer()
                Button {
                    Task { await generateShareCode() }
                } label: {
                    Image(systemName: shareCode == nil ? "plus.circle" : "arrow.clockwise")
                        .foregroundStyle(Theme.Palette.accent)
                }
                .disabled(isGeneratingCode)
                .accessibilityLabel(Text("Generate fresh join code"))
            }
        } header: {
            Text("Invite code")
        } footer: {
            Text("Share the six-character code with a friend. Codes are one-use; mint a fresh one for each new member.")
        }
    }

    // P1.1 — member roster surface. Loads the room's members on
    // appear; the host sees role + display name without leaving
    // the settings sheet.
    private var membersSection: some View {
        Section("Members") {
            if isRosterLoading && roster.isEmpty {
                HStack {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Loading members…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            } else if roster.isEmpty {
                Text("No members yet. Share the invite code above.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            } else {
                ForEach(roster, id: \.id) { member in
                    HStack {
                        Text(member.displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text(member.role == .host ? "Host" : "Member")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(member.role == .host
                                             ? Theme.Palette.accent
                                             : Theme.Palette.primaryText.opacity(0.55))
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Fires `RoomService.updateRoom(...)` with every form value
    /// plus the P1.5 host journal via `RoomService.updateHostJournal(...)`.
    /// On success the rooms-list cache in `RoomService` is
    /// refreshed by the service, the sheet dismisses, and the host
    /// sees the new mascot name + operations immediately on the
    /// Rooms page. On failure the inline `errorMessage` replaces
    /// the dismiss path so the host can edit and retry without
    /// losing input. The two writes run sequentially because both
    /// must succeed for the form to be considered saved; the
    /// journal write is skipped if the settings write throws.
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
                // P1.5: persist the journal separately. Empty string
                // → nil so the SQL column stores NULL, which the
                // iOS decoder collapses to nil on read-back.
                let trimmedJournal = hostJournal.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await roomService.updateHostJournal(
                    roomId: room.id,
                    journal: trimmedJournal.isEmpty ? nil : trimmedJournal
                )
                dismiss()
            } catch {
                errorMessage = (error as NSError).localizedDescription
            }
        }
    }
}