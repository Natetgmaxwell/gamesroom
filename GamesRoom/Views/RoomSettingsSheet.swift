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
//  same `@State` draft as the hub (form state is hoisted) so a
//  single autosave path can write once the host pauses.
//
//  V0.86 — the per-room host calendar toggle is REMOVED. The
//  calendar mirror moved to a per-user surface
//  (`MemberCalendarSettingsSheet`) reachable from a NavigationLink
//  in the hub's root. The host does not need to enter any room to
//  toggle their own calendar (it's per-user).
//
//  V0.81 — autosave: every edit to the draft restarts a 600ms
//  trailing debounce via `.task(id: draft)`; the write fires
//  `RoomService.updateRoom(...)` + the P1.5 journal write + the
//  W2.6 season-subtitle RPC. `.onDisappear` flushes a pending
//  edit so a swipe-dismiss never loses the last keystroke, and a
//  write that lands while another is in flight is refired after
//  the in-flight one completes (no edit is silently dropped). On
//  success the rooms-list cache in `RoomService` is refreshed by
//  the service and the host sees the new mascot name +
//  operations immediately on the Rooms page. On failure the
//  inline status row shows the error and the next edit retries.
//
//  The host-only gate is enforced by the caller
//  (`RoomDetailView`'s settings gear is conditional on
//  `isHost`, `RoomPage`'s gear is conditional on
//  `room.userRole.isHost`).
//

import SwiftUI

struct RoomSettingsSheet: View {
    let room: Room
    /// W-04 — invoked after a successful delete so the presenter can
    /// pop/dismiss the surrounding navigation (the room is gone from
    /// the service's rooms cache at this point).
    var onRoomDeleted: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var casinoService: CasinoService

    // Form-level state — seeded from the `room` passed in.
    // Hoisted to the root so sub-sheets read/write through
    // the same `@State` instance.
    // V0.45 — kept separate from `mascotName` so settings saves
    // don't clobber `rooms.name` with the mascot name.
    @State private var roomName: String
    @State private var mascotName: String
    @State private var mascotPersonality: MascotPersonality
    @State private var mascotIdeology: MascotPoliticalIdeology
    @State private var socialNarrationEnabled: Bool
    @State private var maxSeats: Int
    @State private var memberInviteQuota: Int
    @State private var joinStartingBonus: Int
    @State private var briefing48hEnabled: Bool
    @State private var socialPreferencesEnabled: Bool
    @State private var autoCloseHours: Int
    @State private var seatDepositAmount: Int
    @State private var seatDepositTrigger: SeatDepositTrigger
    @State private var seatDepositGraceMinutes: Int
    @State private var hostJournal: String

    // P0.2 — share-code surface state. Generated on demand.
    @State private var shareCode: String?
    @State private var isGeneratingCode: Bool = false

    // V0.81 — autosave state. `saveState` drives the status row;
    // `draft` is bumped on every edit so `.task(id:)` restarts the
    // debounce; `writeTask` lets `onDisappear` refire a write that
    // was mid-flight so the newest state is never dropped.
    enum SaveState: Equatable {
        case idle
        case saving
        case saved
        case failed(String)
    }
    @State private var saveState: SaveState = .idle
    @State private var draft = 0
    // V0.81 — true when an edit landed that no write has captured
    // yet. Cleared when a write starts; set again if an edit lands
    // while the write is in flight. Drives the dismiss-time retry.
    @State private var isDirty = false
    @State private var writeTask: Task<Void, Never>?
    // V0.81 — write serialization: at most one writeAll runs at a
    // time. An overlapping call (an edit landed while a write is in
    // flight and the debounce fired again) queues a refire instead
    // of running concurrently — concurrent writes could land out of
    // order and persist stale values.
    @State private var isWriting = false
    @State private var refireAfterWrite = false
    // W2.6 — the server subtitle value seeded on open; the
    // season-subtitle bumper compares against it so seeding never
    // triggers a spurious autosave.
    @State private var seededSeasonSubtitle: String = ""

    // W1.5 — host "Declare season end" CTA state.
    @State private var showDeclareConfirm: Bool = false
    @State private var isDeclaring: Bool = false

    // W-04 — host "Delete room" confirm state (US-04).
    @State private var showDeleteConfirm: Bool = false
    @State private var isDeleting: Bool = false

    // V0.86 — member-facing calendar surface. The sheet is opened
    // from the hub (member-visible), lives outside any specific
    // room — the toggle is per-user.
    @State private var showCalendarSettings: Bool = false

