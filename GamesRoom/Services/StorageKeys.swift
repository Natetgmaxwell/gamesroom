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

    /// V0.84 C5 — per-event member-note prompt dismissal. The
    /// prompt is local: "one tap to dismiss, no nagging, never
    /// returns until next recap". Stored as `"1"` (not Bool) so
    /// @AppStorage reads it the same way it reads the
    /// `lastViewedRoomId` empty-string sentinel.
    static func memberNotePromptDismissed(eventId: UUID) -> String {
        "memberNotePromptDismissed-\(eventId.uuidString)"
    }
}
