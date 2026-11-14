//
//  TestsStoreContract.swift
//  games-room
//
//  Task F2 — pin InMemoryRoomStore's CURRENT behaviour so the drift
//  between the fake and the live RPCs is visible in one place.
//  Registered from main.swift through `runStoreContractTests(runner)`.
//
//  Every case here encodes what the fake does TODAY. Where a case
//  looks wrong, the wrongness is the finding (see REPORT-task-FH.md),
//  not a reason to weaken the assertion. This suite changes no store
//  behaviour.
//

import Foundation

/// Runs the task F2 contract cases against the shared runner.
func runStoreContractTests(_ runner: TestRunner) {
    runContractSeedTests(runner)
    runContractBriefingMirrorTests(runner)
    runContractAutoCloseTests(runner)
    runContractAwardsPassthroughTests(runner)
    runContractSingleSeasonTests(runner)
    runContractOtherDivergencesTests(runner)
}

// MARK: - Seeded fixtures

private struct ContractSeed {
    let carwoola: Room
    let dealSundays: Room
    let testSandbox: Room
    let carwoolaEvent: Event
}

/// The seed the in-memory store ships with, read back through its own
/// API so the cases do not reach into private storage.
private func contractSeed(_ store: InMemoryRoomStore) async throws -> ContractSeed {
    let rooms = try await store.fetchRooms()
    func room(_ name: String) throws -> Room {
        guard let room = rooms.first(where: { $0.name == name }) else {
            throw NSError(domain: "TestsStoreContract", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "seed room \(name) missing"])
        }
        return room
    }
    let carwoola = try room("Carwoola Crew")
    let dealSundays = try room("Deal Sundays")
    let testSandbox = try room("Test Sandbox")
    guard let carwoolaEvent = try await store.fetchActiveEvent(roomId: carwoola.id) else {
        throw NSError(domain: "TestsStoreContract", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "seed carwoola event missing"])
    }
    return ContractSeed(
        carwoola: carwoola,
        dealSundays: dealSundays,
        testSandbox: testSandbox,
        carwoolaEvent: carwoolaEvent
    )
}

private func runContractSeedTests(_ runner: TestRunner) {
    runner.runAsync("Contract seed: Carwoola carries one future night and a 6-seat briefing") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        runner.assertTrue(seed.carwoolaEvent.playedAt > Date(), "the seeded night is in the future")
        runner.assertNil(seed.carwoolaEvent.settledAt, "the seeded night is unsettled")
        let briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsTotal, 6)
        runner.assertEqual(briefing?.seatsClaimed, 1)
        runner.assertEqual(briefing?.seatsDeclined, 0)
        runner.assertEqual(briefing?.seatsUnclaimed, 5)
        let rsvp = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .claimed)
        runner.assertEqual(rsvp.memberId, seed.carwoola.createdBy) // the synthetic caller is the first room's host
    }
}

// MARK: - (a) RSVP upsert mirrors the briefing, without previous-state awareness

private func runContractBriefingMirrorTests(_ runner: TestRunner) {
    runner.runAsync("Contract (a): a first claim moves the briefing one seat") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .claimed)
        let briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsClaimed, 2)
        runner.assertEqual(briefing?.seatsUnclaimed, 4)
        runner.assertEqual(briefing?.seatsDeclined, 0)
    }

    runner.runAsync("Contract (a): repeating .claimed double-counts (the fake is NOT idempotent)") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .claimed)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .claimed)
        let briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsClaimed, 3) // two claims on the same member still adds two
        runner.assertEqual(briefing?.seatsUnclaimed, 3)
    }

    runner.runAsync("Contract (a): unclaimed after declined decrements claimed, not declined") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .declined)
        var briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsClaimed, 1)
        runner.assertEqual(briefing?.seatsDeclined, 1)
        runner.assertEqual(briefing?.seatsUnclaimed, 4)

        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .unclaimed)
        briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsClaimed, 0) // unclaimed subtracts from claimed, not declined
        runner.assertEqual(briefing?.seatsDeclined, 1) // the declined seat is left behind
        runner.assertEqual(briefing?.seatsUnclaimed, 5)
    }

    runner.runAsync("Contract (a): declining from the seeded unclaimed seat decrements unclaimed") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .declined)
        let briefing = try await store.fetchBriefing(eventId: seed.carwoolaEvent.id)
        runner.assertEqual(briefing?.seatsDeclined, 1)
        runner.assertEqual(briefing?.seatsUnclaimed, 4)
        runner.assertEqual(briefing?.seatsClaimed, 1) // the seeded claim is untouched
    }
}