    // W2.6 — season-subtitle host-approval beat. Seeded from the
    // current season; saved via set_season_subtitle on Save.
    @State private var seasonSubtitle: String

    // V0.9 Wave 2 Slice 2.1 - the pack the user tapped to view the
    // how-to body. nil = no detail sheet presented.
    @State private var packDetailType: (any PackDefinition.Type)?

    init(room: Room, onRoomDeleted: (() -> Void)? = nil) {
        self.room = room
        self.onRoomDeleted = onRoomDeleted
        _roomName = State(initialValue: room.name)
        _mascotName = State(initialValue: room.mascotName)
        _mascotPersonality = State(initialValue: room.mascotPersonality)
        _mascotIdeology = State(initialValue: room.mascotPoliticalIdeology)
        _socialNarrationEnabled = State(initialValue: room.socialNarrationEnabled)
        _maxSeats = State(initialValue: room.maxSeats)
        _memberInviteQuota = State(initialValue: room.memberInviteQuota)
        _joinStartingBonus = State(initialValue: room.joinStartingBonus)
        _briefing48hEnabled = State(initialValue: room.briefing48hEnabled)
        _socialPreferencesEnabled = State(initialValue: room.socialPreferencesEnabled)
        _autoCloseHours = State(initialValue: room.autoCloseHours)
        _seatDepositAmount = State(initialValue: room.seatDepositAmount)
        _seatDepositTrigger = State(initialValue: room.seatDepositTrigger)
        _seatDepositGraceMinutes = State(initialValue: room.seatDepositGraceMinutes)
        _hostJournal = State(initialValue: room.hostJournal ?? "")
        _seasonSubtitle = State(initialValue: "")
    }

    var body: some View {
        hubNavigation
    }

    /// V0.95b — NavigationStack + the stack-level modifiers.
    private var hubNavigation: some View {
        NavigationStack {
            hubForm
        }
        // V0.81 — autosave debounce + flush live on the
        // NavigationStack, not the Form: pushing into a sub-sheet
        // disappears the Form (cancelling a `.task` attached
        // there), but the stack survives the push.
        .task(id: draft) {
            guard draft > 0 else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await writeAll()
        }
        .onDisappear {
            // Flush on dismiss so a swipe-away never loses the
            // last edit. If a write was mid-flight, await it and
            // retry when it failed or an edit landed while it was
            // in flight (that edit wasn't captured).
            // (Bumping `draft` here would not work: `.task(id:)`
            // is cancelled as the view disappears.)
            if let writeTask {
                let inFlight = writeTask
                Task {
                    await inFlight.value
                    if needsRetry {
                        await writeAll()
                    }
                }
            } else if draft > 0 {
                Task { await writeAll() }
            }
        }
        .task {
            // W2.6 — seed the subtitle field from the current
            // season once the environment object is available.
            // Remember what we seeded so the bumper doesn't treat
            // the seed as an edit (spurious write on open).
            if seasonSubtitle.isEmpty {
                seededSeasonSubtitle = roomService.cachedCurrentSeason(roomId: room.id)?.subtitle ?? ""
                seasonSubtitle = seededSeasonSubtitle
            }
        }
        .tint(Theme.Palette.accent)
        // V0.86 — member-facing calendar surface. The toggle is
        // per-USER; this sheet is the place where the
        // CalendarService.requestAccess() prompt fires (the
        // BriefingSlot mascot voice line accompanies the system
        // prompt on first launch).
        .sheet(isPresented: $showCalendarSettings) {
            MemberCalendarSettingsSheet(room: room)
                .environmentObject(roomService)
        }
    }

    /// V0.95b — the Form plus its full modifier chain, as ONE
    /// separate type-check unit (Xcode 26.5 SDK budget).
    /// V0.95b — Form + chrome. Separate type-check unit.
    private var formChrome: some View {
        Form {
            hubSections
        }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Room settings")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// V0.95b — toolbar + autosave bumpers + sheets, layered on
    /// formChrome. Splitting the chain keeps each unit inside the
    /// Xcode 26.5 SDK's type-check budget.
    /// V0.95b — toolbar, as its own type-check unit.
    private var toolbarLayer: some View {
        formChrome
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    // V0.81 — autosave means there is nothing to
                    // cancel; Done dismisses after any pending write
                    // has flushed.
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
            }
            // V0.81 — autosave bumpers. Every persisted field
            // restarts the debounce. Attached at the hub so edits
            // made inside the sub-sheets (hoisted bindings) fire
    }

