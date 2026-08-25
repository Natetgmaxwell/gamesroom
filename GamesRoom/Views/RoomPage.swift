//
//  RoomPage.swift
//  GamesRoom
//
//  Track E2 — the persistent home of the V0.8 app.
//
//  One page, three states:
//   1. **List** — `LazyVStack` of every room the current user is in,
//      rendered as `RoomRow` tiles. The default surface for a brand-new
//      install or a freshly signed-in user.
//   2. **Last-viewed hero** — if the user previously opened a room and
//      that room is still in their list, a hero card at the top offers
//      one-tap resume. Per the V0.8 brief L "Last-viewed room opens the
//      Rooms tab automatically." We keep the list visible underneath —
//      the hero is an accelerator, not a replacement.
//   3. **Empty** — when the list is empty, a single CTA branching on
//      host-vs-member. Members see "Ask a friend for a join code";
//      hosts (or any signed-in user with no rooms yet) see
//      "Create one to get started".
//
//  Navigation
//  ----------
//  The page owns a `NavigationStack` rooted in the rooms list. Tapping a
//  row pushes `RoomDetailView` via the standard `selection:`-driven
//  `NavigationLink`. The tapped room's id is mirrored to
//  `@AppStorage("lastViewedRoomIdString")` so a future cold launch can
//  auto-push straight into it.
//
//  Toolbar
//  -------
//  One icon — a gear — appears in the top-trailing slot, host-only,
//  scoped to the resolved last-viewed room. Tapping it opens
//  `RoomSettingsSheet` for that room. Members and signed-out states see
//  no toolbar chrome (the app settings gear lives on the Account /
//  Settings tab per V0.8 brief L6).
//
//  Data flow
//  ---------
//  The page subscribes to `RoomService` via `@EnvironmentObject`. Rooms
//  load on `.task` (cold launch) and on pull-to-refresh. The
//  `lastViewedRoomIdString` is read once on appear, then watched via
//  the `@AppStorage` projection so it stays live if the user signs out
//  in another tab.
//
//  Theme discipline
//  ----------------
//  All styling routes through `Theme.Palette`, `Theme.Typography`,
//  `Theme.Layout`, and the `.sectionCard(.hero|.standard)` modifier.
//  No ad-hoc colors, no inline hex. The hero card carries the slot's
//  single `.hero` wash; everything else is `.standard` or naked
//  surface per the 80/20/10 rule.
//

import SwiftUI

// MARK: - RoomPage

struct RoomPage: View {
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var casinoService: CasinoService

    /// The room the user is currently being pushed into. Driven by the
    /// `NavigationStack`'s `selection:` binding. Setting it triggers
    /// the push; clearing it pops back.
    @State private var selectedRoom: Room?

    /// iPhone-only path binding for the rooms-list `NavigationStack`.
    /// Used to programmatically push into a room when in screenshot
    /// mode (V0.92) — the production tap path still uses the
    /// `NavigationLink(value:)` driven push at `.navigationDestination`.
    @State private var roomsPath: [Room] = []

    #if DEBUG
    /// V0.92 — initial-screen selector. When launched with
    /// `-screenshots-screen=<key>`, push the appropriate room
    /// (or none) onto the iPhone NavigationStack on first
    /// appearance. Other values: nil = default rooms list.
    ///
    /// V0.97+ screenshot set keys:
    ///   briefing  — push the first room (the seeded `.upcoming`
    ///               BriefingSlot target).
    ///   witness   — push the first room (`.tonightEvent` capture).
    ///   settled   — push the first room (`.justSettled` capture).
    ///   awards    — push the first room (Felt Faction, whose
    ///               `.ended` season triggers the AwardsCard).
    ///   empty     — leave the rooms list (used by the empty-state
    ///               Create-room capture).
    ///   pack-detail — historical V0.92 alias kept for the
    ///               integration tests; treated like room-detail.
    private static var screenshotInitialRoomPush: Bool {
        let screen = Self.screenshotScreenArg()
        switch screen {
        case "briefing", "witness", "settled", "awards",
             "room-detail", "casino", "pack-detail":
            return true
        default:
            return false
        }
    }

