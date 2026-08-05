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
}