// MARK: - (b) auto-close stamps stale nights with no membership gate

private func runContractAutoCloseTests(_ runner: TestRunner) {
    runner.runAsync("Contract (b): auto-close sweeps a room the synthetic caller does not belong to") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        // The synthetic caller is the Carwoola host; Deal Sundays has a
        // different creator, so the live RPC would raise 42501 here.
        runner.assertFalse(seed.dealSundays.createdBy == seed.carwoola.createdBy,
                           "the rooms have different owners")
        _ = try await store.addEvent(
            roomId: seed.dealSundays.id, name: "Stale",
            playedAt: Date().addingTimeInterval(-20 * 3_600),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        let closed = try await store.autoCloseStaleEvents(roomId: seed.dealSundays.id)
        runner.assertEqual(closed, 1) // the fake closes the night with no auth or membership check
    }

    runner.runAsync("Contract (b): auto-close is idempotent on already-settled nights") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.addEvent(
            roomId: seed.testSandbox.id, name: "Stale",
            playedAt: Date().addingTimeInterval(-20 * 3_600),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        let first = try await store.autoCloseStaleEvents(roomId: seed.testSandbox.id)
        let second = try await store.autoCloseStaleEvents(roomId: seed.testSandbox.id)
        runner.assertEqual(first, 1)
        runner.assertEqual(second, 0) // the settledAt == nil guard makes the second sweep a no-op
    }

    runner.runAsync("Contract (b): a night inside the 8-hour window is not closed") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.addEvent(
            roomId: seed.testSandbox.id, name: "Fresh",
            playedAt: Date().addingTimeInterval(-7 * 3_600),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        let closed = try await store.autoCloseStaleEvents(roomId: seed.testSandbox.id)
        runner.assertEqual(closed, 0) // the default window is 8 hours
    }

    runner.runAsync("Contract (b): the seeded future Carwoola night is untouched") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let closed = try await store.autoCloseStaleEvents(roomId: seed.carwoola.id)
        runner.assertEqual(closed, 0)
        let active = try await store.fetchActiveEvent(roomId: seed.carwoola.id)
        runner.assertEqual(active?.id, seed.carwoolaEvent.id)
        runner.assertNil(active?.settledAt, "the future night stays unsettled")
    }
}

// MARK: - (c) drowning award rows pass through unfiltered

private func runContractAwardsPassthroughTests(_ runner: TestRunner) {
    runner.runAsync("Contract (c): the fake returns another member's drowning row verbatim") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        guard let season = try await store.fetchCurrentSeason(roomId: seed.dealSundays.id) else {
            throw NSError(domain: "TestsStoreContract", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Deal Sundays season missing"])
        }
        runner.assertEqual(season.status, .ended) // the seeded Deal Sundays season is ended
        let awards = try await store.fetchSeasonAwards(seasonId: season.id)
        runner.assertEqual(awards.count, 2)
        guard let drowning = awards.first(where: { $0.awardType == .drowning }) else {
            throw NSError(domain: "TestsStoreContract", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "seed drowning award missing"])
        }
        runner.assertFalse(drowning.recipientUserId == seed.carwoola.createdBy,
                           "the drowning row is for a member other than the synthetic caller")
        runner.assertEqual(awards.filter { $0.awardType == .drowning }.count, 1) // no client-side filter removes it
    }

    runner.runAsync("Contract (c): awards for an unknown season are empty, not an error") {
        let store = InMemoryRoomStore()
        let awards = try await store.fetchSeasonAwards(seasonId: UUID())
        runner.assertTrue(awards.isEmpty)
    }
}

// MARK: - (d) one season per room, so active + ended cannot coexist