    /// V0.97+ — reads `-screenshots-screen=<key>` from
    /// `CommandLine.arguments`. Returns the trimmed key, or nil
    /// when the flag is absent. Centralised so the production
    /// boot path doesn't re-parse the arg list.
    private static func screenshotScreenArg() -> String? {
        guard let raw = CommandLine.arguments.first(where: { $0.hasPrefix("-screenshots-screen=") }) else {
            return nil
        }
        let key = String(raw.dropFirst("-screenshots-screen=".count))
        return key.isEmpty ? nil : key
    }
    #endif

    /// The room whose settings the user is editing. `nil` ⇒ the
    /// settings sheet is dismissed. Only valid for host role rooms.
    @State private var settingsRoom: Room?

    /// Create-room sheet binding. Mirrors the empty-state "Create"
    /// CTA (P0.2 onboarding).
    @State private var showingCreateRoom: Bool = false

    /// Join-room sheet binding. Mirrors the empty-state "Join with
    /// code" CTA (P0.2 onboarding).
    @State private var showingJoinRoom: Bool = false

    /// Mirror of the persisted last-viewed room id, kept live so the
    /// hero card re-renders if the user switches rooms in another
    /// surface. Stored as a String because UUID is not directly
    /// `AppStorage`-compatible; we parse on read. See
    /// `StorageKeys.lastViewedRoomId` for the central key constant.
    @AppStorage("lastViewedRoomIdString") private var lastViewedRoomIdString: String = ""

    var body: some View {
        Group {
            if isPad {
                splitView
            } else {
                stackView
            }
        }
        .sheet(item: $settingsRoom) { room in
            // W-04 — the sheet dismisses itself after a successful
            // delete; the service's rooms-list cache update re-renders
            // this page without the room (and the last-viewed hero
            // resolves to nil because the room is gone).
            RoomSettingsSheet(room: room)
                .environmentObject(roomService)
                .environmentObject(casinoService)
        }
        .sheet(isPresented: $showingCreateRoom) {
            CreateRoomSheet()
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showingJoinRoom) {
            JoinRoomSheet()
                .environmentObject(roomService)
        }
        .task {
            await roomService.refresh()
            await roomService.loadRoomsSocialProof()
            #if DEBUG
            // V0.92 — screenshot mode: push the first room onto
            // the iPhone NavigationStack so the room-detail surface
            // is the first thing on screen when the screenshot
            // fires. Production tap path is unaffected.
            // V0.97+ — also drives the iPad split-view's
            // `selectedRoom` binding so the iPad capture set
            // renders the same room-detail state without
            // requiring a tap on the sidebar.
            if Self.screenshotInitialRoomPush,
               let first = roomService.rooms.first {
                if roomsPath.isEmpty {
                    roomsPath = [first]
                }
                if selectedRoom == nil {
                    selectedRoom = first
                }
            }
            #endif
        }
        .refreshable {
            await roomService.refresh()
            await roomService.loadRoomsSocialProof()
            Haptics.light()
        }
    }

