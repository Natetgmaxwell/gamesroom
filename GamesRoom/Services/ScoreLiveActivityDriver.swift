//
//  ScoreLiveActivityDriver.swift
//  GamesRoom
//
//  Track F-MVP-12 (W2.3) — the app-side Live Activity driver.
//
//  The widget target declares the Live Activity surface; this is
//  the app-side counterpart that starts, updates, and ends it per
//  the vision lifecycle: surface for pre-play briefing and
//  post-settle ceremonial, never during play ("No Live Activity
//  during play"). The widget stays in the system UI for up to
//  8 hours (system cap), so a settle ends the activity and the
//  next pre-play event starts a fresh one.
//
//  All calls are best-effort: ActivityKit requests can fail
//  (permission, system limits) and the app must keep working.
//

import Foundation
import ActivityKit

/// Mirrors the widget target's `ScoreActivityAttributes` (no
/// shared framework). Keep the attribute + content shapes in sync
/// with GamesRoomWidgets/GamesRoomWidgets.swift.
struct ScoreActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var leaderboardLine: String
    }

    var roomName: String
}

/// Drives the score Live Activity from the app side. The rules
/// live in `LiveActivityRule` (Foundation-only, tested).
enum ScoreLiveActivityDriver {

    /// Applies the lifecycle rule for one refresh. Call from the
    /// detail view's refresh path with the current snapshot state.
    static func apply(
        roomName: String,
        leaderboardLine: String,
        isLive: Bool
    ) {
        let running = Activity<ScoreActivityAttributes>.activities
            .first(where: { $0.attributes.roomName == roomName })

        switch LiveActivityRule.action(isLive: isLive, hasLine: !leaderboardLine.isEmpty, isRunning: running != nil) {
        case .startOrUpdate:
            startOrUpdate(roomName: roomName, leaderboardLine: leaderboardLine)
        case .end:
            end(roomName: roomName)
        case .none:
            break
        }
    }

    private static func startOrUpdate(roomName: String, leaderboardLine: String) {
        let running = Activity<ScoreActivityAttributes>.activities
            .first(where: { $0.attributes.roomName == roomName })

        if let running {
            Task {
                await running.update(
                    using: ScoreActivityAttributes.ContentState(leaderboardLine: leaderboardLine)
                )
            }
            return
        }

        let attributes = ScoreActivityAttributes(roomName: roomName)
        let state = ScoreActivityAttributes.ContentState(leaderboardLine: leaderboardLine)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {
            // Best-effort: permission or system-limit failure is
            // non-fatal; the widget Glance still renders.
        }
    }

    private static func end(roomName: String) {
        let running = Activity<ScoreActivityAttributes>.activities
            .first(where: { $0.attributes.roomName == roomName })
        guard let running else { return }
        Task {
            await running.end(nil, dismissalPolicy: .immediate)
        }
    }
}
