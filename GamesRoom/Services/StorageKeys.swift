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

    /// T1.1 — per-event EKEvent identifier, keyed by the room
    /// event's UUID. Lets `CalendarService` update/remove the same
    /// calendar row across edits. Absent = no calendar row yet.
    static func calendarEventIdentifier(eventId: UUID) -> String {
        "calendarEventIdentifier-\(eventId.uuidString)"
    }

    /// Global MiniMax API key for LLM-driven mascot voice. Configured in
    /// App Settings (not per-room). Empty = template fallback.
    static let mascotApiKey = "mascotApiKey"
}