    /// W2.8 — iPad renders a split view (room list sidebar + detail
    /// pane); iPhone keeps the single-column push navigation.
    ///
    /// V0.97+ screenshot bypass — when launched with
    /// `-screenshots-ipad-column`, force the iPhone stack view even on
    /// iPad so the screenshot pipeline can capture the iPhone-column-
    /// centered layout the App Store Connect spec requires. Without
    /// this flag the iPad split-view ships and the captures show a
    /// stretched two-pane, an App Store Connect rejection trigger.
    /// Production builds never see this branch (compile-gated under
    /// `#if DEBUG`); see `screenshotIpadColumnMode`.
    private var isPad: Bool {
        #if DEBUG
        if Self.screenshotIpadColumnMode { return false }
        #endif
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    #if DEBUG
    /// V0.97+ screenshot bypass — `-screenshots-ipad-column` forces the
    /// iPhone stack view on iPad so the iPhone-column-centered capture
    /// renders at iPad size with the black margin the App Store Connect
    /// spec calls for. Production (Release) builds never see this
    /// branch.
    private static var screenshotIpadColumnMode: Bool {
        CommandLine.arguments.contains("-screenshots-ipad-column")
    }
    #endif

    /// iPhone path — the pre-W2.8 NavigationStack, byte-identical.
    /// V0.97+ screenshot bypass — also used on iPad when
    /// `-screenshots-ipad-column` is set, in which case the content
    /// is wrapped in `.contentColumn()` so the iPhone-shaped column
    /// (maxWidth 560pt) renders centered with the black iPad margin
    /// on both sides — matching the App Store Connect spec's
    /// "iPhone column rendered centered with the black iPad margin"
    /// requirement exactly. Without the wrap, the iPad stack view
    /// fills the full iPad width (which a reviewer can still read,
    /// but doesn't match the spec's column treatment).
    private var stackView: some View {
        let column = NavigationStack(path: $roomsPath) {
            content
                .background(Theme.Palette.background.ignoresSafeArea())
                .navigationTitle("Rooms")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
        }
        #if DEBUG
        if isPad && Self.screenshotIpadColumnMode {
            // Wrap in iPhone-shaped column with black iPad margin.
            return AnyView(column.contentColumn())
        }
        #endif
        return AnyView(column)
    }

    /// iPad path — room list as sidebar, detail pane on the right.
    /// NavigationSplitView collapses to a stack in compact widths,
    /// so split-screen multitasking stays usable.
    private var splitView: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Rooms")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
        } detail: {
            NavigationStack {
                if let room = selectedRoom {
                    RoomDetailView(
                        room: room,
                        allRooms: roomService.rooms,
                        onDismiss: { selectedRoom = nil },
                        onSwitchRoom: { _ in }
                    )
                } else {
                    Text("Select a room")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
        }
    }

    /// iPad sidebar — the rooms list as a platform-idiomatic
    /// sidebar List. Selection drives the detail pane.
    private var sidebar: some View {
        Group {
            if roomService.isLoading && roomService.rooms.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Loading rooms…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if roomService.rooms.isEmpty {
                emptyState
            } else {
                List(selection: $selectedRoom) {
                    ForEach(roomService.rooms) { room in
                        NavigationLink(value: room) {
                            HStack(spacing: Theme.Layout.gutter) {
                                if roomService.activeEventByRoom[room.id] != nil {
                                    Circle()
                                        .fill(Theme.Palette.accent)
                                        .frame(width: 8, height: 8)
                                        .accessibilityLabel(Text("Active session"))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.name)
                                        .font(Theme.Typography.body.weight(.semibold))
                                        .foregroundStyle(Theme.Palette.primaryText)
                                    Text(socialProofCaption(for: room) ?? "Tap to open")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                                }
                            }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            recordLastViewed(room)
                        })
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Theme.Palette.background)
            }
        }
    }

    // MARK: - Content slot

    @ViewBuilder
    private var content: some View {
        if roomService.isLoading && roomService.rooms.isEmpty {
            // First-load spinner. Mirrors the dominant-action `.loading`
            // slot — a quiet, centered progress with no chrome.
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.Palette.accent)
                Text("Loading rooms…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if roomService.rooms.isEmpty {
            emptyState
        } else {
            roomsList
        }
    }

    // MARK: - Rooms list (with optional last-viewed hero)

    private var roomsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                if let lastViewed = resolvedLastViewedRoom {
                    lastViewedHero(for: lastViewed)
                }

                sectionHeader("Your rooms")

