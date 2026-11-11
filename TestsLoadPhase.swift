//
//  TestsLoadPhase.swift
//  games-room
//
//  Task C — the room page's load phase as a table test.
//
//  The room page used to infer "still loading" from the shape of the
//  data it had (`hasLoadedInitialData`), which pinned the spinner
//  forever for a room with no night, no standings and no briefing.
//  The phase is now explicit, owned by the store, and read by the
//  view.
//
//  These cases pin the pure transitions the store performs. The store
//  itself (`RoomService`) imports Supabase and is not part of the
//  Foundation runner's slice, so the machine is pinned here in its
//  pure form: exactly the functions `RoomService.withRoomLoadPhase`
//  calls, in the order it calls them.
//
//  Registered from main.swift through `runLoadPhaseTests(runner)`.
//  Foundation only: runs in the macOS test binary with no simulator.
//

import Foundation

func runLoadPhaseTests(_ runner: TestRunner) {
    let room = UUID()
    let otherRoom = UUID()

    // MARK: - The three states

    runner.run("RoomLoadPhase: an unknown room is idle") {
        runner.assertEqual(RoomLoadPhase.phase(in: [:], for: room), .idle)
    }

    runner.run("RoomLoadPhase: idle → loading → loaded") {
        var table: [UUID: RoomLoadPhase] = [:]

        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .idle)

        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loading)

        table = RoomLoadPhase.finish(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)
    }

    // MARK: - The rule that fixes the forever-spinner

    runner.run("RoomLoadPhase: a loaded room stays loaded when a second refresh starts") {
        var table: [UUID: RoomLoadPhase] = [:]
        table = RoomLoadPhase.begin(in: table, for: room)
        table = RoomLoadPhase.finish(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)

        // pull-to-refresh: the phase must NOT go back to .loading, or
        // the spinner comes back over content the user is reading.
        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)

        // and the refresh's own completion keeps it loaded
        table = RoomLoadPhase.finish(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)
    }

    runner.run("RoomLoadPhase: a refresh that is already in flight stays loading") {
        var table: [UUID: RoomLoadPhase] = [:]
        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loading)

        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loading)
    }

    // MARK: - Failure still means "the first load finished"

    runner.run("RoomLoadPhase: a failed first load still lands on loaded") {
        var table: [UUID: RoomLoadPhase] = [:]
        table = RoomLoadPhase.begin(in: table, for: room)
        // the store runs `finish` in a `defer`, so a throwing load
        // reaches the same transition as a successful one
        table = RoomLoadPhase.finish(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)
    }

    // MARK: - The phase is per room

    runner.run("RoomLoadPhase: phases are per room, not global") {
        var table: [UUID: RoomLoadPhase] = [:]
        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loading)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: otherRoom), .idle)

        table = RoomLoadPhase.finish(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loaded)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: otherRoom), .idle)
    }

    runner.run("RoomLoadPhase: begin and finish leave other rooms untouched") {
        var table: [UUID: RoomLoadPhase] = [:]
        table = RoomLoadPhase.begin(in: table, for: otherRoom)
        table = RoomLoadPhase.finish(in: table, for: otherRoom)

        table = RoomLoadPhase.begin(in: table, for: room)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: otherRoom), .loaded)
        runner.assertEqual(RoomLoadPhase.phase(in: table, for: room), .loading)
    }
}
