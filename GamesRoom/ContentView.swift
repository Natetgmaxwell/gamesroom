//
//  ContentView.swift
//  GamesRoom
//
//  Track E1 — root navigation.
//
//  Two form factors, two layouts:
//
//    iPhone (compact width)
//    ----------------------
//    Two-tab `TabView` per V0.8 Layout Decisions L6:
//      * Rooms tab (default, systemImage: "house.fill") hosting
//        `RoomPage` inside its own `NavigationStack`.
//      * Settings tab (systemImage: "gearshape") hosting
//        `SettingsPage` inside its own `NavigationStack`.
//
//    iPad (regular width)
//    --------------------
//    Sidebar owns navigation. `RoomPage` already renders a
//    `NavigationSplitView` with a room-list sidebar + detail pane;
//    the iPad path now mounts `RoomPage` directly (no TabView
//    wrapper). Settings is reachable from a single entry in the
//    sidebar's overflow / toolbar — the previous iPad layout
//    showed both Rooms AND Settings as top tabs of a `TabView`
//    even though the sidebar already owned room selection, which
//    was duplicated chrome. The Settings tab is now removed from
//    the iPad path; the sidebar + the in-room toolbar carry
//    every affordance the user needs.
//
//  "Last-viewed room opens the Rooms tab automatically" (Track A
//  Persistent home) is `RoomPage`'s job — it owns
//  `@AppStorage("lastViewedRoomIdString")` and resolves its own
//  initial room. `ContentView` does not need to know about the
//  stored id; the Rooms tab is always the default selection on
//  iPhone.
//
//  Cold-start session restore: `AuthService.currentUser` is an
//  in-memory `@Published` property — on app launch it is `nil`
//  even when Supabase has a valid session in the keychain. The
//  root `.task` calls `auth.loadCurrentUser()` once on first
//  appearance; while that is in flight we render a splash
//  (`Theme.Palette.background` + `ProgressView()`) instead of the
//  navigation surface, so the sign-in sheet never flashes for a
//  user who is already signed in.
//
//  Auth gate: once restore has finished, `signInBinding` shows
//  the `SignInView` sheet over the navigation surface iff
//  `auth.currentUser` is `nil`. The setter is intentionally a
//  no-op — the user signs in *inside* the sheet; they never
//  dismiss it manually. Sign-in success flips `currentUser` to
//  non-nil and the binding closes the sheet. Sign-out re-presents
//  it through the same path.
//
//  Form-factor gate: `isPadRegularWidth` reads the
//  horizontal-size-class from the environment. `.regular` means
//  iPad in full-screen landscape/portrait AND iPad multitasking
//  split-screen at >=50% split — exactly the width we want to
//  treat as "sidebar lives here". Below that width, we fall back
//  to the iPhone TabView so compact multitasking and iPhone stay
//  identical.
//

import Foundation
import SwiftUI
import Supabase
import Combine

struct ContentView: View {
    /// The two tabs in the V0.8 root navigation (iPhone only).
    enum AppTab: Hashable {
        case rooms
        case settings
    }

    @EnvironmentObject private var auth: AuthService
    /// V0.77 — injected by `GamesRoomApp`; the realtime lifecycle
    /// start passes it to `RealtimeEventService` as the rooms cache.
    @EnvironmentObject private var roomService: RoomService
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .rooms
    @State private var isRestoringSession = true

    /// The rooms a tapped notification asked the app to open, pushed
    /// onto the rooms stack (the iPhone path). `RoomPage` selects a
    /// room the same way — a `Room` value on the stack's path — so a
    /// tap lands on exactly the surface a tap on the room row does.
    @State private var openRoomPath: [Room] = []

    /// The room a tapped notification asked the app to open on iPad.
    /// The iPad detail pane belongs to `RoomPage`'s split view, so
    /// the room is presented over it instead of pushed beside it.
    @State private var presentedRoom: Room?

    /// An open-room request waiting for the rooms list to resolve
    /// it. A tap can land before the rooms have loaded (a cold start
    /// from a notification tap), and a room the user is no longer in
    /// is simply never opened.
    @State private var pendingOpenRoomId: UUID?
    @State private var pendingOpenEventId: UUID?

    /// True when the current width qualifies for the iPad sidebar
    /// layout. `.regular` covers full-screen iPad AND iPad
    /// multitasking split-screen at >=50% split; below that the
    /// iPhone-shaped TabView renders.
    private var isPadRegularWidth: Bool {
        hSize == .regular
    }

