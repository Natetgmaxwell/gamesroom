//
//  TestsS1.swift
//  games-room
//
//  S1 lane (night lifecycle) test group. Registered from main.swift
//  through `runS1Tests(runner)`. Every case is Foundation-only, so
//  it runs in the macOS test binary (build-and-run-tests.sh) with
//  no simulator and no network.
//

import Foundation

// MARK: - S1 lane tests (night lifecycle)

/// Runs the S1 lane's cases against the shared runner.
func runS1Tests(_ runner: TestRunner) {
    runner.run("S1.2: Event.withSettledAt carries every other field across") {
        // The settle stamp is the one field the night lifecycle
        // changes on an event row. Everything else - the pack list,
        // the calendar identifier, the hidden list - has to survive
        // the copy, or a settled night would come back with the
        // wrong packs.
        let hidden = UUID()
        let event = Event(
            id: UUID(),
            roomId: UUID(),
            name: "Friday Night",
            playedAt: Date(timeIntervalSince1970: 1_800_000_000),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            packSlugs: ["casino", "monopoly_deal"],
            packSlug: "casino",
            eventCalendarIdentifier: "EK-12345",
            hiddenFromUserIds: [hidden]
        )
        let stamp = Date(timeIntervalSince1970: 1_800_003_600)
        let settled = event.withSettledAt(stamp)
        runner.assertEqual(settled.settledAt, stamp)
        runner.assertEqual(settled.id, event.id)
        runner.assertEqual(settled.roomId, event.roomId)
        runner.assertEqual(settled.name, event.name)
        runner.assertEqual(settled.playedAt, event.playedAt)
        runner.assertEqual(settled.packSlugs, ["casino", "monopoly_deal"])
        runner.assertEqual(settled.eventCalendarIdentifier, "EK-12345")
        runner.assertEqual(settled.hiddenFromUserIds, [hidden])
    }

    runner.runAsync("S1.2: InMemoryRoomStore.settleEvent stamps the night and returns the stamp") {
        // The in-memory mirror of migration 107's settle_event: the
        // room's event gets a settledAt and the caller gets the same
        // stamp back, so the service can mirror it into its cache.
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        let eventId = try await store.addEvent(
            roomId: hosted.id,
            name: "Friday Night",
            playedAt: Date().addingTimeInterval(-3600),
            packSlugs: ["casino"],
            hiddenFromUserIds: []
        )
        let before = try await store.fetchActiveEvent(roomId: hosted.id)
        runner.assertNil(before?.settledAt, "a fresh night is not settled")

        let settledAt = try await store.settleEvent(eventId: eventId)
        let after = try await store.fetchActiveEvent(roomId: hosted.id)
        runner.assertNotNil(after?.settledAt, "settle stamps settledAt on the event")
        runner.assertEqual(after?.id, eventId)
        runner.assertTrue(
            abs((after?.settledAt?.timeIntervalSince1970 ?? 0) - settledAt.timeIntervalSince1970) < 0.001,
            "the returned stamp is the one on the row"
        )
    }

    runner.runAsync("S1.2: InMemoryRoomStore.settleEvent throws for an unknown event") {
        let store = InMemoryRoomStore()
        var threw = false
        do {
            _ = try await store.settleEvent(eventId: UUID())
        } catch {
            threw = true
        }
        runner.assertTrue(threw, "settleEvent throws for an event the room does not have")
    }
}
