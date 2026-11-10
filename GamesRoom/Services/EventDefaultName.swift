//
//  EventDefaultName.swift
//  GamesRoom
//
//  fx30 — the one default name a night gets, in one place.
//
//  `AddEventSheet` offers "<weekday d MMM · ha> session" ("tue 10 nov ·
//  7pm session") when the host leaves the name blank, and `EditEventSheet`
//  needs the same string twice: once for the OLD time (to tell "still the
//  default" from "the host named this night") and once for the NEW time
//  (to rename it after a move). Two copies of the format would drift, so
//  the format lives here and both screens read it.
//
//  The clock is en_US_POSIX on purpose: a device set to a 24-hour clock
//  made `ha` under `Locale.current` render "19" instead of "7pm", so the
//  night was called "tue 10 nov · 19 session". A fixed POSIX locale keeps
//  the hour 12-hour wherever the device is, and minutes only appear when
//  they are not zero ("9:30am", never "9:00am").
//
//  Foundation only: the unit runner compiles this file.
//

import Foundation

/// The default name for a night: "<weekday d MMM · ha> session",
/// lowercased so it reads like a sentence rather than a timestamp.
enum EventDefaultName {
    /// The hour, 12-hour and lower-case: "7pm", "9:30am".
    static func clock(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let minute = calendar.component(.minute, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = minute == 0 ? "ha" : "h:mma"
        return formatter.string(from: date).lowercased()
    }

    /// "tue 10 nov · 7pm" — the date part plus `clock(for:)`.
    static func stamp(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        return "\(formatter.string(from: date).lowercased()) · \(clock(for: date, timeZone: timeZone))"
    }

    /// "tue 10 nov · 7pm session" — the name an unnamed night gets.
    static func name(for date: Date, timeZone: TimeZone = .current) -> String {
        "\(stamp(for: date, timeZone: timeZone)) session"
    }
}
