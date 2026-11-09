//
//  StorageKeys.swift
//  GamesRoom
//
//  Track M0.7 — centralize UserDefaults + @AppStorage keys.
//
//  Every persisted key used across the app lives here. Renaming
//  is a one-file change; grep-by-string catches every consumer.
//

import Foundation

enum StorageKeys {

    /// The room the user was last viewing, persisted across
    /// cold launches so the Rooms tab can resume into the same
    /// detail view.
    ///
    /// Stored as a `String` (UUID.uuidString) because `@AppStorage`
    /// doesn't accept `UUID?` directly. Empty string means "no
    /// resume target."
    static let lastViewedRoomId = "lastViewedRoomIdString"

    /// T1.2 — opt-in "keep scan photos" flag. Default `false`:
    /// the F-CAS-03 discard-by-default path stays identical. When
    /// on, `ChipScanSheet` writes the JPEG to the app sandbox
    /// (`Documents/ScanPhotos/`) instead of discarding it. The
    /// photo never leaves the device.
    static let keepScanPhotos = "keepScanPhotos"

    /// Lane S2: this device's calendar rows, a dictionary
    /// eventId -> EventKit identifier (`CalendarRowStore`).
    static let calendarRowIdentifiers = "calendarRowIdentifiers"

    /// V0.86 — the calendar identifier storage moved server-side
    /// (`events.event_calendar_identifier`, migration 087). iOS
    /// event UUIDs are not stable across reinstalls and the
    /// UserDefaults map was wiped on every uninstall, so the host's
    /// `calendar_auto_add_host` toggle "kept turning off every
    /// time I rebuild the app". The calendar identifier is now
    /// reported back via `report_calendar_identifier(p_event_id,
    /// p_identifier)` after each successful EKEvent.save().
    /// Lane S2 (1.2.4) moved it back on device, per member:
    /// `calendarRowIdentifiers` below. The server column held one
    /// identifier for the whole table and is no longer read.

    /// V0.84 C5 — per-event member-note prompt dismissal. The
    /// prompt is local: "one tap to dismiss, no nagging, never
    /// returns until next recap". Stored as `"1"` (not Bool) so
    /// @AppStorage reads it the same way it reads the
    /// `lastViewedRoomId` empty-string sentinel.
    static func memberNotePromptDismissed(eventId: UUID) -> String {
        "memberNotePromptDismissed-\(eventId.uuidString)"
    }

    /// Lane S2: the post-claim "Remind me the morning of" ask was
    /// tapped in this room. Per device; the room's notification
    /// setting is the durable surface.
    static func claimReminderAskAnswered(roomId: UUID) -> String {
        "claimReminderAskAnswered-\(roomId.uuidString)"
    }

    /// V0.79: the one-time "Notify me" / "Not now" prompt above the
    /// room page was answered in this room. Per device; the room's
    /// notification setting is the durable surface.
    static func notifPromptAnswered(roomId: UUID) -> String {
        "notifPromptAnswered.\(roomId.uuidString)"
    }

    /// Lane S2: this install has reported the device time zone for a
    /// room it hosts (`set_room_time_zone`). Set only on success, so
    /// a missing RPC is retried on a later room open.
    static func roomTimeZoneReported(roomId: UUID) -> String {
        "roomTimeZoneReported-\(roomId.uuidString)"
    }

    /// Every key this enum owns. A key added here without a decision in
    /// `DeviceStateKeys` (purged on sign-out) or `devicePreferences`
    /// (kept) fails `runDeviceStateTests`.
    static let persistedKeys: [String] = [
        lastViewedRoomId,
        keepScanPhotos,
        calendarRowIdentifiers
    ]

    /// Keys that describe the PHONE, not the person: they survive a
    /// sign-out because the next account uses the same hardware.
    static let devicePreferences: [String] = [keepScanPhotos]
}

/// Lane S2: this device's calendar rows, eventId -> EventKit
/// identifier, in UserDefaults. The identifier is per device, so it
/// never goes to the server.
enum CalendarRowStore {

    /// `gamesroom://event/<eventId>`, the URL every row carries.
    static func eventURL(eventId: UUID) -> URL? {
        URL(string: "gamesroom://event/\(eventId.uuidString)")
    }

    static func identifier(eventId: UUID, defaults: UserDefaults = .standard) -> String? {
        map(defaults)[eventId.uuidString]
    }

    static func set(_ identifier: String, eventId: UUID, defaults: UserDefaults = .standard) {
        var rows = map(defaults)
        rows[eventId.uuidString] = identifier
        defaults.set(rows, forKey: StorageKeys.calendarRowIdentifiers)
    }

    static func remove(eventId: UUID, defaults: UserDefaults = .standard) {
        var rows = map(defaults)
        guard rows.removeValue(forKey: eventId.uuidString) != nil else { return }
        defaults.set(rows, forKey: StorageKeys.calendarRowIdentifiers)
    }

    /// Every row this device has written: eventId string → EventKit
    /// identifier. Used by the sign-out purge to delete the rows
    /// themselves before the map is dropped (audit 04 D6).
    static func all(defaults: UserDefaults = .standard) -> [String: String] {
        map(defaults)
    }

    private static func map(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: StorageKeys.calendarRowIdentifiers) as? [String: String] ?? [:]
    }
}
