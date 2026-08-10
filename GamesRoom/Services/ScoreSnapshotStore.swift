//
//  ScoreSnapshotStore.swift
//  GamesRoom
//
//  Track F-MVP-12 (W2.3) — app-side score snapshot writer.
//
//  The widget extension + watch app are separate processes; the
//  App Group UserDefaults suite is the shared channel. This store
//  writes the room's current standings after every refresh so the
//  Glance renders live data. The widget target compiles its own
//  mirror of `ScoreSnapshot` (no shared framework).
//

import Foundation

/// Writes the score snapshot the widget + watch read. The suite
/// must match the App Group entitlement
/// (`group.com.gamesroom.app`) on both targets.
enum ScoreSnapshotStore {

    static let suiteName = "group.com.gamesroom.app"
    private static let key = "scoreSnapshot"

    /// Persists the room's current standings. Called from
    /// `RoomService.refresh()` after the rooms list lands and from
    /// `RoomDetailView.refresh()` after the leaderboard loads.
    /// Best-effort: a missing App Group entitlement or a failed
    /// encode is non-fatal (the widget renders its placeholder).
    static func write(
        roomName: String,
        leaderboardLine: String,
        isLive: Bool
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        let snapshot = ScoreSnapshot(
            roomName: roomName,
            leaderboardLine: leaderboardLine,
            isLive: isLive,
            updatedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }
}

/// The snapshot payload. Mirrors the widget target's copy — keep
/// the two in sync (the widget compiles its own because there is
/// no shared framework between the app and the extension).
struct ScoreSnapshot: Codable {
    var roomName: String
    var leaderboardLine: String
    var isLive: Bool
    var updatedAt: Date
}
