//
//  TestsP1.swift
//  games-room
//
//  Lane P (state machines) test group. Registered from main.swift
//  through `runP1Tests(runner)`. Foundation only, so it runs in the
//  macOS test binary (build-and-run-tests.sh) with no simulator and
//  no network.
//
//  Every case here is a table row or a pure-function assertion: the
//  machines under test take facts in and return a value, so a test
//  that needs a clock passes one rather than waiting for one.
//

import Foundation

/// Runs the lane P cases against the shared runner.
func runP1Tests(_ runner: TestRunner) {
    runP1NightPhaseTests(runner)
}

// MARK: - NightPhase table (audit 01 §3.1)

private func runP1NightPhaseTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func phase(
        played: TimeInterval?,
        settled: TimeInterval? = nil,
        autoCloseHours: Int = NightPhaseResolver.defaultAutoCloseHours
    ) -> NightPhase {
        NightPhaseResolver.phase(NightFacts(
            playedAt: played.map { now.addingTimeInterval($0) },
            settledAt: settled.map { now.addingTimeInterval($0) },
            autoCloseHours: autoCloseHours,
            now: now
        ))
    }

    // The table the Swift resolver and `public.night_phase(...)` must
    // both satisfy. Rows 3, 7, 10 and 11 are exact boundaries: the SQL
    // comparisons are strict, so "exactly at" lands on the later state.

    runner.run("P1: no night is .none") {
        runner.assertEqual(phase(played: nil), .none)
    }

    runner.run("P1: started an hour ago, inside the 8h window, is .live") {
        runner.assertEqual(phase(played: -3_600), .live)
    }

    runner.run("P1: exactly at played_at + auto_close_hours is .stranded") {
        runner.assertEqual(phase(played: -8 * 3_600), .stranded)
    }

    runner.run("P1: one second inside the window is still .live") {
        runner.assertEqual(phase(played: -(8 * 3_600) + 1), .live)
    }

    runner.run("P1: one second past the window is .stranded") {
        runner.assertEqual(phase(played: -(8 * 3_600) - 1), .stranded)
    }

    runner.run("P1: a night nine hours old was never settled and is .stranded") {
        runner.assertEqual(phase(played: -9 * 3_600), .stranded)
    }

    runner.run("P1: starting exactly now is .live, not .upcoming") {
        runner.assertEqual(phase(played: 0), .live)
    }

    runner.run("P1: starting in an hour is .upcoming") {
        runner.assertEqual(phase(played: 3_600), .upcoming)
    }

    runner.run("P1: starting in one second is .upcoming") {
        runner.assertEqual(phase(played: 1), .upcoming)
    }

    runner.run("P1: settled half an hour ago is .recap") {
        runner.assertEqual(phase(played: -3_600, settled: -1_800), .recap)
    }

    runner.run("P1: settled exactly 24 hours ago is .past, not .recap") {
        runner.assertEqual(phase(played: -30 * 3_600, settled: -86_400), .past)
    }

    runner.run("P1: settled one second inside the recap window is .recap") {
        runner.assertEqual(phase(played: -30 * 3_600, settled: -86_400 + 1), .recap)
    }

    runner.run("P1: settled one second outside the recap window is .past") {
        runner.assertEqual(phase(played: -30 * 3_600, settled: -86_400 - 1), .past)
    }

    runner.run("P1: a month-old settled night is .past") {
        runner.assertEqual(phase(played: -30 * 86_400, settled: -30 * 86_400 + 3_600), .past)
    }

    runner.run("P1: settling wins over the auto-close window") {
        // A night that ran long then settled inside the window is a
        // recap, not a stranded night: the settle is the later fact.
        runner.assertEqual(phase(played: -10 * 3_600, settled: -9 * 3_600), .recap)
    }

    runner.run("P1: a settled night in the future is still .recap") {
        // Defensive: a bad row can carry played_at > now and a settle
        // stamp. The settled branches run first, exactly like the SQL.
        runner.assertEqual(phase(played: 3_600, settled: -60), .recap)
    }

    runner.run("P1: the room's autoCloseHours moves the live/stranded line") {
        runner.assertEqual(phase(played: -5_400, autoCloseHours: 2), .live)
        runner.assertEqual(phase(played: -5_400, autoCloseHours: 1), .stranded)
    }

    runner.run("P1: autoCloseHours 0 makes a just-started night .stranded") {
        runner.assertEqual(phase(played: -1, autoCloseHours: 0), .stranded)
    }

    runner.run("P1: autoCloseHours does not affect an upcoming night") {
        runner.assertEqual(phase(played: 3_600, autoCloseHours: 0), .upcoming)
    }

    runner.run("P1: the vocabulary is the seven SQL values") {
        runner.assertEqual(NightPhase.allCases.map(\.rawValue),
                           ["none", "upcoming", "live", "stranded", "recap", "past", "cancelled"])
        for value in NightPhase.allCases {
            runner.assertEqual(NightPhase(rawValue: value.rawValue), value)
        }
    }

    runner.run("P1: the resolver never returns .cancelled") {
        // `cancel_event` deletes the row, so a cancelled night is
        // absent rather than classifiable. The case exists for rows
        // that carry the marker; the rule must not manufacture it.
        let inputs: [(TimeInterval?, TimeInterval?)] = [
            (nil, nil), (-1, nil), (1, nil), (-1, -1), (-200_000, -200_000)
        ]
        for (played, settled) in inputs {
            runner.assertTrue(phase(played: played, settled: settled) != .cancelled)
        }
    }

    runner.run("P1: phase(for:) reads an Event and is nil-safe") {
        runner.assertEqual(NightPhaseResolver.phase(for: nil, now: now), .none)
        let event = Event(
            id: UUID(), roomId: UUID(), name: "Friday",
            playedAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-86_400)
        )
        runner.assertEqual(NightPhaseResolver.phase(for: event, now: now), .live)
        runner.assertEqual(NightPhaseResolver.phase(for: event.withSettledAt(now), now: now), .recap)
    }
}
