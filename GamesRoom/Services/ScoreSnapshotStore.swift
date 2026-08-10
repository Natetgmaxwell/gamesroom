//
//  ScoreSnapshotStore.swift
//  GamesRoom
//
//  Track F-MVP-12 (W2.3) — app-side score snapshot writer.
//
//  The widget extension + watch app are separate processes; the
//  App Group UserDefaults suite is the shared channel. This store
//  writes the room's current standings after every refresh so the
//  Glance renders live data. The widget + watch targets compile
//  their own mirrors of `ScoreSnapshot` (no shared framework).
//

import Foundation

/// Writes the score snapshot the widget + watch read. The suite
/// must match the App Group entitlement
/// (`group.com.gamesroom.app`) on all three targets.
enum ScoreSnapshotStore {

    static let suiteName = "group.com.gamesroom.app"
    private static let key = "scoreSnapshot"

    /// Persists the room's current standings. Called from
    /// `RoomService.refresh()` after the rooms list lands and from
    /// `RoomDetailView.refresh()` after the leaderboard loads.
    /// Best-effort: a missing App Group entitlement or a failed
    /// encode is non-fatal (the widget renders its placeholder).
    /// A stale empty write never clobbers real standings
    /// (`ScoreSnapshot.shouldPersist`).
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
        let existing = load()
        guard ScoreSnapshot.shouldPersist(snapshot, existing: existing) else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Reads the current snapshot, if any.
    static func load() -> ScoreSnapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScoreSnapshot.self, from: data)
    }
}
