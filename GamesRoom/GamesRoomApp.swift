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
    @UIApplicationDelegateAdaptor(GamesRoomAppDelegate.self) private var appDelegate
    @StateObject private var auth = AuthService()
    #if DEBUG
    // V0.92 screenshot mode — when launched with
    // `-screenshots-bypass-auth`, swap the live Supabase store for
    // `InMemoryRoomStore.shared` so the screens render against the
    // seeded rooms / events / casino state instead of an empty
    // network-backed fetch. Production builds never see this branch.
    private static func makeScreenshotStore() -> RoomStore {
        CommandLine.arguments.contains("-screenshots-bypass-auth")
            ? InMemoryRoomStore.shared
            : LiveRoomStore.shared
    }
    @StateObject private var roomService = RoomService(store: GamesRoomApp.makeScreenshotStore())
    @StateObject private var questionBox = QuestionBoxService(
        store: CommandLine.arguments.contains("-screenshots-bypass-auth")
            ? InMemoryRoomStore.shared as QuestionBoxStore
            : LiveQuestionBoxStore.shared
    )
    #else
    @StateObject private var roomService = RoomService(store: LiveRoomStore.shared)
    @StateObject private var questionBox = QuestionBoxService(store: LiveQuestionBoxStore.shared)
    #endif
    @StateObject private var casinoService = CasinoService()
    @StateObject private var scoringService = ScoringService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .textCase(nil)
                .environmentObject(auth)
                .environmentObject(roomService)
                .environmentObject(casinoService)
                .environmentObject(scoringService)
                .environmentObject(questionBox)
                // V0.106 — the reader's full-screen card. Presented app-wide
                // so it reaches the reader wherever they are in the app.
                .fullScreenCover(item: $questionBox.readerCard) { turn in
                    QuestionReaderCard(
                        turn: turn,
                        onDone: { Task { await questionBox.respond(turn, action: .done) } },
                        onPass: { Task { await questionBox.respond(turn, action: .pass) } }
                    )
                }
                .onAppear { GamesRoomAppDelegate.questionBox = questionBox }
                // The palette is dark-mode-first (near-black canvas,
                // warm parchment text, brass accent). Forcing dark
                // scheme at the root keeps system surfaces (Form
                // rows, sheets, pickers) on the same canvas — without
                // it, a light-mode device renders white form
                // backgrounds under the dark palette and the bronze
                // text loses all contrast (settings-modal readability
                // bug, 2026-08-10 feedback).
                .preferredColorScheme(.dark)
        }
    }
}