    /// V0.95b — autosave bumpers (every persisted field restarts
    /// the debounce), as its own type-check unit.
    private var bumpersLayer: some View {
        toolbarLayer
            // the same path.
            .onChange(of: mascotName) { _, _ in bumpDraft() }
            .onChange(of: mascotPersonality) { _, _ in bumpDraft() }
            .onChange(of: mascotIdeology) { _, _ in bumpDraft() }
            .onChange(of: socialNarrationEnabled) { _, _ in bumpDraft() }
            .onChange(of: hostJournal) { _, _ in bumpDraft() }
            .onChange(of: maxSeats) { _, _ in bumpDraft() }
            .onChange(of: memberInviteQuota) { _, _ in bumpDraft() }
            .onChange(of: joinStartingBonus) { _, _ in bumpDraft() }
            .onChange(of: briefing48hEnabled) { _, _ in bumpDraft() }
            .onChange(of: socialPreferencesEnabled) { _, _ in bumpDraft() }
            .onChange(of: autoCloseHours) { _, _ in bumpDraft() }
            .onChange(of: seatDepositAmount) { _, _ in bumpDraft() }
            .onChange(of: seatDepositTrigger) { _, _ in bumpDraft() }
            .onChange(of: seatDepositGraceMinutes) { _, _ in bumpDraft() }
            .onChange(of: seasonSubtitle) { _, newValue in
                if newValue != seededSeasonSubtitle { bumpDraft() }
            }
    }

    private var hubForm: some View {
        bumpersLayer
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


    @ViewBuilder
    private var hubSections: some View {
        notifAndCalendarSections
        navLinkSection
        statusAndSeasonSections
    }


    // V0.95b — hubSections split further: Xcode 26.6 (iOS 26.5 SDK)
    // still blows the type-checker budget on the whole hub. Three
    // independent @ViewBuilder units, composed below.
    @ViewBuilder
    private var notifAndCalendarSections: some View {
                // V0.79 — member-visible notification preferences.
                // All roles: the host is a member too. The section
                // owns the durable opt-in + per-event mute controls
                // that left the briefing card.
                RoomNotifSettingsSection(room: room)

                // V0.86 — member-facing calendar surface. The
                // toggle is per-USER (applies to every room the
                // caller is in), so it lives on the member's own
                // settings, NOT inside any room. Rendered as a
                // sheet trigger next to "My notifications" so the
                // user already managing their prefs finds the
                // calendar toggle in the same mental slot.
                Button {
                    showCalendarSettings = true
                } label: {
                    HStack(spacing: Theme.Layout.gutter) {
                        Image(systemName: "calendar")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My calendar")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("Auto-add events to your iOS calendar")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                        Spacer()
                        Image(systemName: Theme.Icon.chevronRight)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

    }

    @ViewBuilder
    private var navLinkSection: some View {
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
                            briefing48hEnabled: $briefing48hEnabled,
                            socialPreferencesEnabled: $socialPreferencesEnabled,
                            autoCloseHours: $autoCloseHours,
                            seatDepositAmount: $seatDepositAmount,
                            seatDepositTrigger: $seatDepositTrigger,
                            seatDepositGraceMinutes: $seatDepositGraceMinutes,
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

                    // W2.2 — F-MVP-07 pack store shell. Lists the
                    // four packs with installed state; paid packs
                    // land here in a future release.
                    NavigationLink {
                        PackStoreView(roomId: room.id)
                            .environmentObject(roomService)
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.infoCircle,
                            title: "Pack store",
                            detail: "Browse packs, how-to guides, installed state"
                        )
                    }

                    // W-06 — host chip-color-map editor (US-26).
                    // Data layer (`upsert_casino_config`, migration
                    // 014) shipped with zero UI; this row opens the
                    // editor. Color map only — no vision-model
                    // settings panel (non-goal 15).
                    NavigationLink {
                        RoomSettingsCasinoSheet(roomId: room.id)
                            .environmentObject(casinoService)
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.circleHexagongridFill,
                            title: "Casino chips",
                            detail: "Chip values — standard or per-room"
                        )
                    }
                }

    }

