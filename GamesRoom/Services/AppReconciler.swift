//
//  AppReconciler.swift
//  GamesRoom
//
//  Lane S2 step 5: the foreground reconcile.
//
//  Every time the app comes back to the foreground the phone
//  converges on the server's truth for this user:
//   1. the rooms list is re-read, and every room the user is no
//      longer in (they left, or the host removed them) is purged
//      from the phone: its pending and delivered notifications,
//      its calendar rows, its Live Activity and the widget's
//      snapshot when it shows that room;
//   2. every room the user is a member of re-reads its night — even
//      one this device never opened, whose cached night therefore
//      does not exist — and re-plans this user's reminders for their
//      current seat;
//   3. the realtime subscription is restarted, because iOS drops
//      the socket while the app is suspended and the INSERTs it
//      missed are exactly the nights step 2 just caught up on.
//
//  The pure decisions (which rooms were removed, which requests
//  belong to a room) live in `BriefingReconciler` so the unit
//  runner covers them.
//

import Foundation
import WidgetKit

@MainActor
final class AppReconciler {

    static let shared = AppReconciler()

    /// Foreground events can arrive back to back (a notification
    /// banner, Control Centre). One pass at a time is enough.
    private var isRunning = false

    private init() {}

    /// The app became active. Safe to call on every `.active`
    /// scene phase: concurrent calls coalesce into the running pass.
    func appBecameActive(roomService: RoomService) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        // Signed out: there is nothing of this user's to converge,
        // and an empty rooms list must never read as "removed from
        // every room".
        guard await SupabaseClientProvider.currentSession() != nil else { return }

        // 1. Rooms the user is no longer in. A failed refresh leaves
        // the list as it was, so a dropped connection purges nothing.
        let oldRooms = roomService.rooms
        let cachedEventIdByRoom = roomService.activeEventByRoom.mapValues(\.id)
        await roomService.refresh()
        let currentRoomIds = roomService.rooms.map(\.id)
        let removed = BriefingReconciler.removedRoomIds(
            old: oldRooms.map(\.id),
            new: currentRoomIds
        )
        for roomId in removed {
            await roomService.purgeRoom(roomId: roomId)
            // The room's surfaces are ended by ID, not by name: two
            // rooms may share a name, and a rename used to orphan them
            // (audit 01 D11, 04 D9).
            Self.endRoomSurfaces(roomId: roomId)
        }

        // 2. Re-read each room's night and re-plan this user's
        // reminders for their current seat. EVERY member room is
        // visited, not only the ones with a cached night: a room this
        // device has never opened still has a night the host may have
        // scheduled while the member was away, and it is the only way
        // that member learns about it while server push is off
        // (audit 04 D3). A night that ended or was replaced while the
        // app slept has its old requests swept first.
        let plan = BriefingReconciler.foregroundRoomPlan(
            memberRoomIds: currentRoomIds,
            cachedEventIdByRoom: cachedEventIdByRoom
        )
        for step in plan {
            let fresh = await roomService.loadActiveEvent(
                roomId: step.roomId, force: true
            )
            if let staleEventId = step.staleEventId, fresh?.id != staleEventId {
                await NotificationDispatcher.shared.cancelBriefingTrio(
                    eventId: staleEventId
                )
            }
            if let fresh {
                await roomService.reconcileBriefing(eventId: fresh.id)
            }
            // A night that ended while the app was asleep takes its
            // scoreboard with it; the old code ended the activity only
            // from a room refresh or a host settle, so a member's
            // lock screen kept showing a finished night (audit 04
            // commit 9).
            ScoreLiveActivityDriver.endIfNightNotLive(
                roomId: step.roomId,
                isLive: Self.isNightLive(fresh)
            )
        }

        // 3. Restart the realtime subscription.
        await RealtimeEventService.shared.stop()
        await RealtimeEventService.shared.start(roomService: roomService)
    }

    /// Reports the device time zone for a room this user hosts, once
    /// per room per install. The RPC (`set_room_time_zone`) ships in
    /// another lane and may not exist yet: the call is fire and
    /// forget, every failure is swallowed, and the flag is set only
    /// on success so a later room open tries again.
    static func reportRoomTimeZoneOnce(roomId: UUID) {
        let key = StorageKeys.roomTimeZoneReported(roomId: roomId)
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let params = SetRoomTimeZoneParams(
            p_room_id: roomId.uuidString,
            p_tz: TimeZone.current.identifier
        )
        Task {
            let sent: Void? = try? await SupabaseClientProvider.shared
                .rpc("set_room_time_zone", params: params)
                .execute()
                .value
            if sent != nil {
                UserDefaults.standard.set(true, forKey: key)
            }
        }
    }

    /// True when the night is live by the predicate this lane's
    /// surfaces still use: started and not settled.
    ///
    /// TODO(SM-P): replace with `NightPhase == .live` — which also
    /// honours `rooms.autoCloseHours` and names the overrunning night —
    /// when lane P lands. Do not add a second phase type here.
    private static func isNightLive(_ event: Event?, now: Date = Date()) -> Bool {
        guard let event else { return false }
        return event.playedAt <= now && event.settledAt == nil
    }

    /// Ends the room's Live Activity and clears the widget snapshot
    /// when it is showing that room. Both surfaces key on the room ID
    /// now: the widget target has one snapshot slot, and keying it by
    /// name ended the wrong room's activity when two rooms shared a
    /// name (audit 01 D11, 04 D9). Best-effort.
    static func endRoomSurfaces(roomId: UUID) {
        ScoreLiveActivityDriver.endNight(roomId: roomId)
        guard ScoreSnapshotStore.load()?.roomId == roomId else { return }
        ScoreSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Params for `set_room_time_zone(p_room_id, p_tz)`.
struct SetRoomTimeZoneParams: Encodable, Sendable {
    let p_room_id: String
    let p_tz: String
}
