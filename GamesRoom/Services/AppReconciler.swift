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
//   2. every room with a cached night re-reads that night and
//      re-plans this user's reminders for their current seat;
//   3. the realtime subscription is restarted, because iOS drops
//      the socket while the app is suspended and the INSERTs it
//      missed are exactly the nights step 2 just caught up on.
//
//  The pure decisions (which rooms were removed, which requests
//  belong to a room) live in `BriefingReconciler` so the unit
//  runner covers them.
//

import ActivityKit
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
            if let name = oldRooms.first(where: { $0.id == roomId })?.name {
                Self.endRoomSurfaces(roomName: name)
            }
        }

        // 2. Re-read each cached night and re-plan this user's
        // reminders for their current seat. A night that ended or
        // was replaced while the app slept has its old requests
        // swept first.
        let current = Set(currentRoomIds)
        for (roomId, oldEventId) in cachedEventIdByRoom where current.contains(roomId) {
            let fresh = await roomService.loadActiveEvent(roomId: roomId, force: true)
            if fresh?.id != oldEventId {
                await NotificationDispatcher.shared.cancelBriefingTrio(eventId: oldEventId)
            }
            if let fresh {
                await roomService.reconcileBriefing(eventId: fresh.id)
            }
        }

        // 3. Restart the realtime subscription.
        await RealtimeEventService.shared.stop()
        await RealtimeEventService.shared.start(roomService: roomService)
    }

    /// Ends the room's Live Activity and clears the widget snapshot
    /// when it is showing that room. Both surfaces key on the room's
    /// name (the widget target has no room id). Best-effort.
    static func endRoomSurfaces(roomName: String) {
        for activity in Activity<ScoreActivityAttributes>.activities
        where activity.attributes.roomName == roomName {
            Task {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        if ScoreSnapshotStore.load()?.roomName == roomName,
           let defaults = UserDefaults(suiteName: ScoreSnapshotStore.suiteName) {
            // Same key `ScoreSnapshotStore` writes (private there).
            defaults.removeObject(forKey: "scoreSnapshot")
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