    @ViewBuilder
    private var statusAndSeasonSections: some View {
                // V0.81 — autosave status. Replaces the manual
                // Save button: edits write themselves after a
                // 600ms pause; this row only reports state.
                Section {
                    HStack {
                        switch saveState {
                        case .idle:
                            Text("Edits save automatically")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        case .saving:
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.Palette.accent)
                            Text("Saving…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        case .saved:
                            Image(systemName: Theme.Icon.checkmarkCircleFill)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.accent)
                            Text("Saved")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        case .failed(let message):
                            Image(systemName: Theme.Icon.exclamationmarkTriangleFill)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.red.opacity(0.85))
                            Text(message)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                        Spacer()
                    }
                }

                // W1.5 — host-only season-close CTA. Hidden once the
                // current season has ended (the awards card owns
                // that state on the room page).
                if roomService.cachedCurrentSeason(roomId: room.id)?.status != .ended {
                    Section {
                        // W2.6 — season-subtitle host-approval beat.
                        // The mascot proposes; the host approves or
                        // edits here. The proposing voice stays
                        // gated on Q-TONE; the mechanism ships.
                        TextField("Season subtitle", text: $seasonSubtitle)
                            .font(Theme.Typography.body)
                            .onChange(of: seasonSubtitle) { _, newValue in
                                if newValue.count > 140 {
                                    seasonSubtitle = String(newValue.prefix(140))
                                }
                            }
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
                        Text("The subtitle shows on the awards card. Declaring closes the season, surfaces awards (Phoenix, Veteran, Whale, Drowning), and resets season scores.")
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

                // W-04 — host-only destructive action. Sits at the
                // bottom of the sheet, visually separated from the
                // settings sections (AC-03 placement; never next to
                // claim-seat surfaces).
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Image(systemName: Theme.Icon.trashFill)
                            Text("Delete room")
                                .font(Theme.Typography.body.weight(.semibold))
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                    .tint(.red)
                            }
                        }
                    }
                    .disabled(isDeleting)
                } footer: {
                    Text("Expires all join codes and removes calendar rows. The score ledger is kept for disputes.")
                }
                .confirmationDialog(
                    "Delete \(room.name)?",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task { await deleteRoom() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All join codes for this room expire immediately. This cannot be undone.")
                }
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
            // V0.81 — autosave status row carries the error.
            saveState = .failed((error as NSError).localizedDescription)
        }
    }

    // MARK: - Actions (W1.5 / W-04)

    /// W1.5 — host "Declare season end" action. Fires the
    /// `close_season` RPC via `RoomService.closeSeason`, then
    /// refreshes the room page state so the awards card renders.
    private func declareSeasonEnd() async {
        guard !isDeclaring else { return }
        isDeclaring = true
        defer { isDeclaring = false }
        do {
            _ = try await roomService.closeSeason(roomId: room.id)
            dismiss()
        } catch {
            // V0.81 — autosave status row carries the error.
            saveState = .failed((error as NSError).localizedDescription)
        }
    }

    // MARK: - Delete room (W-04, US-04)

    /// Host-only destructive action. Fires `RoomService.deleteRoom`,
    /// which routes through `delete_room` (migration 052): soft-
    /// deletes the room, expires open join codes, and removes
    /// calendar rows. On success the sheet dismisses; the service
    /// updates its rooms-list cache so the caller's list re-renders
    /// without the room.
    private func deleteRoom() async {
        guard !isDeleting else { return }
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await roomService.deleteRoom(roomId: room.id)
            dismiss()
            onRoomDeleted?()
        } catch {
            // V0.81 — autosave status row carries the error.
            saveState = .failed((error as NSError).localizedDescription)
        }
    }

    // MARK: - Autosave (V0.81)

    /// Bumps the draft counter, which restarts the `.task(id:)`
    /// debounce. Called from every field's `.onChange`.
    private func bumpDraft() {
        draft += 1
        isDirty = true
    }

    /// True when a dismiss-time retry is warranted: an edit that
    /// no write captured, or a write that failed.
    private var needsRetry: Bool {
        if isDirty { return true }
        if case .failed = saveState { return true }
        return false
    }

    /// Fires `RoomService.updateRoom(...)` with every form value
    /// plus the P1.5 host journal and the W2.6 season subtitle.
    /// The journal/subtitle writes are skipped if the settings
    /// write throws.
    private func writeAll() async {
        // Serialize: if a write is already in flight, queue a
        // refire (runs when the current write completes) instead of
        // running concurrently.
        guard !isWriting else {
            refireAfterWrite = true
            return
        }
        isWriting = true
        defer {
            isWriting = false
            if refireAfterWrite {
                refireAfterWrite = false
                Task { await writeAll() }
            }
        }
        saveState = .saving
        let task = Task {
            // Mark clean at the moment the write captures state;
            // an edit landing mid-write re-dirties so the
            // dismiss-time retry can catch it.
            isDirty = false
            do {
                _ = try await roomService.updateRoom(
                    id: room.id,
                    name: roomName,
                    mascotName: mascotName,
                    mascotPersonality: mascotPersonality,
                    mascotPoliticalIdeology: mascotIdeology,
                    maxSeats: maxSeats,
                    memberInviteQuota: memberInviteQuota,
                    joinStartingBonus: joinStartingBonus,
                    socialNarrationEnabled: socialNarrationEnabled,
                    briefing48hEnabled: briefing48hEnabled,
                    socialPreferencesEnabled: socialPreferencesEnabled,
                    autoCloseHours: autoCloseHours,
                    seatDepositAmount: seatDepositAmount,
                    seatDepositTrigger: seatDepositTrigger,
                    seatDepositGraceMinutes: seatDepositGraceMinutes
                )
                let trimmedJournal = hostJournal.trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await roomService.updateHostJournal(
                    roomId: room.id,
                    journal: trimmedJournal.isEmpty ? nil : trimmedJournal
                )
                // W2.6 — season-subtitle host-approval beat. Empty
                // clears; the RPC is idempotent.
                let trimmedSubtitle = seasonSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                try await roomService.setSeasonSubtitle(
                    roomId: room.id,
                    subtitle: trimmedSubtitle.isEmpty ? nil : trimmedSubtitle
                )
                // V0.86 — calendar permission is a per-member
                // surface, fired by the
                // `MemberCalendarSettingsSheet` (not the room's
                // host settings). The host's own calendar row is
                // written when the host has the toggle on
                // (host = user, same toggle applies — no
                // special-case for hosts). This branch is empty
                // intentionally; kept here to mark the migration.
                saveState = .saved
            } catch {
                saveState = .failed((error as NSError).localizedDescription)
            }
        }
        writeTask = task
        await task.value
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
                MascotConfigSection(
                    name: $mascotName,
                    personality: $mascotPersonality,
                    ideology: $mascotIdeology
                )
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
///
/// V0.86 — the "Auto-add to host calendar" toggle is REMOVED.
/// The calendar mirror moved to a per-user surface
/// (`MemberCalendarSettingsSheet`), reachable from the hub's
/// NavigationLink in the member-visible section.
struct RoomSettingsOperationsSheet: View {
    let roomId: UUID
    @Binding var maxSeats: Int
    @Binding var memberInviteQuota: Int
    @Binding var joinStartingBonus: Int
    @Binding var briefing48hEnabled: Bool
    @Binding var socialPreferencesEnabled: Bool
    @Binding var autoCloseHours: Int
    @Binding var seatDepositAmount: Int
    @Binding var seatDepositTrigger: SeatDepositTrigger
    @Binding var seatDepositGraceMinutes: Int
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
        briefing48hEnabled: Binding<Bool>,
        socialPreferencesEnabled: Binding<Bool>,
        autoCloseHours: Binding<Int>,
        seatDepositAmount: Binding<Int>,
        seatDepositTrigger: Binding<SeatDepositTrigger>,
        seatDepositGraceMinutes: Binding<Int>,
        shareCode: Binding<String?>,
        isGeneratingCode: Binding<Bool>
    ) {
        self.roomId = roomId
        _maxSeats = maxSeats
        _memberInviteQuota = memberInviteQuota
        _joinStartingBonus = joinStartingBonus
        _briefing48hEnabled = briefing48hEnabled
        _socialPreferencesEnabled = socialPreferencesEnabled
        _autoCloseHours = autoCloseHours
        _seatDepositAmount = seatDepositAmount
        _seatDepositTrigger = seatDepositTrigger
        _seatDepositGraceMinutes = seatDepositGraceMinutes
        _shareCode = shareCode
        _isGeneratingCode = isGeneratingCode
    }

    var body: some View {
        Form {
            Section("Operations") {
                Stepper("Max seats: \(maxSeats)", value: $maxSeats, in: 2...20)
                Stepper("Invite quota: \(memberInviteQuota)", value: $memberInviteQuota, in: 0...20)
                Stepper("Starting bonus: \(joinStartingBonus) pts", value: $joinStartingBonus, in: 0...1000, step: 50)
                // V0.83 — auto-close window. The lazy close stamps
                // settled_at on an un-finalized event this many hours
                // after played_at. Bounded 1...72 server-side.
                Stepper("Auto-close event after: \(autoCloseHours)h", value: $autoCloseHours, in: 1...72)
            }

            // V0.85 — seat deposit settings (migration 085). The
            // deposit reframes the tax: it leaves the balance at
            // claim and returns on the member's "I'm here" tap.
            // The four values ride the autosave wire identical to
            // autoCloseHours (each edit restarts the V0.81 600ms
            // debounce + writeAll call). `amount` is 0...1000
            // server-side, `grace` is 0...120; the picker raw
            // values match the migration's CHECK constraint
            // members exactly so the RPC never rejects the write.
            Section {
                Stepper(
                    "Seat deposit: \(seatDepositAmount) CC",
                    value: $seatDepositAmount, in: 0...1000, step: 50
                )
                Picker("Deposits", selection: $seatDepositTrigger) {
                    ForEach(SeatDepositTrigger.allCases, id: \.self) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                Stepper(
                    "Grace window: \(seatDepositGraceMinutes) min",
                    value: $seatDepositGraceMinutes, in: 0...120
                )
            } header: {
                Text("Seat deposit")
            } footer: {
                Text("Escrow holds each member's deposit from claim until they tap I'm here. A no-show is yours to call at session start — forfeit it and the deposit is gone, or hand it back.")
            }

            Section("Features") {
                Toggle("48-hour briefing push", isOn: $briefing48hEnabled)
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
                            Text(pack.scoringType.displayLabel)
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
        // share-code generation still happens via the hub's
        // generateShareCode() path (the code surfaces inline).
        // Until the closure is wired, this button is a no-op
        // placeholder.
        _ = isGeneratingCode
    }
}

// MARK: - Members sub-sheet

/// M2.2 — Members section. Loads the room's members on appear;
/// the host sees role + display name without leaving settings.
/// W1.6 — hosts can assign a team label per member (F-MVP-05
/// V2-full, migration 049); members see the roster read-only.
/// V0.91 — hosts can promote a member to host or demote a host
/// to member (multi-host; ≥1 host always). The promote/demote
/// action lives in a context menu on each row the host can
/// manage; the caller's own row and member rows (when the
/// caller isn't a host) have no menu.
struct RoomSettingsMembersSheet: View {
    let room: Room

    @EnvironmentObject private var roomService: RoomService

    @State private var roster: [Member] = []
    @State private var isRosterLoading: Bool = false
    /// Caller's auth id — needed so the row for "you" can hide
    /// the manage menu. Fetched once via `SupabaseClientProvider`
    /// in `.task`; nil while pending (renders the manage menu
    /// optimistically for both rows, then hides the self-row's
    /// menu once the id arrives).
    @State private var currentUserId: UUID?
    /// V0.91 — pending role-change awaiting the host's confirm.
    /// Identifies the row + action so the confirmation alert can
    /// render the right copy and the confirm button can fire the
    /// right RPC call.
    @State private var pendingChange: PendingRoleChange?
    /// Transient inline error (e.g. last_host on a single-host
    /// room). Drives an alert at the sheet level so the message
    /// has somewhere to render.
    @State private var transferError: String?

    private var isHost: Bool {
        room.userRole == .host
    }

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
                        memberRow(member)
                    }
                }
            }
            if isHost {
                Section {
                    if let selfRow = roster.first(where: { $0.userId == currentUserId }), selfRow.role == .host {
                        Text("To leave the room, ask another host to demote you.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
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
            // Resolve the caller id once so the self-row hides
            // its manage menu. The session lookup is local + fast;
            // we don't refetch on every render.
            if currentUserId == nil {
                currentUserId = await SupabaseClientProvider.currentSession()?.user.id
            }
        }
        // V0.91 — confirm-before-mutate alerts. SwiftUI's `.alert`
        // lives at the body level (not per-row) because a context
        // menu's `Button` cannot own a confirmation dialog — the
        // dialog must be promoted to the sheet so it survives the
        // menu's dismissal. The pending payload identifies which
        // row + action the alert is for.
        .alert(
            pendingChange?.confirmTitle ?? "",
            isPresented: Binding(
                get: { pendingChange != nil },
                set: { if !$0 { pendingChange = nil } }
            ),
            presenting: pendingChange
        ) { change in
            Button(change.confirmButtonTitle, role: .destructive) {
                Task { await applyPendingChange(change) }
            }
            Button("Cancel", role: .cancel) {
                pendingChange = nil
            }
        } message: { change in
            Text(change.confirmMessage)
        }
        .alert(
            "Couldn't change the role",
            isPresented: Binding(
                get: { transferError != nil },
                set: { if !$0 { transferError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(transferError ?? "")
        }
    }

    @ViewBuilder
    private func memberRow(_ member: Member) -> some View {
        let isSelf = member.userId == currentUserId
        if isHost && member.role != .host && !isSelf {
            // Member row (host viewing a non-host member): name +
            // role + a V0.98 visible "···" trailing menu with the
            // actions the caller can take (promote, kick).
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Member")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                Spacer()
                rowMenu(for: member, role: .member)
            }
        } else if isHost && member.role == .host && !isSelf {
            // Host row (host viewing another host): name + role
            // + a V0.98 visible "···" trailing menu (demote).
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Host")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                }
                Spacer()
                rowMenu(for: member, role: .host)
            }
        } else if isSelf && member.role == .host {
            // Caller's own row, when the caller is the host.
            // Display name + "Host (you)" with no menu — per the
            // spec, hosts can't self-promote or self-demote. The
            // leave-room affordance lives below the roster (see
            // the footer note in the host section).
            HStack {
                Text(member.displayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer()
                Text("Host (you)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
            }
        } else {
            // Either: member viewing the room, OR caller is a
            // host viewing a member whose role lookup raced
            // (`isHost && member.role != .host && isSelf` is a
            // contradiction; this branch covers the rest).
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

    /// V0.98 — visible trailing "···" menu on rows the caller can
    /// manage. Replaces the V0.91 hidden context menu so the host
    /// doesn't need a long-press to discover host tools. The menu
    /// contents vary by the row's current role (member → promote /
    /// kick; host → demote). Member rows carry the destructive kick
    /// entry; host rows don't (one tool per row — D5: demote first
    /// before kick is even possible server-side).
    @ViewBuilder
    private func rowMenu(for member: Member, role: MemberRowRole) -> some View {
        Menu {
            switch role {
            case .member:
                Button {
                    pendingChange = PendingRoleChange(
                        member: member,
                        action: .promote
                    )
                } label: {
                    Label("Make host", systemImage: "person.badge.shield.checkmark.fill")
                }
                Button(role: .destructive) {
                    pendingChange = PendingRoleChange(
                        member: member,
                        action: .kick
                    )
                } label: {
                    Label("Remove from room", systemImage: "person.slash.fill")
                }
            case .host:
                Button(role: .destructive) {
                    pendingChange = PendingRoleChange(
                        member: member,
                        action: .demote
                    )
                } label: {
                    Label("Demote to member", systemImage: "person.fill.xmark")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.6))
                .frame(width: 32, height: 32, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Manage \(member.displayName)")
    }

    /// V0.98 — which set of manage-actions a row should expose in
    /// its trailing menu. Tracks the row's *current* role, not the
    /// caller's: a host row always shows demote, a member row always
    /// shows promote (+ kick in slice 3), even if the caller is the
    /// room host. Tells the menu which branch of the switch to
    /// render without leaking the caller's role through the helper.
    private enum MemberRowRole {
        case member
        case host
    }

    /// V0.91 — fire the confirmed role change. On success the
    /// roster cache is already updated by `RoomService.transferHostRole`
    /// (replaced with the authoritative server-side set), so the
    /// row re-renders immediately. On error we surface the message
    /// via the sheet-level alert so the user sees the reason
    /// (`lastHost` is the canonical case). V0.98 also routes the
    /// `.kick` action through `RoomService.kickMember` so the same
    /// `pendingChange` payload drives the destructive remove flow
    /// with the same confirm-alert plumbing.
    private func applyPendingChange(_ change: PendingRoleChange) async {
        pendingChange = nil
        do {
            let rows: [Member]
            switch change.action {
            case .promote, .demote:
                rows = try await roomService.transferHostRole(
                    roomId: room.id,
                    targetUserId: change.member.userId,
                    action: change.action
                )
            case .kick:
                rows = try await roomService.kickMember(
                    roomId: room.id,
                    targetUserId: change.member.userId
                )
            }
            roster = rows
        } catch let error as HostRoleTransferError {
            transferError = error.errorDescription
        } catch let error as HostKickError {
            transferError = error.errorDescription
        } catch {
            transferError = error.localizedDescription
        }
    }
}

/// V0.91 — payload that drives the role-change confirmation alert.
/// Identifies which member the action targets and which direction
/// (promote/demote) the alert copy is for. V0.98 adds `.kick` so
/// the same `pendingChange` confirm-alert plumbing carries the
/// destructive remove-from-room action through the same sheet-level
/// `.alert` modifier (the existing reason context menus were
/// awkward).
private struct PendingRoleChange: Identifiable {
    let id = UUID()
    let member: Member
    let action: HostRoleAction

    var confirmTitle: String {
        switch action {
        case .promote: return "Make \(member.displayName) host?"
        case .demote: return "Demote \(member.displayName)?"
        case .kick: return "Remove \(member.displayName) from the room?"
        }
    }

    var confirmMessage: String {
        switch action {
        case .promote:
            return "You'll both have host powers. You can demote them later."
        case .demote:
            return "They'll lose host tools. The room will still have you."
        case .kick:
            return "Their nights stay in the ledger. They can rejoin later with a new invite code."
        }
    }

    var confirmButtonTitle: String {
        switch action {
        case .promote: return "Make host"
        case .demote: return "Demote"
        case .kick: return "Remove"
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

// MARK: - Casino sub-sheet (W-06)

/// W-06 — host chip-color-map editor (US-26). Surfaces
/// `upsert_casino_config` / `get_casino_config` (migration 014) —
/// the data layer shipped with zero UI. The host picks between the
/// standard preset values and per-room overrides per chip color.
/// Color map only; no vision-model settings panel (non-goal 15).
struct RoomSettingsCasinoSheet: View {
    let roomId: UUID

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var casinoService: CasinoService

    /// The config as loaded from the server. Non-nil once the
    /// initial read resolves; every field except the two the host
    /// edits (`standardPresets`, `chipColorMap`) passes through
    /// untouched on save.
    @State private var loadedConfig: CasinoConfig?
    @State private var standardPresets: Bool = true
    @State private var colorValues: [ChipColor: Int] = [:]
    @State private var isLoading: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Standard presets", isOn: $standardPresets)
                } footer: {
                    Text("On: the classic chip values (white 1, red 5, blue 10, green 25, black 100). Off: use your per-room values below.")
                }

                if !standardPresets {
                    Section {
                        ForEach(ChipColor.allCases, id: \.self) { color in
                            Stepper(
                                "\(color.displayName): \(value(for: color)) pts",
                                value: Binding(
                                    get: { value(for: color) },
                                    set: { colorValues[color] = $0 }
                                ),
                                in: 0...500,
                                step: 1
                            )
                        }
                    } header: {
                        Text("Per-room values")
                    } footer: {
                        Text("Colors you leave at their standard value keep it — only the changed ones are saved.")
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
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Casino chips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .tint(Theme.Palette.accent)
                    .disabled(isLoading || isSaving || loadedConfig == nil)
                }
            }
            .task {
                await load()
            }
        }
        .tint(Theme.Palette.accent)
    }

    private func value(for color: ChipColor) -> Int {
        colorValues[color] ?? color.defaultValue
    }

    private func load() async {
        guard loadedConfig == nil else { return }
        isLoading = true
        defer { isLoading = false }
        let config = await casinoService.loadCasinoConfig(roomId: roomId)
        loadedConfig = config
        standardPresets = config?.standardPresets ?? true
        colorValues = config?.chipColorMap ?? [:]
    }

    private func save() async {
        guard let loaded = loadedConfig, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        // Persist only the colors the host actually changed; the
        // model's `value(for:)` falls back to `defaultValue` for
        // unmapped colors.
        let map: [ChipColor: Int] = standardPresets
            ? [:]
            : Dictionary(uniqueKeysWithValues: ChipColor.allCases.compactMap { color in
                let v = value(for: color)
                return v == color.defaultValue ? nil : (color, v)
            })
        let updated = CasinoConfig(
            roomId: roomId,
            enabled: loaded.enabled,
            chipColorMap: map,
            standardPresets: standardPresets,
            visionProvider: loaded.visionProvider,
            visionModel: loaded.visionModel,
            visionApiKey: loaded.visionApiKey
        )
        do {
            try await casinoService.updateCasinoConfig(
                roomId: roomId,
                enabled: updated.enabled,
                chipColorMap: updated.chipColorMap,
                standardPresets: updated.standardPresets
            )
            dismiss()
        } catch {
            // AC-10: what/why/what-to-do inline; the sheet stays so
            // the host can retry without losing input.
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
