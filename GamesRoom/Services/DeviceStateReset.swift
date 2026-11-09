//
//  DeviceStateReset.swift
//  GamesRoom
//
//  One sweep that clears every trace of the signed-in member from
//  this device (audit 04 D6).
//
//  Called from `AuthService.signOut()` and `AuthService.deleteAccount()`
//  — the two places a member stops being the member — so a shared
//  phone, or a reinstall-and-register, can never inherit the previous
//  account's pending notifications, Live Activity, widget snapshot,
//  calendar rows, prompt flags or cached room data.
//
//  The keys themselves live in `DeviceStateKeys` (Foundation-only, unit
//  tested); this file is the edge that can reach the notification
//  center, ActivityKit, WidgetKit and EventKit.
//

import ActivityKit
import Foundation
import UserNotifications
import WidgetKit

@MainActor
enum DeviceStateReset {

    /// Clears this device of the member who is leaving:
    ///  - every pending and delivered notification (briefing bodies
    ///    carry event names);
    ///  - every Live Activity;
    ///  - the widget/watch score snapshot;
    ///  - the calendar rows this device wrote, then the row map;
    ///  - every account-scoped UserDefaults key (`DeviceStateKeys`);
    ///  - `RoomService`'s in-memory caches.
    ///
    /// Best-effort throughout: a failure to end one Live Activity must
    /// not stop the rest of the purge. Safe to call when nobody is
    /// signed in.
    static func purgeDeviceState() async {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()

        for activity in Activity<ScoreActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        ScoreSnapshotStore.clear()
        WidgetCenter.shared.reloadAllTimelines()

        // Remove the rows themselves first: dropping the map without
        // deleting the events orphans them in the user's calendar.
        for (rawEventId, _) in CalendarRowStore.all() {
            guard let eventId = UUID(uuidString: rawEventId) else { continue }
            await CalendarService.shared.removeEvent(eventId: eventId)
        }
        UserDefaults.standard.removeObject(forKey: StorageKeys.calendarRowIdentifiers)

        DeviceStateKeys.removeAll(in: .standard)

        RoomService.current?.resetInMemoryState()
    }
}
