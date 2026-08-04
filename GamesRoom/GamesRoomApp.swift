//
//  GamesRoomApp.swift
//  GamesRoom
//
//  Track E1 — app entry point.
//
//  Owns the app-level `AuthService` so the entire view tree shares
//  a single instance. `ContentView` reads it as `@EnvironmentObject`
//  and drives the sign-in sheet from `AuthService.currentUser`.
//
//  ponytail: AuthService is `@MainActor` and constructs without
//  side effects — its `loadCurrentUser()` is called by `ContentView`
//  in its `.task` modifier on first appearance. We do not call it
//  here so that app launch stays synchronous.
//
//

import Foundation
import SwiftUI
import Supabase

@main
struct GamesRoomApp: App {
    @StateObject private var auth = AuthService()
    @StateObject private var roomService = RoomService()
    @StateObject private var casinoService = CasinoService()
    @StateObject private var scoringService = ScoringService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(roomService)
                .environmentObject(casinoService)
                .environmentObject(scoringService)
        }
    }
}