private func runContractSingleSeasonTests(_ runner: TestRunner) {
    runner.runAsync("Contract (d): fetchCurrentSeason returns whatever was last written") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let deal = try await store.fetchCurrentSeason(roomId: seed.dealSundays.id)
        runner.assertEqual(deal?.status, .ended) // an ended season is returned when it is the only one
        let carwoola = try await store.fetchCurrentSeason(roomId: seed.carwoola.id)
        runner.assertEqual(carwoola?.status, .active)
        runner.assertEqual(carwoola?.ordinal, 3)
    }

    runner.runAsync("Contract (d): closing a season replaces the single slot with the next active") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let before = try await store.fetchCurrentSeason(roomId: seed.carwoola.id)!
        let closed = try await store.closeSeason(roomId: seed.carwoola.id)
        runner.assertEqual(closed.id, before.id)
        runner.assertEqual(closed.status, .ended)

        let after = try await store.fetchCurrentSeason(roomId: seed.carwoola.id)
        runner.assertEqual(after?.status, .active)
        runner.assertEqual(after?.ordinal, before.ordinal + 1)
        runner.assertFalse(after?.id == closed.id,
                           "the closed (ended) season is no longer readable — the single slot was overwritten")
        runner.assertTrue(after?.id != nil)
    }

    runner.runAsync("Contract (d): closing a room whose only season is ended throws") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        var threw = false
        do {
            _ = try await store.closeSeason(roomId: seed.dealSundays.id)
        } catch {
            threw = true
        }
        runner.assertTrue(threw, "there is no active season to close")
    }
}

// MARK: - Other divergences (e-h)

private func runContractOtherDivergencesTests(_ runner: TestRunner) {
    runner.runAsync("Contract (e): fetchCurrentMemberRSVP is .unclaimed even after an upsert") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        _ = try await store.upsertEventRSVP(eventId: seed.carwoolaEvent.id, state: .claimed)
        // the fake has no notion of the current user
        runner.assertEqual(try await store.fetchCurrentMemberRSVP(eventId: seed.carwoolaEvent.id),
                           .unclaimed)
    }

    runner.runAsync("Contract (f): settleEvent stamps a night that has not started, with no host guard") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        runner.assertTrue(seed.carwoolaEvent.playedAt > Date())
        let stamp = try await store.settleEvent(eventId: seed.carwoolaEvent.id)
        runner.assertTrue(abs(stamp.timeIntervalSinceNow) < 5, "the mirror stamps now")
        let recent = try await store.fetchRecentSettledEvent(roomId: seed.carwoola.id)
        runner.assertEqual(recent?.id, seed.carwoolaEvent.id) // a future night is settled and served as the recap
    }

    runner.runAsync("Contract (g): closeSeason computes no awards for the closed season") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let closed = try await store.closeSeason(roomId: seed.carwoola.id)
        let awards = try await store.fetchSeasonAwards(seasonId: closed.id)
        runner.assertTrue(awards.isEmpty, "the live RPC computes four awards; the fake computes none")
    }

    runner.runAsync("Contract (h): addEvent's hidden-from list is not honoured on read") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let hiddenId = try await store.addEvent(
            roomId: seed.testSandbox.id, name: "Hidden",
            playedAt: Date().addingTimeInterval(86_400),
            packSlugs: ["casino"],
            hiddenFromUserIds: [seed.carwoola.createdBy]
        )
        let active = try await store.fetchActiveEvent(roomId: seed.testSandbox.id)
        runner.assertEqual(active?.id, hiddenId) // the fake skips the hidden_from_user_ids gate the live read RPCs apply
        runner.assertEqual(active?.hiddenFromUserIds, Optional([seed.carwoola.createdBy])) // the field is stored, just not enforced
    }

    runner.runAsync("Contract (i): season history is a static seed and ignores a just-closed season") {
        let store = InMemoryRoomStore()
        let seed = try await contractSeed(store)
        let before = try await store.fetchSeasonHistory(roomId: seed.carwoola.id)
        runner.assertEqual(before.map { $0.ordinal }, [2, 1])
        let closed = try await store.closeSeason(roomId: seed.carwoola.id)
        let after = try await store.fetchSeasonHistory(roomId: seed.carwoola.id)
        runner.assertEqual(after.map { $0.ordinal }, [2, 1]) // the closed season is not appended — history is the seed
        runner.assertFalse(after.contains(where: { $0.seasonId == closed.id }))
    }
}
