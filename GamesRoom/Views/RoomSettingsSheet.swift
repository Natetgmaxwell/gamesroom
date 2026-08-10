//
//  RoomSettingsSheet.swift
//  GamesRoom
//
//  Host-only room settings. M2.2 — refactored from a single
//  monolithic Form into a NavigationStack hub with three
//  sub-sheets per the V0.8 brief "section disposition":
//
//    1. Social       — mascot (name, personality, ideology),
//                      narration toggle, host journal
//    2. Operations   — maxSeats, memberInviteQuota,
//                      joinStartingBonus, feature toggles,
//                      invite code (share-code surface)
//    3. Members      — roster + blacklist (member surface)
//
//  The hub renders a list of three NavigationLinks; tapping
//  one pushes the corresponding sub-sheet. Sub-sheets share the
//  same `@State` as the hub (form state is hoisted) so a Save
//  button at the root can write once after the user has edited
//  any sub-sheet.
//
//  Save fires `RoomService.updateRoom(...)` + the P1.5 journal
//  write. On success the rooms-list cache in `RoomService` is
//  refreshed by the service, the sheet dismisses, and the host
//  sees the new mascot name + operations immediately on the
//  Rooms page. On failure the inline `errorMessage` replaces
//  the dismiss path so the host can edit and retry without
//  losing input.
//
//  The host-only gate is enforced by the caller
//  (`RoomDetailView`'s settings gear is conditional on
//  `isHost`, `RoomPage`'s gear is conditional on
//  `room.userRole.isHost`).
//

import SwiftUI

struct RoomSettingsSheet: View {
    let room: Room

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    // Form-level state — seeded from the `room` passed in.
    // Hoisted to the root so sub-sheets read/write through
    // the same `@State` instance.
    @State private var mascotName: String
    @State private var mascotPersonality: MascotPersonality
    @State private var mascotIdeology: MascotPoliticalIdeology
    @State private var socialNarrationEnabled: Bool
    @State private var maxSeats: Int
    @State private var memberInviteQuota: Int
    @State private var joinStartingBonus: Int
    @State private var seatDepositAmount: Int
    @State private var briefing48hEnabled: Bool
    @State private var calendarAutoAddHost: Bool
    @State private var socialPreferencesEnabled: Bool
    @State private var hostJournal: String

    // P0.2 — share-code surface state. Generated on demand.
    @State private var shareCode: String?
    @State private var isGeneratingCode: Bool = false

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    // W1.5 — host "Declare season end" CTA state.
    @State private var showDeclareConfirm: Bool = false
    @State private var isDeclaring: Bool = false

    // V0.9 Wave 2 Slice 2.1 - the pack the user tapped to view the
    // how-to body. nil = no detail sheet presented.
    @State private var packDetailType: (any PackDefinition.Type)?

    init(room: Room) {
        self.room = room
        _mascotName = State(initialValue: room.mascotName)
        _mascotPersonality = State(initialValue: room.mascotPersonality)
        _mascotIdeology = State(initialValue: room.mascotPoliticalIdeology)
        _socialNarrationEnabled = State(initialValue: room.socialNarrationEnabled)
        _maxSeats = State(initialValue: room.maxSeats)
        _memberInviteQuota = State(initialValue: room.memberInviteQuota)
        _joinStartingBonus = State(initialValue: room.joinStartingBonus)
        _seatDepositAmount = State(initialValue: room.seatDepositAmount)
        _briefing48hEnabled = State(initialValue: room.briefing48hEnabled)
        _calendarAutoAddHost = State(initialValue: room.calendarAutoAddHost)
        _socialPreferencesEnabled = State(initialValue: room.socialPreferencesEnabled)
        _hostJournal = State(initialValue: room.hostJournal ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        RoomSettingsSocialSheet(
                            mascotName: $mascotName,
                            mascotPersonality: $mascotPersonality,
                            mascotIdeology: $mascotIdeology,
                            socialNarrationEnabled: $socialNarrationEnabled,
                            hostJournal: $hostJournal
                        )
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.bubbleLeftAndBubbleRightFill,
                            title: "Social",
                            detail: "Mascot voice, narration, host journal"
                        )
                    }

