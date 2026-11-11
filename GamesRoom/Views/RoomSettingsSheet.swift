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
//  V0.81 — autosave: every edit to the draft is written after a
//  600ms trailing debounce; the write fires
//  `RoomService.updateRoom(...)` + the P1.5 journal write + the
//  W2.6 season-subtitle RPC. A swipe-dismiss flushes a pending
//  edit so the last keystroke is never lost, and a write that
//  lands while another is in flight is followed by exactly one
//  re-write (no edit is silently dropped). On success the
//  rooms-list cache in `RoomService` is refreshed by the service
//  and the host sees the new mascot name + operations immediately
//  on the Rooms page. On failure the inline status row shows the
//  error and the next edit retries.
//
//  Task E — the debounce, the pending draft and the write
//  serialisation moved out of the view and into `DraftSaver`
//  (Services/). The view submits the form's current values to the
//  saver and flushes it on the way out; it no longer owns a
//  debounce task, a write handle or a dirty flag.
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
    /// S3.5 — invoked after a successful leave so the presenter can
    /// pop/dismiss the surrounding navigation (the room is gone from
    /// the service's rooms cache at this point).
    var onRoomLeft: (() -> Void)?
    /// v1.1 — invoked after Declare season end succeeds, with the
    /// closed season, so the room page can land on its awards card.
    var onSeasonClosed: ((Season) -> Void)?

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
    // V0.107 — "brought by" host switch. The column is not on the
    // `Room` model (migration 103 ships its own RPC, not an
    // `update_room_settings` field), so there is nothing to seed in
    // `init`: the open-time seed comes from `RoomService` on the
    // stack's `.task` below. `seededShowBroughtBy` is that seed —
    // `nil` until it has been read. The seed is not an edit (the
    // server already holds the value), so the one change it causes
    // is swallowed by `isSeedingShowBroughtBy`; every change after
    // it is an edit and goes to the saver.
    @State private var showBroughtBy: Bool = true
    @State private var seededShowBroughtBy: Bool?
    // True between applying the seed and the `onChange` that carries
    // it. One change, swallowed.
    @State private var isSeedingShowBroughtBy: Bool = false

    @State private var autoCloseHours: Int
    @State private var seatDepositAmount: Int
    @State private var seatDepositTrigger: SeatDepositTrigger
    @State private var seatDepositGraceMinutes: Int
    @State private var hostJournal: String

    // P0.2 — share-code surface state. Generated on demand. The mint runs
    // in the Operations sub-sheet, next to the button and its own error row
    // (D9); only the code itself is hoisted, because that is what the row
    // renders.
    @State private var shareCode: String?

    // Task E — autosave state. The write machine is still `WriteState`
    // (Models/), but the view no longer holds it: the saver's write runs
    // off the main actor and reports through `DraftWriteStatus`, an
    // object the status section reads (`writeStatus.state`).
    @StateObject private var writeStatus = DraftWriteStatus()
    // The saver owns the pending draft, the 600ms debounce and the write
    // serialisation. It is built in the stack-level `.task`, where
    // `roomService` is available; the view only submits drafts to it and
    // flushes it on the way out.
    @State private var saver: DraftSaver<RoomSettingsDraft>?
    // W2.6 — the server subtitle value seeded on open. The seed is
    // not an edit either: the one change it causes is swallowed by
    // `isSeedingSeasonSubtitle`, so opening settings never triggers
    // a spurious autosave.
    @State private var seededSeasonSubtitle: String = ""
    // True between applying the seed and the `onChange` that carries
    // it. One change, swallowed.
    @State private var isSeedingSeasonSubtitle: Bool = false

    // W1.5 — host "Declare season end" CTA state.
    @State private var declareState: WriteState = .idle

    // W-04 — host "Delete room" state (US-04).
    @State private var deleteState: WriteState = .idle

    // S3.5 — "Leave room" state. The confirm is a destructive
    // action (the caller's membership ends), so it goes through a
    // `confirmationDialog` like the other destructive actions.
    @State private var isLeaving: Bool = false

    /// D11 — the three destructive confirms, as one value. Three Bools with
    /// three dialogs had no name for the concept; one enum with one dialog
    /// does, and only one can be up at a time by construction.
    @State private var confirm: RoomSettingsConfirm?
    /// S3.5 — inline error for a refused leave (the last host).
    @State private var leaveError: String?
    /// S3.5 — true once the room roster has been read. A host may
    /// only leave when another host remains, so the Leave row
    /// waits for the roster instead of guessing.
    @State private var rosterReady: Bool = false

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

    init(
        room: Room,
        onRoomDeleted: (() -> Void)? = nil,
        onRoomLeft: (() -> Void)? = nil,
        onSeasonClosed: ((Season) -> Void)? = nil
    ) {
        self.room = room
        self.onRoomDeleted = onRoomDeleted
        self.onRoomLeft = onRoomLeft
        self.onSeasonClosed = onSeasonClosed
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
        // Task E — the flush lives on the NavigationStack, not the
        // Form: pushing into a sub-sheet disappears the Form (and
        // everything attached to it), but the stack survives the push.
        .onDisappear {
            // The saver owns the pending draft and the write on the
            // wire. Flushing here means a swipe-away never loses the
            // last edit: the write in flight is awaited and the
            // pending draft is written immediately.
            guard let saver else { return }
            Task { @MainActor in await saver.flush() }
        }
        .task {
            // Task E — the saver is built here, where `roomService` is
            // available (see `makeSaver`).
            if saver == nil {
                saver = makeSaver()
            }
            // W2.6 — seed the subtitle field from the current
            // season once the environment object is available.
            // The seed is not an edit: the one change it causes is
            // swallowed, so opening settings never writes.
            if seasonSubtitle.isEmpty {
                seededSeasonSubtitle = roomService.cachedCurrentSeason(roomId: room.id)?.subtitle ?? ""
                if seededSeasonSubtitle != seasonSubtitle {
                    isSeedingSeasonSubtitle = true
                    seasonSubtitle = seededSeasonSubtitle
                }
            }
            // V0.107 — seed the brought-by switch. `cachedShowBroughtBy`
            // defaults to true so a cold open (the RPC has not landed
            // yet) still shows the switch where the column default
            // says it should be. The seed is not an edit either.
            if seededShowBroughtBy == nil {
                let on = await roomService.loadShowBroughtBy(roomId: room.id)
                seededShowBroughtBy = on
                if on != showBroughtBy {
                    isSeedingShowBroughtBy = true
                    showBroughtBy = on
                }
            }
            // S3.5 — read the roster so the Leave row knows whether
            // another host remains. A host may only leave when one
            // does (the live `leave_room` refuses the last host).
            _ = await roomService.loadRoomMembers(roomId: room.id)
            rosterReady = true
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
                        .foregroundStyle(Theme.Palette.labelText)
                }
            }
            // Task E — autosave bumpers. Every persisted field submits
            // the form's current values to the saver. Attached at the
            // hub so edits made inside the sub-sheets (hoisted bindings)
            // fire the same path.
    }

    /// V0.95b — autosave bumpers (every persisted field submits to the
    /// saver), as its own type-check unit.
    private var bumpersLayer: some View {
        toolbarLayer
            .onChange(of: mascotName) { _, _ in submitDraft() }
            .onChange(of: mascotPersonality) { _, _ in submitDraft() }
            .onChange(of: mascotIdeology) { _, _ in submitDraft() }
            .onChange(of: socialNarrationEnabled) { _, _ in submitDraft() }
            .onChange(of: hostJournal) { _, _ in submitDraft() }
            .onChange(of: maxSeats) { _, _ in submitDraft() }
            .onChange(of: memberInviteQuota) { _, _ in submitDraft() }
            .onChange(of: joinStartingBonus) { _, _ in submitDraft() }
            .onChange(of: briefing48hEnabled) { _, _ in submitDraft() }
            .onChange(of: socialPreferencesEnabled) { _, _ in submitDraft() }
            .onChange(of: showBroughtBy) { _, _ in
                // The open-time seed is not an edit — the server already
                // holds that value — so that one change is swallowed.
                // Every change after it is an edit.
                if isSeedingShowBroughtBy {
                    isSeedingShowBroughtBy = false
                    return
                }
                submitDraft()
            }
            .onChange(of: autoCloseHours) { _, _ in submitDraft() }
            .onChange(of: seatDepositAmount) { _, _ in submitDraft() }
            .onChange(of: seatDepositTrigger) { _, _ in submitDraft() }
            .onChange(of: seatDepositGraceMinutes) { _, _ in submitDraft() }
            .onChange(of: seasonSubtitle) { _, _ in
                // Same for the subtitle seed.
                if isSeedingSeasonSubtitle {
                    isSeedingSeasonSubtitle = false
                    return
                }
                submitDraft()
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
            // D11 — one destructive confirm for the whole sheet: declare
            // season end, delete room, leave room. One dialog, one value, so
            // two can never be up at once.
            .confirmationDialog(
                confirmTitle,
                isPresented: Binding(
                    get: { confirm != nil },
                    set: { if !$0 { confirm = nil } }
                ),
                titleVisibility: .visible,
                presenting: confirm
            ) { action in
                switch action {
                case .declareSeason:
                    Button("Declare", role: .destructive) {
                        confirm = nil
                        Task { await declareSeasonEnd() }
                    }
                case .deleteRoom:
                    Button("Delete", role: .destructive) {
                        confirm = nil
                        Task { await deleteRoom() }
                    }
                case .leaveRoom:
                    Button("Leave", role: .destructive) {
                        confirm = nil
                        Task { await leaveRoom() }
                    }
                }
                Button("Cancel", role: .cancel) { confirm = nil }
            } message: { action in
                switch action {
                case .declareSeason:
                    Text("Awards will be computed and season scores reset. This cannot be undone.")
                case .deleteRoom:
                    Text("All join codes for this room expire immediately. This cannot be undone.")
                case .leaveRoom:
                    Text("Your season history stays with the room.")
                }
            }
    }

    /// The title of the one destructive confirm. The copy is unchanged from
    /// the three dialogs it replaces.
    private var confirmTitle: String {
        switch confirm {
        case .declareSeason:
            return "Declare season end?"
        case .deleteRoom:
            return "Delete \(room.name)?"
        case .leaveRoom:
            return "Leave \(room.name)?"
        case nil:
            return ""
        }
    }


    /// S3.5 — the hub branches on role at the top. A host gets the
    /// full hub (social, operations, questions, casino chips,
    /// season, delete room). A member gets only the surfaces that
    /// are theirs: notifications, calendar, the roster (read-only),
    /// the pack list (read-only) and Leave room. Everyone can leave
    /// a room, so the Leave row sits at the bottom for both roles.
    @ViewBuilder
    private var hubSections: some View {
        notifAndCalendarSections
        if isHost {
            navLinkSection
            statusAndSeasonSections
        } else {
            memberNavLinkSection
        }
        leaveRoomSection
    }

    /// S3.5 — the caller's role in this room.
    private var isHost: Bool {
        room.userRole == .host
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
                    HStack(spacing: Theme.Layout.cardInset) {
                        Image(systemName: "calendar")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(width: Theme.Layout.rowIconWidth)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("My calendar")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("Auto-add events to your iOS calendar")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                        Spacer()
                        Image(systemName: Theme.Icon.chevronRight)
                            .accessibilityHidden(true)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

    }

    /// S3.5 — the host's links: everything that writes to the room
    /// (social, operations, questions, casino chips) plus the two
    /// read-only links a member also gets.
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
                            // V0.107 — the brought-by switch is host
                            // only; the sheet itself is member-reachable
                            // (V0.79 made the gear member-visible), so
                            // the gate is passed down explicitly.
                            isHost: room.userRole == .host,
                            maxSeats: $maxSeats,
                            memberInviteQuota: $memberInviteQuota,
                            joinStartingBonus: $joinStartingBonus,
                            briefing48hEnabled: $briefing48hEnabled,
                            socialPreferencesEnabled: $socialPreferencesEnabled,
                            showBroughtBy: $showBroughtBy,
                            autoCloseHours: $autoCloseHours,
                            seatDepositAmount: $seatDepositAmount,
                            seatDepositTrigger: $seatDepositTrigger,
                            seatDepositGraceMinutes: $seatDepositGraceMinutes,
                            shareCode: $shareCode
                        )
                    } label: {
                        settingsRow(
                            icon: Theme.Icon.sliderHorizontal3,
                            title: "Operations",
                            detail: "Seats, invites, features, share code"
                        )
                    }

                    // V0.106 — Question Box settings + editor (host only).
                    if room.userRole == .host {
                        NavigationLink {
                            QuestionBoxSettingsView(roomId: room.id)
                        } label: {
                            settingsRow(
                                icon: Theme.Icon.bubbleLeftAndBubbleRightFill,
                                title: "Questions",
                                detail: "Question Box, timer, speaking light"
                            )
                        }
                        .accessibilityIdentifier("settings-questions-link")
                    }

                    membersLink

                    packStoreLink

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
                            detail: "Chip values: standard or per-room"
                        )
                    }
                }

    }

    /// S3.5 — the member's links. The roster and the pack list are
    /// read-only for a member (the sheets gate their own controls on
    /// the host role), so a member sees what the room is without any
    /// of the controls that would only error for them.
    @ViewBuilder
    private var memberNavLinkSection: some View {
                Section {
                    membersLink
                    packStoreLink
                }
    }

    /// The roster link. Members see the list; hosts see the list plus
    /// the per-member controls.
    private var membersLink: some View {
        NavigationLink {
            RoomSettingsMembersSheet(room: room)
        } label: {
            settingsRow(
                icon: Theme.Icon.person2Fill,
                title: "Members",
                detail: room.userRole == .host ? "Roster + per-member controls" : "Who's in the room"
            )
        }
    }

    /// W2.2 — F-MVP-07 pack store shell. Lists the four packs with
    /// installed state; paid packs land here in a future release.
    /// Read-only for a member: the store lists what is installed and
    /// opens the how-to body, it never writes.
    private var packStoreLink: some View {
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
    }

    @ViewBuilder
    private var statusAndSeasonSections: some View {
                // V0.81 — autosave status. Replaces the manual
                // Save button: edits write themselves after a
                // 600ms pause; this row only reports state.
                // D10 — this row reports the settings write and nothing
                // else. Season-close, delete and share-code outcomes each
                // render under their own control now.
                Section {
                    HStack {
                        switch writeStatus.state {
                        case .idle:
                            Text("Edits save automatically")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        case .saving:
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.Palette.accent)
                            Text("Saving…")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        case .saved:
                            Image(systemName: Theme.Icon.checkmarkCircleFill)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.accent)
                            Text("Saved")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        case .failed(_, let message):
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
                            confirm = .declareSeason
                        } label: {
                            HStack {
                                Text("Declare season end")
                                    .font(Theme.Typography.body.weight(.semibold))
                                Spacer()
                                if declareState.isBusy {
                                    ProgressView()
                                        .tint(Theme.Palette.accent)
                                }
                            }
                        }
                        .disabled(declareState.isBusy)
                        // D9/D10 — the season-close outcome renders under the
                        // button that caused it, not in the settings status row.
                        if let declareError = declareState.failureMessage {
                            Text(declareError)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    } header: {
                        Text("Season")
                    } footer: {
                        Text("The subtitle shows on the awards card. Declaring closes the season, surfaces awards (Phoenix, Veteran, Whale, Drowning), and resets season scores.")
                    }
                }

                // W-04 — host-only destructive action. Sits at the
                // bottom of the sheet, visually separated from the
                // settings sections (AC-03 placement; never next to
                // claim-seat surfaces).
                Section {
                    Button(role: .destructive) {
                        confirm = .deleteRoom
                    } label: {
                        HStack {
                            Image(systemName: Theme.Icon.trashFill)
                            Text("Delete room")
                                .font(Theme.Typography.body.weight(.semibold))
                            Spacer()
                            if deleteState.isBusy {
                                ProgressView()
                                    .tint(.red)
                            }
                        }
                    }
                    .disabled(deleteState.isBusy)
                    // D10 — a failed delete says so under the Delete row. It
                    // used to surface in the mascot status row, a section up.
                    if let deleteError = deleteState.failureMessage {
                        Text(deleteError)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                } footer: {
                    Text("Expires all join codes and removes calendar rows. The score ledger is kept for disputes.")
                }
    }


    /// S3.5 — Leave room. Every role can leave: a member walks away
    /// from a room they are in, a host walks away when another host
    /// remains. The last host gets a grey caption instead of the
    /// button, because the server refuses that leave (`last_host`).
    @ViewBuilder
    private var leaveRoomSection: some View {
                Section {
                    if isHost && !rosterReady {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Theme.Palette.accent)
                            Text("Checking the roster")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Spacer()
                        }
                    } else if canLeaveRoom {
                        Button(role: .destructive) {
                            confirm = .leaveRoom
                        } label: {
                            HStack {
                                Text("Leave room")
                                    .font(Theme.Typography.body.weight(.semibold))
                                Spacer()
                                if isLeaving {
                                    ProgressView()
                                        .tint(.red)
                                }
                            }
                        }
                        .disabled(isLeaving)
                    } else {
                        Text("Make someone else host first.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
                .alert(
                    "Couldn't leave the room",
                    isPresented: Binding(
                        get: { leaveError != nil },
                        set: { if !$0 { leaveError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(leaveError ?? "")
                }
    }

    /// S3.5 — the host count that decides whether the caller may
    /// leave. A room must always keep one host, so the last host
    /// stays. The caller's own row is excluded (`room.userRole` is
    /// the caller's role in this room).
    private var otherHostCount: Int {
        let roster = roomService.cachedMembers(roomId: room.id)
        let hosts = roster.filter { $0.role == .host }.count
        return isHost ? max(0, hosts - 1) : hosts
    }

    /// S3.5 — a member may always leave. A host may leave when
    /// another host remains. An empty roster means the read failed
    /// or has not landed: the server has the final say, so the
    /// button stays.
    private var canLeaveRoom: Bool {
        guard isHost else { return true }
        let roster = roomService.cachedMembers(roomId: room.id)
        guard !roster.isEmpty else { return true }
        return otherHostCount > 0
    }

    /// S3.5 — leaves the room. The membership ends server-side, the
    /// room leaves the caller's rooms list, and the sheet closes so
    /// the caller lands back on the rooms list without it.
    private func leaveRoom() async {
        guard !isLeaving else { return }
        isLeaving = true
        defer { isLeaving = false }
        do {
            try await roomService.leaveRoom(roomId: room.id)
            dismiss()
            onRoomLeft?()
        } catch {
            leaveError = error.localizedDescription
        }
    }

    /// Visual row inside the hub. Shared shape; sub-sheets own
    /// the body of the form.
    private func settingsRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: Theme.Layout.cardInset) {
            Image(systemName: icon)
                .accessibilityHidden(true)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: Theme.Layout.rowIconWidth)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions (W1.5 / W-04)

    /// W1.5 — host "Declare season end" action. Fires the
    /// `close_season` RPC via `RoomService.closeSeason`, then
    /// refreshes the room page state so the awards card renders.
    /// The outcome is its own `WriteState`: a failure renders under the
    /// Declare button, not in the settings status row (D10).
    private func declareSeasonEnd() async {
        guard !declareState.isBusy else { return }
        declareState = declareState.reduce(.begin(.declareSeason))
        do {
            let closed = try await roomService.closeSeason(roomId: room.id)
            Haptics.success()
            declareState = declareState.reduce(.succeed(at: Date()))
            dismiss()
            onSeasonClosed?(closed)
        } catch {
            declareState = declareState.reduce(.fail(.declareSeason, (error as NSError).localizedDescription))
        }
    }

    // MARK: - Delete room (W-04, US-04)

    /// Host-only destructive action. Fires `RoomService.deleteRoom`,
    /// which routes through `delete_room` (migration 052): soft-
    /// deletes the room, expires open join codes, and removes
    /// calendar rows. On success the sheet dismisses; the service
    /// updates its rooms-list cache so the caller's list re-renders
    /// without the room. A failure renders under the Delete row (D10).
    private func deleteRoom() async {
        guard !deleteState.isBusy else { return }
        deleteState = deleteState.reduce(.begin(.deleteRoom))
        do {
            try await roomService.deleteRoom(roomId: room.id)
            deleteState = deleteState.reduce(.succeed(at: Date()))
            dismiss()
            onRoomDeleted?()
        } catch {
            deleteState = deleteState.reduce(.fail(.deleteRoom, (error as NSError).localizedDescription))
        }
    }

    // MARK: - Autosave (V0.81)

    /// The single funnel every field's `.onChange` calls.
    ///
    /// The form's current values go to the saver, which owns the
    /// debounce and the write sequencing. The draft is read here, not
    /// captured when the edit happened, so the write that lands carries
    /// the newest values.
    private func submitDraft() {
        // D8 — an edit retires the last outcome: "Saved" stops claiming the
        // current draft is on the wire, and a stale failure clears as the
        // retry is already queued.
        writeStatus.edited()
        // The saver is built by the stack-level `.task`, which runs when
        // the sheet appears. This is the belt to that braces: an edit
        // must never be dropped because the saver was not there yet.
        let saver = saver ?? makeSaver()
        self.saver = saver
        let draft = currentDraft()
        // The submit is ordered on the main actor's queue, so the
        // newest draft is the one that lands.
        Task { @MainActor in await saver.submit(draft) }
    }

    /// The saver, with the settings write wired in.
    ///
    /// The write closure needs `roomService`, which is why the saver is
    /// built where the environment object is available. Only the
    /// service, the status object and the room id cross into the
    /// closure: it is `@Sendable`, and a closure that captured the view
    /// would capture a type that is not `Sendable`.
    private func makeSaver() -> DraftSaver<RoomSettingsDraft> {
        let service = roomService
        let status = writeStatus
        let roomId = room.id
        return DraftSaver<RoomSettingsDraft>(
            debounce: DraftSaver<RoomSettingsDraft>.defaultDebounce
        ) { draft in
            await status.begin()
            do {
                try await persistRoomSettings(
                    service: service,
                    roomId: roomId,
                    draft: draft
                )
                await status.succeed()
            } catch {
                await status.fail((error as NSError).localizedDescription)
                // The rethrow is how the saver learns the write failed:
                // it keeps the draft for the one retry a flush allows.
                throw error
            }
        }
    }

    /// The form as one value the saver can hold.
    private func currentDraft() -> RoomSettingsDraft {
        RoomSettingsDraft(
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
            seatDepositGraceMinutes: seatDepositGraceMinutes,
            showBroughtBy: showBroughtBy,
            hostJournal: hostJournal,
            seasonSubtitle: seasonSubtitle
        )
    }
}

/// The settings write, as a free function.
///
/// It cannot be a method on the view: the saver's write closure is
/// `@Sendable`, and a closure that captures the view captures a type
/// that is not `Sendable`. Everything the write needs is in the draft,
/// so the function takes the draft and the room it belongs to.
///
/// The journal/subtitle writes are skipped if the settings write
/// throws.
private func persistRoomSettings(
    service: RoomService,
    roomId: UUID,
    draft: RoomSettingsDraft
) async throws {
    _ = try await service.updateRoom(
        id: roomId,
        name: draft.name,
        mascotName: draft.mascotName,
        mascotPersonality: draft.mascotPersonality,
        mascotPoliticalIdeology: draft.mascotPoliticalIdeology,
        maxSeats: draft.maxSeats,
        memberInviteQuota: draft.memberInviteQuota,
        joinStartingBonus: draft.joinStartingBonus,
        socialNarrationEnabled: draft.socialNarrationEnabled,
        briefing48hEnabled: draft.briefing48hEnabled,
        socialPreferencesEnabled: draft.socialPreferencesEnabled,
        autoCloseHours: draft.autoCloseHours,
        seatDepositAmount: draft.seatDepositAmount,
        seatDepositTrigger: draft.seatDepositTrigger,
        seatDepositGraceMinutes: draft.seatDepositGraceMinutes
    )
    // V0.107 — the brought-by switch rides this write.
    // `update_room_settings` does not own the column (migration 103
    // added a host-only RPC for it), so call it alongside; skipping it
    // would leave the switch visibly off with nothing persisted.
    try await service.setShowBroughtBy(roomId: roomId, on: draft.showBroughtBy)
    // P1.5 — the host journal.
    let trimmedJournal = draft.hostJournal.trimmingCharacters(in: .whitespacesAndNewlines)
    _ = try await service.updateHostJournal(
        roomId: roomId,
        journal: trimmedJournal.isEmpty ? nil : trimmedJournal
    )
    // W2.6 — season-subtitle host-approval beat. Empty clears; the
    // RPC is idempotent.
    let trimmedSubtitle = draft.seasonSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    try await service.setSeasonSubtitle(
        roomId: roomId,
        subtitle: trimmedSubtitle.isEmpty ? nil : trimmedSubtitle
    )
    // V0.86 — calendar permission is a per-member surface, fired by the
    // `MemberCalendarSettingsSheet` (not the room's host settings). The
    // host's own calendar row is written when the host has the toggle on
    // (host = user, same toggle applies — no special-case for hosts).
    // This branch is empty intentionally; kept here to mark the migration.
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
                        .font(Theme.Typography.monoFootnote)
                        .foregroundStyle(hostJournal.count >= 260
                                         ? Theme.Palette.accent
                                         : Theme.Palette.tertiaryText)
                }
            } footer: {
                Text("A short note visible only to hosts: venue quirks, recurring house rules, who's hosting next.")
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
    /// V0.107 — the brought-by switch is host only (spec §3). The
    /// sheet is member-reachable, so the hub passes the resolved role
    /// down rather than the sub-sheet reading it back off the room.
    let isHost: Bool
    @Binding var maxSeats: Int
    @Binding var memberInviteQuota: Int
    @Binding var joinStartingBonus: Int
    @Binding var briefing48hEnabled: Bool
    @Binding var socialPreferencesEnabled: Bool
    /// V0.107 — hoisted to the hub so its autosave write rides the
    /// same debounce as every other field.
    @Binding var showBroughtBy: Bool
    @Binding var autoCloseHours: Int
    @Binding var seatDepositAmount: Int
    @Binding var seatDepositTrigger: SeatDepositTrigger
    @Binding var seatDepositGraceMinutes: Int
    @Binding var shareCode: String?

    @EnvironmentObject private var roomService: RoomService

    @State private var enabledPackSlugs: Set<String> = []
    @State private var packsLoaded: Bool = false
    /// D9 — the invite-code mint reports next to its own button. It used to
    /// write the hub's settings status row, which is a section away and
    /// behind this sub-sheet, so a failure looked like nothing happening.
    @State private var shareState: WriteState = .idle

    // V0.9 Wave 2 Slice 2.1 - the pack the user tapped to view the
    // how-to body. nil = no detail sheet presented.
    @State private var packDetailType: (any PackDefinition.Type)?

    init(
        roomId: UUID = UUID(),
        isHost: Bool = false,
        maxSeats: Binding<Int>,
        memberInviteQuota: Binding<Int>,
        joinStartingBonus: Binding<Int>,
        briefing48hEnabled: Binding<Bool>,
        socialPreferencesEnabled: Binding<Bool>,
        showBroughtBy: Binding<Bool>,
        autoCloseHours: Binding<Int>,
        seatDepositAmount: Binding<Int>,
        seatDepositTrigger: Binding<SeatDepositTrigger>,
        seatDepositGraceMinutes: Binding<Int>,
        shareCode: Binding<String?>
    ) {
        self.roomId = roomId
        self.isHost = isHost
        _maxSeats = maxSeats
        _memberInviteQuota = memberInviteQuota
        _joinStartingBonus = joinStartingBonus
        _briefing48hEnabled = briefing48hEnabled
        _socialPreferencesEnabled = socialPreferencesEnabled
        _showBroughtBy = showBroughtBy
        _autoCloseHours = autoCloseHours
        _seatDepositAmount = seatDepositAmount
        _seatDepositTrigger = seatDepositTrigger
        _seatDepositGraceMinutes = seatDepositGraceMinutes
        _shareCode = shareCode
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
            // debounce inside the saver). `amount` is 0...1000
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
                Text("Escrow holds each member's deposit from claim until they tap I'm here. A no-show is yours to call at session start. Forfeit it and the deposit is gone, or hand it back.")
            }

            Section("Features") {
                Toggle("Mid-week reminder push", isOn: $briefing48hEnabled)
                Toggle("Members can set preferences", isOn: $socialPreferencesEnabled)
            }

            // V0.107 — who brought newcomers. Its own section so the
            // footer reads as this switch's caption and not the two
            // feature toggles' (spec §3: beside the social-preferences
            // switch). Off hides the anchor and first-night text on
            // every surface in this room (A7); `cachedShowBroughtBy`
            // is the single gate those surfaces read.
            if isHost {
                Section {
                    Toggle("Show who brought newcomers", isOn: $showBroughtBy)
                        .accessibilityIdentifier("show-brought-by-toggle")
                } footer: {
                    Text("Shows \"with Alex\" under a newcomer's name so the room knows who they came with.")
                }
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
                                .foregroundStyle(Theme.Palette.secondaryText)
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
                                .accessibilityHidden(true)
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
                    if shareState.isBusy {
                        ProgressView()
                            .tint(Theme.Palette.accent)
                        Text("Generating…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    } else if let shareCode {
                        Text(shareCode)
                            .font(Theme.Typography.titleMono)
                            .foregroundStyle(Theme.Palette.primaryText)
                            .tracking(2)
                    } else {
                        Text("Tap to mint a fresh code")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer()
                    Button {
                        Task { await mintShareCode() }
                    } label: {
                        Image(systemName: shareCode == nil ? Theme.Icon.plusCircle : Theme.Icon.arrowClockwise)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .disabled(shareState.isBusy)
                    .accessibilityLabel(Text("Generate fresh join code"))
                }
                // D9 — the failure renders under the button that caused it.
                if let shareError = shareState.failureMessage {
                    Text(shareError)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
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
        .alert(
            "Couldn't update packs",
            isPresented: Binding(
                get: { toggleError != nil },
                set: { if !$0 { toggleError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(toggleError ?? "")
        }
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
    /// V0.98 — failures surface instead of silently reverting (the
    /// created_by-guard bug class failed invisibly here for weeks).
    @State private var toggleError: String?

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
            toggleError = nil
        } catch {
            // Revert the local toggle on failure — and TELL the host
            // (silent revert looked like "settings don't save").
            if isOn {
                enabledPackSlugs.remove(slug)
            } else {
                enabledPackSlugs.insert(slug)
            }
            toggleError = (error as NSError).localizedDescription
        }
    }

    /// Mints a fresh six-character join code via
    /// `RoomService.generateJoinCode(roomId:)` and writes it to the hoisted
    /// binding the invite-code row renders. The outcome stays local so a
    /// failure lands under this button and not in the hub's status row (D9).
    private func mintShareCode() async {
        guard !shareState.isBusy else { return }
        shareState = shareState.reduce(.begin(.shareCode))
        do {
            shareCode = try await roomService.generateJoinCode(roomId: roomId)
            shareState = shareState.reduce(.succeed(at: Date()))
        } catch {
            shareState = shareState.reduce(.fail(.shareCode, (error as NSError).localizedDescription))
        }
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
    /// D13 — the role-change confirm and its failure used to be two `.alert`
    /// modifiers on one `Form`: the second could be dropped while the first
    /// was dismissing. One alert, one value.
    @State private var alert: RoleAlert?

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
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                } else if roster.isEmpty {
                    Text("No members yet. Share the invite code from the Operations section.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                } else {
                    ForEach(roster, id: \.id) { member in
                        memberRow(member)
                    }
                }
            }
            // S3.5 — the old host-only copy here ("To leave the room,
            // ask another host to demote you") is gone: leaving is
            // now an action every member has, from the settings hub
            // (and from the rooms list row).
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
        // D13 — one alert for both the confirm and the failure it can
        // produce, so a failed role change can never be dropped behind a
        // dismissing confirm.
        .alert(
            alertTitle,
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            ),
            presenting: alert
        ) { alert in
            switch alert {
            case .confirm(let change):
                Button(change.confirmButtonTitle, role: .destructive) {
                    self.alert = nil
                    Task { await applyPendingChange(change) }
                }
                Button("Cancel", role: .cancel) { self.alert = nil }
            case .error:
                Button("OK", role: .cancel) { self.alert = nil }
            }
        } message: { alert in
            switch alert {
            case .confirm(let change):
                Text(change.confirmMessage)
            case .error(let message):
                Text(message)
            }
        }
    }

    /// Title for the one role alert. The copy is unchanged from the two
    /// alerts it replaces.
    private var alertTitle: String {
        switch alert {
        case .confirm(let change):
            return change.confirmTitle
        case .error:
            return "Couldn't change the role"
        case nil:
            return ""
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
                        .foregroundStyle(Theme.Palette.secondaryText)
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
                                     : Theme.Palette.secondaryText)
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
                    alert = .confirm(PendingRoleChange(
                        member: member,
                        action: .promote
                    ))
                } label: {
                    Label("Make host", systemImage: "person.badge.shield.checkmark.fill")
                }
                Button(role: .destructive) {
                    alert = .confirm(PendingRoleChange(
                        member: member,
                        action: .kick
                    ))
                } label: {
                    Label("Remove from room", systemImage: "person.slash.fill")
                }
            case .host:
                Button(role: .destructive) {
                    alert = .confirm(PendingRoleChange(
                        member: member,
                        action: .demote
                    ))
                } label: {
                    Label("Demote to member", systemImage: "person.fill.xmark")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(Theme.Palette.secondaryText)
                .frame(width: Theme.Layout.rowIconWidth, height: 32, alignment: .trailing)
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
        alert = nil
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
            alert = .error(error.errorDescription ?? "")
        } catch let error as HostKickError {
            alert = .error(error.errorDescription ?? "")
        } catch {
            alert = .error(error.localizedDescription)
        }
    }
}

/// D13 — the one role alert on the members sheet: the confirm, and the
/// failure it can produce.
private enum RoleAlert: Identifiable {
    case confirm(PendingRoleChange)
    case error(String)

    var id: String {
        switch self {
        case .confirm(let change):
            return "confirm-\(change.id.uuidString)"
        case .error(let message):
            return "error-\(message)"
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
    /// v1.1 — edits autosave (like the rest of Room settings). A
    /// presenter that shows this as a sheet passes `true` to get a
    /// Done button; the pushed hub page uses the back button.
    var showsDoneButton: Bool = false

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
    /// Draft key last written (or loaded); autosave fires only when
    /// the current draft differs.
    @State private var savedDraftKey: String?
    @State private var showSaved: Bool = false

    private var draftKey: String {
        let values = ChipColor.allCases.map { "\(value(for: $0))" }.joined(separator: ",")
        return "\(standardPresets)|\(values)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Standard presets", isOn: $standardPresets)
                } header: {
                    Text(isSaving ? "Saving…" : (showSaved ? "Saved" : "Edits save automatically"))
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
                        Text("Colors you leave at their standard value keep it. Only the changed ones are saved.")
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
                if showsDoneButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .tint(Theme.Palette.accent)
                    }
                }
            }
            .task {
                await load()
            }
            // v1.1 — autosave: write 600ms after the last edit, the
            // same rhythm as the Room settings hub.
            .task(id: draftKey) {
                guard loadedConfig != nil, let saved = savedDraftKey, saved != draftKey else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await save()
            }
            // Flush an edit made inside the debounce window when the
            // page closes. Values are captured now: the view's state
            // is gone by the time the write runs.
            .onDisappear {
                guard let loaded = loadedConfig, savedDraftKey != draftKey else { return }
                let presets = standardPresets
                let map = changedColorMap
                let service = casinoService
                let id = roomId
                Task {
                    try? await service.updateCasinoConfig(
                        roomId: id,
                        enabled: loaded.enabled,
                        chipColorMap: map,
                        standardPresets: presets
                    )
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    private func value(for color: ChipColor) -> Int {
        colorValues[color] ?? color.defaultValue
    }

    /// Persist only the colors the host actually changed; the
    /// model's `value(for:)` falls back to `defaultValue` for
    /// unmapped colors.
    private var changedColorMap: [ChipColor: Int] {
        standardPresets
            ? [:]
            : Dictionary(uniqueKeysWithValues: ChipColor.allCases.compactMap { color in
                let v = value(for: color)
                return v == color.defaultValue ? nil : (color, v)
            })
    }

    private func load() async {
        guard loadedConfig == nil else { return }
        isLoading = true
        defer { isLoading = false }
        let config = await casinoService.loadCasinoConfig(roomId: roomId)
        loadedConfig = config
        standardPresets = config?.standardPresets ?? true
        colorValues = config?.chipColorMap ?? [:]
        savedDraftKey = draftKey
    }

    private func save() async {
        guard let loaded = loadedConfig, !isSaving else { return }
        let key = draftKey
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        let map = changedColorMap
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
            savedDraftKey = key
            showSaved = true
        } catch {
            // AC-10: what/why/what-to-do inline; the page stays so
            // the host can retry without losing input.
            errorMessage = (error as NSError).localizedDescription
        }
    }
}
