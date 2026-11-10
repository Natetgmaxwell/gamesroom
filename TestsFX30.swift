//
//  TestsFX30.swift
//  games-room
//
//  fx30 — the default night name: "tue 10 nov · 7pm session",
//  independent of the device's 24-hour clock setting.
//  Registered from main.swift through `runFX30Tests(runner)`.
//  Foundation only: runs in the macOS test binary with no simulator.
//
//  The score-picker half of fx30 is pinned in TestsS1 (S1.3).

import Foundation

/// Runs the fx30 cases against the shared runner.
func runFX30Tests(_ runner: TestRunner) {
    runner.run("FX30: the default night name says 7pm, not 19") {
        // A 24-hour device setting made `ha` under Locale.current render
        // "19". The formatter is pinned to en_US_POSIX.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let seven = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 19, minute: 0))!
        runner.assertEqual(EventDefaultName.clock(for: seven, timeZone: calendar.timeZone), "7pm")
        runner.assertEqual(
            EventDefaultName.name(for: seven, timeZone: calendar.timeZone),
            "tue 10 nov · 7pm session"
        )
    }

    runner.run("FX30: the default night name keeps minutes only when they are not zero") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        let halfPastNine = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9, minute: 30))!
        runner.assertEqual(EventDefaultName.clock(for: halfPastNine, timeZone: calendar.timeZone), "9:30am")
        runner.assertEqual(
            EventDefaultName.stamp(for: halfPastNine, timeZone: calendar.timeZone),
            "tue 10 nov · 9:30am"
        )
    }
}
