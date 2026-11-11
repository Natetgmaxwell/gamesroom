//
//  LoadPhase.swift
//  GamesRoom
//
//  Task C — a room's first-load phase, as a named machine.
//
//  The room page used to infer "still loading" from the shape of the
//  data it already had: a room with no night, no standings and no
//  briefing looked exactly like a room whose fetch was still in
//  flight, so the page pinned itself to the spinner forever (the
//  V0.100 forever-spinner bug). The phase replaces that inference.
//  The store owns it; the view reads it.
//
//  The rules, in one place:
//
//    * `.idle`    — the room has never been loaded.
//    * `.loading` — a first load is in flight.
//    * `.loaded`  — the first load finished, successfully or not.
//
//  A refresh of an already-loaded room stays `.loaded`: pull-to-
//  refresh must never put a spinner back over content the user is
//  already looking at.
//
//  This file is pure (Foundation only, no service dependencies) so the
//  Foundation test runner can pin the transitions without a store, a
//  network or a view.
//

import Foundation

/// The load phase of one room's first load.
enum RoomLoadPhase: Equatable {

    /// The room has never been loaded.
    case idle

    /// A first load is in flight.
    case loading

    /// The first load finished — successfully or not. The phase claims
    /// "the first load finished", never "the data is good"; a failed
    /// load still lands here so the page can show its error path
    /// instead of a spinner that never stops.
    case loaded

    /// The phase of `roomId` in `table`. A room the table has never
    /// seen is `.idle`.
    static func phase(in table: [UUID: RoomLoadPhase], for roomId: UUID) -> RoomLoadPhase {
        table[roomId] ?? .idle
    }

    /// The table after a load starts for `roomId`.
    ///
    /// `.idle` becomes `.loading`, `.loading` stays `.loading`, and
    /// `.loaded` STAYS `.loaded` — a refresh of a loaded room must not
    /// put the spinner back.
    static func begin(in table: [UUID: RoomLoadPhase], for roomId: UUID) -> [UUID: RoomLoadPhase] {
        guard phase(in: table, for: roomId) != .loaded else { return table }
        var next = table
        next[roomId] = .loading
        return next
    }

    /// The table after a load finishes for `roomId` — success or
    /// failure, the same transition either way.
    static func finish(in table: [UUID: RoomLoadPhase], for roomId: UUID) -> [UUID: RoomLoadPhase] {
        var next = table
        next[roomId] = .loaded
        return next
    }
}