                LazyVStack(spacing: 0) {
                    ForEach(roomService.rooms) { room in
                        NavigationLink(
                            value: room
                        ) {
                            HStack(spacing: Theme.Layout.gutter) {
                                // M1.2 — session-active indicator. A
                                // small accent dot appears next to the
                                // room name when the room has an
                                // active event cached in RoomService.
                                if roomService.activeEventByRoom[room.id] != nil {
                                    Circle()
                                        .fill(Theme.Palette.accent)
                                        .frame(width: 8, height: 8)
                                        .accessibilityLabel(Text("Active session"))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(room.name)
                                        .font(Theme.Typography.title)
                                        .foregroundStyle(Theme.Palette.primaryText)
                                    Text(socialProofCaption(for: room) ?? "Tap to open")
                                        .font(Theme.Typography.caption)
                                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                                    // V0.55 — overlap badge + season-arc
                                    // preview. Two lines max, no new chrome.
                                    if let overlap = overlapLine(for: room) {
                                        Text(overlap)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.Palette.accent)
                                    }
                                    if let arc = seasonArcLine(for: room) {
                                        Text(arc)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, Theme.Layout.cardInset)
                            .padding(.horizontal, Theme.Layout.edgePadding)
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            recordLastViewed(room)
                        })

                        if room.id != roomService.rooms.last?.id {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                                .padding(.horizontal, Theme.Layout.edgePadding)
                        }
                    }
                }
                .background(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .contentColumn()
            .padding(.vertical, Theme.Layout.sectionSpacing)
        }
        .navigationDestination(for: Room.self) { room in
            RoomDetailView(
                room: room,
                allRooms: roomService.rooms,
                onDismiss: {},
                onSwitchRoom: { _ in }
            )
        }
    }

    private func socialProofCaption(for room: Room) -> String? {
        guard let event = roomService.cachedActiveEvent(roomId: room.id),
              event.startedAt == nil,
              Calendar.current.isDateInToday(event.playedAt)
                || Calendar.current.isDateInTomorrow(event.playedAt) else { return nil }
        return SocialProof.claimedSeatsCaption(
            claimedNames: roomService.cachedEventRSVPs(eventId: event.id)
                .filter { $0.state == .claimed }
                .map { $0.displayName }
        )
    }

    /// V0.55 — the overlap badge line for a room row. Hidden when the
    /// room has no cross-room overlap. Shows the count, or the names
    /// when exactly one overlapping co-member. Never a directory —
    /// count + names only, capped at 5 by the server.
    private func overlapLine(for room: Room) -> String? {
        guard room.overlapCount > 0 else { return nil }
        if room.overlapCount == 1, let name = room.overlapNames.first {
            return "Shared with \\(name) in another room"
        }
        return "\\(room.overlapCount) shared with your other rooms"
    }

    /// V0.55 — the season-arc preview line for a room row. Reuses the
    /// cached season + most recent settled event; no new fetch. Shows
    /// "Season N" plus, when a settled event exists, "last played X
    /// ago". Hidden when the room has no current season.
    private func seasonArcLine(for room: Room) -> String? {
        guard let season = roomService.cachedCurrentSeason(roomId: room.id) else { return nil }
        var line = "Season \(season.ordinal)"
        if let last = roomService.cachedActiveEvent(roomId: room.id),
           let settled = last.settledAt {
            let days = max(0, Int(Date().timeIntervalSince(settled) / 86_400))
            let ago: String
            if days == 0 {
                ago = "tonight"
            } else {
                ago = "\(days) night\(days == 1 ? "" : "s") ago"
            }
            line += " · last played \(ago)"
        }
        return line
    }

    // MARK: - Last-viewed hero

    private func lastViewedHero(for room: Room) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Text("Continue")
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.accent)

            Text(room.name)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)

            // Live state is derived from the active-event cache, NOT
            // from the stored Room.isLive field. The stored field
            // mirrors the room-creation seed and never updates; the
            // amber-dot row indicator above (RoomPage.swift:363-368)
            // and this pill both drive off
            // `roomService.activeEventByRoom[room.id] != nil` so they
            // flip together when a host kicks off / settles an event.
            let hasActiveEvent = roomService.activeEventByRoom[room.id] != nil

            HStack(spacing: 8) {
                Circle()
                    .fill(hasActiveEvent ? Theme.Palette.accent : Theme.Palette.hairline)
                    .frame(width: 8, height: 8)
                Text(hasActiveEvent ? "Live now" : "Last opened")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Spacer(minLength: 8)
                Text(room.mascotName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            NavigationLink(value: room) {
                Text("Resume")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                recordLastViewed(room)
            })
        }
        .sectionCard(.hero)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            Spacer()
            Text("\(roomService.rooms.count)")
                .font(Theme.Typography.footnote.monospacedDigit())
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.40))
        }
        .padding(.horizontal, Theme.Layout.edgePadding)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Layout.cardInset) {
            Spacer(minLength: 0)

            Text(emptyHeadline)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
                .multilineTextAlignment(.center)

            Text(emptySubhead)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Layout.gutter)

            // P0.2: both onboarding paths render equal-weight. The
            // host-create path is the primary (brass-accented fill);
            // the member join path is a quieter outlined button.
            // Members (who don't see the "hosted" badge) get the
            // same pair — a brand-new user with no rooms can become
            // a host of their own room by tapping Create.
            Button(action: openCreateRoom) {
                Text(emptyCTATitle)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 14)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Button(action: openJoinRoom) {
                Text("Ask a friend for a join code")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                    .frame(maxWidth: 320)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .contentColumn()
    }

    private var emptyHeadline: String {
        "No rooms yet"
    }

    private var emptySubhead: String {
        // Members get the join-code path; hosts get the create path.
        // Both choices render regardless — V0.8 keeps both visible
        // so a member can become a host of their own room by
        // tapping Create.
        isKnownHost
            ? "Spin up a room to start running a games night with your group."
            : "Ask a friend for a join code, or create your own room to host."
    }

    private var emptyCTATitle: String {
        isKnownHost ? "Create one to get started" : "Create your own room"
    }

    // MARK: - Empty-state actions (P0.2 wired)

    private func openCreateRoom() {
        showingCreateRoom = true
    }

    private func openJoinRoom() {
        showingJoinRoom = true
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // V0.76 — "Host your own room" create CTA. Always available in
        // the toolbar once the user has at least one room; the empty
        // state already offers a large create button. Any signed-in
        // user can become a host, so this isn't host-gated.
        if !roomService.rooms.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openCreateRoom) {
                    Image(systemName: Theme.Icon.plus)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .accessibilityLabel(Text("Host your own room"))
                .accessibilityHint(Text("Create a new room to run a games night"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openJoinRoom) {
                    Image(systemName: Theme.Icon.personCropCircleBadgePlus)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .accessibilityLabel(Text("Join a room with a code"))
                .accessibilityHint(Text("Enter a friend's join code to become a member"))
            }
        }
        if let room = resolvedLastViewedRoom, room.userRole.isHost {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    settingsRoom = room
                } label: {
                    Image(systemName: Theme.Icon.gearshape)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .accessibilityLabel(Text("Room settings"))
                .accessibilityHint(Text("Opens settings for \(room.name)"))
            }
        }
    }

    // MARK: - Last-viewed resolution

    /// The room the user most recently opened, resolved against the
    /// current `rooms` list. Returns `nil` if no last-viewed id is
    /// stored, the stored id doesn't parse, or the room has been left
    /// since the last view.
    private var resolvedLastViewedRoom: Room? {
        guard
            let uuid = UUID(uuidString: lastViewedRoomIdString),
            let room = roomService.rooms.first(where: { $0.id == uuid })
        else {
            return nil
        }
        return room
    }

    /// Mirrors a tapped room's id into `@AppStorage` so a future cold
    /// launch can resume there. Side-effect-only — kept `func` (not a
    /// computed setter) so the call site reads as an event.
    private func recordLastViewed(_ room: Room) {
        lastViewedRoomIdString = room.id.uuidString
    }

    /// True when the current user has hosted at least one of the rooms
    /// in the list. Used to branch the empty-state CTA. We don't have
    /// a "has ever hosted" signal outside the rooms list, so this is
    /// the closest v0.8 approximation. Defaults to `true` when no
    /// rooms exist — every signed-in user *can* host, and the create
    /// path is the first-class action.
    private var isKnownHost: Bool {
        // In the empty-state branch, we have no rooms. Default true.
        // In the populated branch, true if the user holds host role
        // in at least one room.
        if roomService.rooms.isEmpty { return true }
        return roomService.rooms.contains { $0.userRole.isHost }
    }
}

// MARK: - Preview support
//
// Lightweight fakes so the RoomPage preview compiles without the
// `RoomService` / `AuthService` implementations in tree. These are
// scoped to `#if DEBUG` and are not part of the production surface —
// they only exist so the previews in this file are usable while the
// view layer lands.
#if DEBUG
private enum PreviewSupport {
    @MainActor
    static func roomService() -> RoomService { RoomService.preview() }
    @MainActor
    static func authService() -> AuthService { AuthService.preview() }
}

#Preview("Rooms list") {
    RoomPage()
        .environmentObject(PreviewSupport.roomService())
        .environmentObject(PreviewSupport.authService())
        .environmentObject(CasinoService())
        .preferredColorScheme(.dark)
}
#endif
