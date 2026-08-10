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

/// The vision lifecycle rule for the Live Activity score surface:
/// surface for pre-play briefing and post-settle ceremonial, never
/// during play ("No Live Activity during play").
enum LiveActivityRule {
    enum Action: Equatable {
        case startOrUpdate
        case end
        case none
    }

    static func action(isLive: Bool, hasLine: Bool, isRunning: Bool) -> Action {
        if isLive {
            return isRunning ? .end : .none
        }
        if hasLine {
            return .startOrUpdate
        }
        return .none
    }
}
