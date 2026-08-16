//
//  ContentView.swift
//  GamesRoom
//
//  Track E1 — root navigation.
//
//  Two-tab `TabView` per V0.8 Layout Decisions L6:
//
//    * Rooms tab (default, systemImage: "house.fill") hosting
//      `RoomPage` inside its own `NavigationStack`.
//    * Settings tab (systemImage: "gearshape") hosting
//      `SettingsPage` inside its own `NavigationStack`.
//
//  "Last-viewed room opens the Rooms tab automatically" (Track A
//  Persistent home) is `RoomPage`'s job — it owns
//  `@AppStorage("lastViewedRoomIdString")` and resolves its own
//  initial room. `ContentView` does not need to know about the
//  stored id; the Rooms tab is always the default selection.
//
//  Cold-start session restore: `AuthService.currentUser` is an
//  in-memory `@Published` property — on app launch it is `nil`
//  even when Supabase has a valid session in the keychain. The
//  root `.task` calls `auth.loadCurrentUser()` once on first
//  appearance; while that is in flight we render a splash
//  (`Theme.Palette.background` + `ProgressView()`) instead of the
//  `TabView`, so the sign-in sheet never flashes for a user who
//  is already signed in.
//
//  Auth gate: once restore has finished, `signInBinding` shows
//  the `SignInView` sheet over the `TabView` iff
//  `auth.currentUser` is `nil`. The setter is intentionally a
//  no-op — the user signs in *inside* the sheet; they never
//  dismiss it manually. Sign-in success flips `currentUser` to
//  non-nil and the binding closes the sheet. Sign-out re-presents
//  it through the same path.
//

import Foundation
import SwiftUI
import Supabase

struct ContentView: View {
    /// The two tabs in the V0.8 root navigation.
    enum AppTab: Hashable {
        case rooms
        case settings
    }

    @EnvironmentObject private var auth: AuthService
    /// V0.77 — injected by `GamesRoomApp`; the realtime lifecycle
    /// start passes it to `RealtimeEventService` as the rooms cache.
    @EnvironmentObject private var roomService: RoomService
    @State private var selectedTab: AppTab = .rooms
    @State private var isRestoringSession = true

    var body: some View {
        Group {
            if isRestoringSession {
                Theme.Palette.background
                    .ignoresSafeArea()
                    .overlay(ProgressView())
            } else {
                TabView(selection: $selectedTab) {
                    NavigationStack {
                        RoomPage()
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
                .sheet(isPresented: signInBinding) {
                    SignInView(authService: auth)
                }
            }
        }
        .task {
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