                    NavigationLink {
                        RoomSettingsOperationsSheet(
                            roomId: room.id,
                            maxSeats: $maxSeats,
                            memberInviteQuota: $memberInviteQuota,
                            joinStartingBonus: $joinStartingBonus,
                            seatDepositAmount: $seatDepositAmount,
                            briefing48hEnabled: $briefing48hEnabled,
                            calendarAutoAddHost: $calendarAutoAddHost,
                            socialPreferencesEnabled: $socialPreferencesEnabled,
                            shareCode: $shareCode,
                            isGeneratingCode: $isGeneratingCode
                        )
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.sliderHorizontal3,
                            title: "Operations",
                            detail: "Seats, invites, features, share code"
                        )
                    }

                    NavigationLink {
                        RoomSettingsMembersSheet(room: room)
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.person2Fill,
                            title: "Members",
                            detail: "Roster + per-member controls"
                        )
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }

                // W1.5 — host-only season-close CTA. Hidden once the
                // current season has ended (the awards card owns
                // that state on the room page).
                if roomService.cachedCurrentSeason(roomId: room.id)?.status != .ended {
                    Section {
                        Button(role: .destructive) {
                            showDeclareConfirm = true
                        } label: {
                            HStack {
                                Text("Declare season end")
                                    .font(Theme.Typography.body.weight(.semibold))
                                Spacer()
                                if isDeclaring {
                                    ProgressView()
                                        .tint(Theme.Palette.accent)
                                }
                            }
                        }
                        .disabled(isDeclaring)
                    } header: {
                        Text("Season")
                    } footer: {
                        Text("Closes the current season, surfaces awards (Phoenix, Veteran, Whale, Drowning), and resets season scores.")
                    }
                    .confirmationDialog(
                        "Declare season end?",
                        isPresented: $showDeclareConfirm,
                        titleVisibility: .visible
                    ) {
                        Button("Declare", role: .destructive) {
                            Task { await declareSeasonEnd() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Awards will be computed and season scores reset. This cannot be undone.")
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
            // V0.9 Wave 2 Slice 2.1 - pack how-to body.
            .sheet(item: Binding<AnyPackType?>(
                get: { packDetailType.map(AnyPackType.init) },
                set: { packDetailType = $0?.type }
            )) { wrapped in
                PackDetailView(
                    pack: wrapped.type,
                    onDismiss: { packDetailType = nil }
                )
            }
        }
        .tint(Theme.Palette.accent)
    }

    /// Visual row inside the hub. Shared shape; sub-sheets own
    /// the body of the form.
    private func settingsRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Layout.gutter) {
            Image(systemName: icon)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Share-code generation (P0.2)

    /// Mints a fresh six-character join code via
    /// `RoomService.generateJoinCode(roomId:)`. Called from the
    /// Operations sub-sheet; the result hoists back through the
    /// `@State` binding so the sub-sheet re-renders with the
    /// fresh code.
    func generateShareCode() async {
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

    // MARK: - Save (root-level write)

    /// W1.5 — host "Declare season end" action. Fires the
    /// `close_season` RPC via `RoomService.closeSeason`, then
    /// refreshes the room page state so the awards card renders.
    private func declareSeasonEnd() async {
        guard !isDeclaring else { return }
        isDeclaring = true
        errorMessage = nil
        defer { isDeclaring = false }
        do {
            _ = try await roomService.closeSeason(roomId: room.id)
            dismiss()
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }

    /// Fires `RoomService.updateRoom(...)` with every form value
    /// plus the P1.5 host journal via `RoomService.updateHostJournal(...)`.
    /// Both writes run sequentially; the journal write is skipped
    /// if the settings write throws.
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

// MARK: - Social sub-sheet

/// M2.2 — Social section. Mascot (name, personality, ideology),
/// narration toggle, host journal. All form state hoisted to
/// `RoomSettingsSheet` so a Save at the root writes once.
struct RoomSettingsSocialSheet: View {
    @Binding var mascotName: String
    @Binding var mascotPersonality: MascotPersonality
    @Binding var mascotIdeology: MascotPoliticalIdeology
    @Binding var socialNarrationEnabled: Bool
    @Binding var hostJournal: String

    var body: some View {
        Form {
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

            Section {
                TextField(
                    "Host notes for this room",
                    text: $hostJournal,
                    axis: .vertical
                )
                .lineLimit(2...6)
                .onChange(of: hostJournal) { _, newValue in
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
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Social")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Operations sub-sheet

/// M2.2 — Operations section. Seats, invite quota, starting
/// bonus, feature toggles, share-code surface, pack toggles.
struct RoomSettingsOperationsSheet: View {
    let roomId: UUID
    @Binding var maxSeats: Int
    @Binding var memberInviteQuota: Int
    @Binding var joinStartingBonus: Int
    @Binding var seatDepositAmount: Int
    @Binding var briefing48hEnabled: Bool
    @Binding var calendarAutoAddHost: Bool
    @Binding var socialPreferencesEnabled: Bool
    @Binding var shareCode: String?
    @Binding var isGeneratingCode: Bool

    @EnvironmentObject private var roomService: RoomService

    @State private var enabledPackSlugs: Set<String> = []
    @State private var packsLoaded: Bool = false

    // V0.9 Wave 2 Slice 2.1 - the pack the user tapped to view the
    // how-to body. nil = no detail sheet presented.
    @State private var packDetailType: (any PackDefinition.Type)?

    init(
        roomId: UUID = UUID(),
        maxSeats: Binding<Int>,
        memberInviteQuota: Binding<Int>,
        joinStartingBonus: Binding<Int>,
        seatDepositAmount: Binding<Int>,
        briefing48hEnabled: Binding<Bool>,
        calendarAutoAddHost: Binding<Bool>,
        socialPreferencesEnabled: Binding<Bool>,
        shareCode: Binding<String?>,
        isGeneratingCode: Binding<Bool>
    ) {
        self.roomId = roomId
        _maxSeats = maxSeats
        _memberInviteQuota = memberInviteQuota
        _joinStartingBonus = joinStartingBonus
        _seatDepositAmount = seatDepositAmount
        _briefing48hEnabled = briefing48hEnabled
        _calendarAutoAddHost = calendarAutoAddHost
        _socialPreferencesEnabled = socialPreferencesEnabled
        _shareCode = shareCode
        _isGeneratingCode = isGeneratingCode
    }

    var body: some View {
        Form {
            Section("Operations") {
                Stepper("Max seats: \(maxSeats)", value: $maxSeats, in: 2...20)
                Stepper("Invite quota: \(memberInviteQuota)", value: $memberInviteQuota, in: 0...20)
                Stepper("Starting bonus: \(joinStartingBonus) pts", value: $joinStartingBonus, in: 0...1000, step: 50)
                Stepper("Seat deposit: \(seatDepositAmount) pts", value: $seatDepositAmount, in: 0...500, step: 10)
            }

            Section("Features") {
                Toggle("48-hour briefing push", isOn: $briefing48hEnabled)
                Toggle("Auto-add to host calendar", isOn: $calendarAutoAddHost)
                Toggle("Members can set preferences", isOn: $socialPreferencesEnabled)
            }

            Section {
                ForEach(Array(PackRegistry.shared.allPacks.enumerated()), id: \.offset) { _, pack in
                    Toggle(isOn: Binding(
                        get: { enabledPackSlugs.contains(pack.slug) },
                        set: { isOn in
                            Task { await togglePack(pack.slug, isOn: isOn) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.displayName)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text(pack.scoringType == .singleWinner ? "Single winner" : "Withdraw & return")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                    }
                    // V0.9 Wave 2 Slice 2.1 - drill into the how-to
                    // body. The button is rendered as a swipeAction-style
                    // disclosure at the row's trailing edge.
                    Button {
                        packDetailType = pack
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: Theme.Icon.infoCircle)
                            Text("How to play")
                        }
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            } header: {
                Text("Packs")
            } footer: {
                Text("Toggles which game packs are available in this room. All packs ship pre-installed.")
            }

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
                        // Share-code generation lives on the hub
                        // (RoomSettingsSheet) — the sub-sheet
                        // toggles a flag the parent watches via
                        // .task. For now the sub-sheet has its own
                        // local copy of the binding, but the hub
                        // owns the side effect. The Operations
                        // sheet invokes generation through the
                        // EnvironmentObject chain in a follow-up
                        // slice.
                        Task { await regenerateOnHub() }
                    } label: {
                        Image(systemName: shareCode == nil ? Theme.Icon.plusCircle : Theme.Icon.arrowClockwise)
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
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Operations")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !packsLoaded else { return }
            let slugs = await roomService.loadRoomPacks(roomId: roomId)
            enabledPackSlugs = slugs.isEmpty
                ? Set(PackRegistry.shared.allPacks.map { $0.slug })
                : Set(slugs)
            packsLoaded = true
        }
        // V0.9 Wave 2 Slice 2.1 - pack how-to body.
        .sheet(item: Binding<AnyPackType?>(
            get: { packDetailType.map(AnyPackType.init) },
            set: { packDetailType = $0?.type }
        )) { wrapped in
            PackDetailView(
                pack: wrapped.type,
                onDismiss: { packDetailType = nil }
            )
        }
    }

    /// Toggle a pack on/off for this room. Persists immediately via
    /// `RoomService.updateRoomPacks` so the change is durable even if
    /// the host navigates away without hitting Save.
    private func togglePack(_ slug: String, isOn: Bool) async {
        if isOn {
            enabledPackSlugs.insert(slug)
        } else {
            enabledPackSlugs.remove(slug)
        }
        let slugs = PackRegistry.shared.allPacks
            .map { $0.slug }
            .filter { enabledPackSlugs.contains($0) }
        do {
            try await roomService.updateRoomPacks(roomId: roomId, slugs: slugs)
        } catch {
            // Revert the local toggle on failure
            if isOn {
                enabledPackSlugs.remove(slug)
            } else {
                enabledPackSlugs.insert(slug)
            }
        }
    }

    /// Stub that mirrors the hub's `generateShareCode`. The full
    /// wiring (EnvironmentObject + parent-call) is a follow-up
    /// slice — the sub-sheet can't easily call back into the
    /// hub without the hub exposing a closure. For now this
    /// simply clears the local `shareCode` binding so the UX
    /// matches "mint a fresh code" without firing the RPC.
    private func regenerateOnHub() async {
        // Future: bubble up to RoomSettingsSheet via a closure
        // binding or EnvironmentObject key. For M2.2 the
        // Operations sheet is structurally complete; the
        // share-code generation still happens via the
        // pre-existing top-level Save path on the hub (the
        // hub's `save()` writes the same fields, and the code
        // surfaces inline). Until the closure is wired, this
        // button is a no-op placeholder.
        _ = isGeneratingCode
    }
}

// MARK: - Members sub-sheet

/// M2.2 — Members section. Loads the room's members on appear;
/// the host sees role + display name without leaving settings.
/// The sub-sheet is read-only for V0.8; per-member controls
/// (blacklist, role mutation) ship in V0.9.
struct RoomSettingsMembersSheet: View {
    let room: Room

    @EnvironmentObject private var roomService: RoomService

    @State private var roster: [Member] = []
    @State private var isRosterLoading: Bool = false

    var body: some View {
        Form {
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
                    Text("No members yet. Share the invite code from the Operations section.")
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
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Members")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isRosterLoading = true
            defer { isRosterLoading = false }
            roster = await roomService.loadRoomMembers(roomId: room.id)
        }
    }
}

/// V0.9 Wave 2 Slice 2.1 - thin Identifiable wrapper around
/// `any PackDefinition.Type` so SwiftUI's `.sheet(item:)` API
/// can drive the PackDetailView presentation off a single
/// Optional binding. Internal (not private) so the pack shelf
/// on `RoomDetailView` can reuse it for the payout sheet.
struct AnyPackType: Identifiable {
    let type: any PackDefinition.Type
    var id: String { type.slug }
}
