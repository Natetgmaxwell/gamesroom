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
//  Auth gate: while `AuthService.currentUser` is `nil`, the
//  `SignInView` is presented as a sheet over the `TabView`. The
//  sheet is driven by a custom binding whose getter reads
//  `currentUser` directly — when sign-in succeeds and
//  `loadCurrentUser()` populates `currentUser`, the getter flips
//  to `false` and the sheet dismisses automatically. When the
//  user signs out, the same path re-presents the sheet.
//
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
    @State private var selectedTab: AppTab = .rooms

    var body: some View {
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

    /// Drives the sign-in sheet from the auth state. The getter is
    /// `currentUser == nil`; the setter is intentionally a no-op
    /// because the sheet is owned by auth, not by user interaction
    /// (the user signs in *inside* the sheet; they never dismiss it
    /// manually — sign-in success flips `currentUser` to non-nil
    /// and the binding closes the sheet).
    private var signInBinding: Binding<Bool> {
        Binding(
            get: { auth.currentUser == nil },
            set: { _ in }
        )
    }
}