    #if DEBUG
    /// V0.92 — screenshot mode initial-tab selection. Read from
    /// `-screenshots-tab=rooms|settings`; falls back to `.rooms`.
    private static var screenshotInitialTab: AppTab {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("-screenshots-tab=") }) {
            return arg == "-screenshots-tab=settings" ? .settings : .rooms
        }
        return .rooms
    }

    /// V0.97+ — `-screenshots-ipad-layout` forces the iPad
    /// sidebar layout (rooms + sidebar) on iPad so the
    /// screenshot pipeline captures the iPad-correct chrome.
    /// `-screenshots-ipad-column` forces the iPhone layout on
    /// iPad (the App Store Connect column-on-iPad screenshot
    /// workaround). Defaults to the iPad sidebar layout on
    /// regular-width iPad.
    private static var screenshotForceIPadSidebar: Bool {
        CommandLine.arguments.contains("-screenshots-ipad-layout")
    }
    private static var screenshotForceIPhoneLayout: Bool {
        CommandLine.arguments.contains("-screenshots-ipad-column")
    }
    #endif

    var body: some View {
        Group {
            if isRestoringSession {
                Theme.Palette.background
                    .ignoresSafeArea()
                    .overlay(ProgressView())
            } else {
                if usesIPadSidebar {
                    iPadSidebarLayout
                } else {
                    iPhoneTabLayout
                }
            }
        }
        .task {
            #if DEBUG
            // V0.92 screenshot bypass: when launched with
            // `-screenshots-bypass-auth`, skip the real Supabase auth
            // check and load a stubbed currentUser so screenshots can
            // capture in-app surfaces (rooms list, room detail,
            // casino, settings) without going through Apple Sign-In.
            // Production builds (Release) never see this branch.
            if CommandLine.arguments.contains("-screenshots-bypass-auth") {
                auth.injectStubUserForScreenshots()
                isRestoringSession = false
                return
            }
            #endif
            await auth.loadCurrentUser()
            isRestoringSession = false
        }
        // V0.77 — realtime event subscription lifecycle. Start when
        // a session exists (cold launch restore or fresh sign-in),
        // stop on sign-out. `onChange` fires on the publish; the
        // nil→user transition also covers the post-sign-in path.
        .onChange(of: auth.currentUser?.id) { _, newUserId in
            Task {
                if newUserId != nil {
                    QuestionBoxPushRegistration.registerIfPossible()
                    await RealtimeEventService.shared.start(roomService: roomService)
                } else {
                    await RealtimeEventService.shared.stop()
                }
            }
        }
        // Cold-launch path: a restored session doesn't always trip
        // onChange (currentUser goes nil→user inside loadCurrentUser,
        // which does fire, but the sheet-gated state can swallow the
        // first emit). Belt-and-braces start attempt after restore.
        .task(id: "realtime-start") {
            if auth.currentUser != nil {
                await RealtimeEventService.shared.start(roomService: roomService)
            }
        }
        // Cold-launch reconcile (audit 04 D2). `.onChange(of: scenePhase)`
        // never fires for the phase the app launched in, so a kill then
        // relaunch into the room list ran no pass at all: no purge of
        // the rooms left or been kicked from while the app was closed,
        // no re-plan, no Live Activity end. This task runs once per
        // signed-in user id — cold launch and fresh sign-in alike — and
        // `AppReconciler.isRunning` coalesces it with the scenePhase
        // `.active` pass that may follow.
        .task(id: auth.currentUser?.id) {
            guard auth.currentUser != nil else { return }
            await AppReconciler.shared.appBecameActive(roomService: roomService)
        }
        // A tapped briefing (on-create, the reminders, the catch-up)
        // or a tapped anchor nudge opens the room it belongs to.
        .onReceive(NotificationCenter.default.publisher(for: .gamesRoomOpenRoom)) { _ in
            takeOpenRoomRequest()
        }
        // The same request, taken on appear: a tap that lands while
        // the app is still launching is latched by `OpenRoomRequest`
        // and would otherwise be posted to nobody.
        .onAppear {
            takeOpenRoomRequest()
        }
        // The rooms list is what resolves the request, so a room
        // that is still loading is opened as soon as it arrives.
        .onChange(of: roomService.rooms) { _, _ in
            openPendingRoomIfReady()
        }
        // Every return to the foreground converges the phone on the
        // server: purge rooms the user left or was removed from,
        // re-plan reminders for the current seat, restart realtime.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !isRestoringSession, auth.currentUser != nil else { return }
            Task {
                await AppReconciler.shared.appBecameActive(roomService: roomService)
            }
        }
    }

    // MARK: - Open room from a notification tap

    /// Takes the latched open-room request, if there is one.
    private func takeOpenRoomRequest() {
        guard let request = OpenRoomRequest.shared.take() else { return }
        pendingOpenRoomId = request.roomId
        pendingOpenEventId = request.eventId
        openPendingRoomIfReady()
    }

    /// Opens the pending room once the rooms list can resolve it.
    /// The room id is the payload's; a request scheduled before the
    /// payload carried one falls back to the event's cached room.
    private func openPendingRoomIfReady() {
        guard let eventId = pendingOpenEventId else { return }
        let rooms = roomService.rooms
        var match: Room?
        if let roomId = pendingOpenRoomId {
            match = rooms.first { $0.id == roomId }
        }
        if match == nil {
            match = rooms.first { roomService.activeEventByRoom[$0.id]?.id == eventId }
        }
        guard let room = match else { return }
        pendingOpenRoomId = nil
        pendingOpenEventId = nil
        open(room)
    }

    /// Opens one room. iPhone pushes it onto the rooms stack, the
    /// same way a tap on the room row does; iPad presents it over
    /// the split view, whose detail pane `RoomPage` owns.
    private func open(_ room: Room) {
        if usesIPadSidebar {
            presentedRoom = room
        } else {
            selectedTab = .rooms
            openRoomPath.append(room)
        }
    }

    /// True when the iPad sidebar layout should render instead of
    /// the iPhone TabView. Production rule: regular width.
    /// DEBUG-only overrides let the screenshot pipeline force
    /// either layout independently of the device width class.
    private var usesIPadSidebar: Bool {
        #if DEBUG
        if Self.screenshotForceIPhoneLayout { return false }
        if Self.screenshotForceIPadSidebar { return true }
        #endif
        return isPadRegularWidth
    }

    // MARK: - iPhone TabView (unchanged from V0.8)

    private var iPhoneTabLayout: some View {
        #if DEBUG
        let initialTab = Self.screenshotInitialTab
        #else
        let initialTab = AppTab.rooms
        #endif
        return TabView(selection: $selectedTab) {
            NavigationStack(path: $openRoomPath) {
                RoomPage()
                    // The destination a tapped notification pushes
                    // to. `RoomPage` keeps its own stack and its own
                    // destination for the room rows; this one serves
                    // the rooms the app is asked to open.
                    .navigationDestination(for: Room.self) { room in
                        RoomDetailView(
                            room: room,
                            allRooms: roomService.rooms,
                            onDismiss: {},
                            onSwitchRoom: { _ in }
                        )
                    }
            }
            .tabItem {
                Label("Rooms", systemImage: "house.fill")
            }
            .tag(AppTab.rooms)

            NavigationStack {
                SettingsPage()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }
            .tag(AppTab.settings)
        }
        .tint(Theme.Palette.accent)
        #if DEBUG
        .onAppear { selectedTab = initialTab }
        #endif
        .sheet(isPresented: signInBinding) {
            SignInView(authService: auth)
        }
    }

    // MARK: - iPad sidebar layout

    /// iPad regular-width layout. Mounts `RoomPage` directly — the
    /// page already owns a `NavigationSplitView` with a room-list
    /// sidebar + detail pane. The Settings tab that used to ride
    /// alongside in a `TabView` is gone; Settings is reachable
    /// from the sidebar's own overflow / toolbar entry (a sheet
    /// over the iPad layout), keeping exactly one way to reach
    /// Settings per form factor.
    private var iPadSidebarLayout: some View {
        RoomPage()
            .tint(Theme.Palette.accent)
            .sheet(isPresented: signInBinding) {
                SignInView(authService: auth)
            }
            // A tapped notification opens the room over the split
            // view. The room detail owns no dismiss control of its
            // own, so the stack carries one.
            .fullScreenCover(item: $presentedRoom) { room in
                NavigationStack {
                    RoomDetailView(
                        room: room,
                        allRooms: roomService.rooms,
                        onDismiss: { presentedRoom = nil },
                        onSwitchRoom: { _ in }
                    )
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Rooms") { presentedRoom = nil }
                        }
                    }
                }
            }
    }

    /// Drives the sign-in sheet from the auth state, gated by the
    /// cold-start restore window. During restore the getter is
    /// `false` so the sheet never flashes for a user who is
    /// already signed in; once restore has finished, it tracks
    /// `auth.currentUser`. The setter is intentionally a no-op
    /// because the sheet is owned by auth, not by user interaction.
    private var signInBinding: Binding<Bool> {
        Binding(
            get: { isRestoringSession ? false : auth.currentUser == nil },
            set: { _ in }
        )
    }
}
