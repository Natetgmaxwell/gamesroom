//
//  ScoreLiveActivityDriver.swift
//  GamesRoom
//
//  Track F-MVP-12 (W2.3) — the app-side Live Activity driver.
//
//  The widget target declares the Live Activity surface; this is the
//  app-side counterpart that starts, updates, and ends it.
//
//  The rule is the 2026-09-02 product reversal (Nathan): the score
//  activity surfaces ONLY while an event is live — started, not
//  settled, and still inside the room's `autoCloseHours`. No live
//  night, no Live Activity: the phone stays out of the room. An
//  activity also carries a `staleDate` (the moment the night stops
//  being live), so a settle this phone never heard about still shows
//  as stale rather than pinned fresh forever, and the foreground
//  reconcile ends it outright.
//
//  Identity is the room id, not the room name: two rooms may share a
//  name (audit 01 D11, 04 D9).
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

    /// The room the activity belongs to. Every match keys on this.
    var roomId: UUID
    /// Display only.
    var roomName: String
}

/// Drives the score Live Activity from the app side. The rules
/// live in `LiveActivityRule` (Foundation-only, tested).
enum ScoreLiveActivityDriver {

    /// Applies the lifecycle rule for one refresh. Call from the
    /// detail view's refresh path with the current snapshot state.
    ///
    /// `staleDate` is the moment the night stops being live; a running
    /// activity is re-requested with it on every update so a phone that
    /// stops receiving updates still ages out instead of pinning the
    /// scoreboard forever.
    static func apply(
        roomId: UUID,
        roomName: String,
        leaderboardLine: String,
        isLive: Bool,
        staleDate: Date?
    ) {
        let running = Activity<ScoreActivityAttributes>.activities
            .first(where: { $0.attributes.roomId == roomId })

        switch LiveActivityRule.action(
            isLive: isLive, hasLine: !leaderboardLine.isEmpty, isRunning: running != nil
        ) {
        case .startOrUpdate:
            startOrUpdate(
                roomId: roomId,
                roomName: roomName,
                leaderboardLine: leaderboardLine,
                staleDate: staleDate
            )
        case .end:
            end(roomId: roomId)
        case .none:
            break
        }
    }

    /// The reconcile's pass over one room: end the activity if its
    /// night is no longer live. It never starts one — a pass has no
    /// leaderboard line to show (audit 04 commit 9).
    ///
    /// TODO(SM-P): `isLive` becomes `NightPhase == .live` once lane P
    /// lands `NightPhase`; this call site must not grow its own phase
    /// type.
    static func endIfNightNotLive(roomId: UUID, isLive: Bool) {
        guard LiveActivityRule.reconcileAction(isLive: isLive) == .end else { return }
        end(roomId: roomId)
    }

    private static func startOrUpdate(
        roomId: UUID,
        roomName: String,
        leaderboardLine: String,
        staleDate: Date?
    ) {
        let running = Activity<ScoreActivityAttributes>.activities
            .first(where: { $0.attributes.roomId == roomId })

        if let running {
            let state = ScoreActivityAttributes.ContentState(
                leaderboardLine: leaderboardLine
            )
            Task {
                // `update(_ ActivityContent)` carries the staleDate, so
                // a running activity ages out even when this path is the
                // last one to touch it.
                await running.update(
                    ActivityContent(state: state, staleDate: staleDate)
                )
            }
            return
        }

        let attributes = ScoreActivityAttributes(roomId: roomId, roomName: roomName)
        let state = ScoreActivityAttributes.ContentState(leaderboardLine: leaderboardLine)
        do {
            _ = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: staleDate)
            )
        } catch {
            // Best-effort: permission or system-limit failure is
            // non-fatal; the widget Glance still renders.
        }
    }

    /// S1.5 — the host settled the night: end the room's activity
    /// now rather than on the next refresh.
    static func endNight(roomId: UUID) {
        end(roomId: roomId)
    }

    /// Ends every activity for the room. `nil` content keeps the last
    /// rendered state; `.immediate` removes it from the lock screen.
    private static func end(roomId: UUID) {
        for running in Activity<ScoreActivityAttributes>.activities
        where running.attributes.roomId == roomId {
            Task {
                await running.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
