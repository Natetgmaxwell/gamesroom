//
//  ScoreSnapshot.swift
//  GamesRoom
//
//  Tracks F-MVP-12 (W2.3) — the widget/watch snapshot payload and
//  the pure persistence + Live Activity rules.
//
//  Foundation-only so the test runner compiles it. The widget and
//  watch targets compile their own mirrors of `ScoreSnapshot` (no
//  shared framework); the app-side copy lives here.
//

import Foundation

/// The score snapshot the app writes to the App Group suite and the
/// widget + watch read. Keep the mirrors in `GamesRoomWidgets/` and
/// `GamesRoomWatch/` in sync with this struct.
struct ScoreSnapshot: Codable {
    var roomName: String
    var leaderboardLine: String
    var isLive: Bool
    var updatedAt: Date

    /// True when `incoming` should replace `existing`.
    ///
    /// The rooms-list refresh (`RoomService.refresh()`) writes an
    /// empty leaderboard line before the detail view has loaded the
    /// real standings. That empty write must never clobber a
    /// non-empty snapshot, or the Glance loses the leaderboard
    /// until the room is reopened.
    static func shouldPersist(_ incoming: ScoreSnapshot, existing: ScoreSnapshot?) -> Bool {
        guard let existing else { return true }
        if incoming.leaderboardLine.isEmpty && !existing.leaderboardLine.isEmpty {
            return false
        }
        return incoming.updatedAt >= existing.updatedAt
    }
}

/// The Live Activity lifecycle rule — 2026-09-02 product reversal
/// (Nathan): the score activity surfaces ONLY while an event is
/// active (started, not settled). No active event = no Live
/// Activity; the phone stays out of the room. The old
/// "briefing + ceremonial" surface kept the score pinned on the
/// lock screen between nights, which pulled members back into the
/// app exactly when they should be present at the table.
enum LiveActivityRule {
    enum Action: Equatable {
        case startOrUpdate
        case end
        case none
    }

    static func action(isLive: Bool, hasLine: Bool, isRunning: Bool) -> Action {
        if isLive {
            // Active event: surface + keep the line fresh. An empty
            // line has nothing worth showing — end a running activity,
            // no-op when none exists.
            return hasLine ? .startOrUpdate : (isRunning ? .end : .none)
        }
        // No active event: end whatever is running, schedule nothing.
        return isRunning ? .end : .none
    }
}
