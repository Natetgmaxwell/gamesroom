//
//  TestsS3.swift
//  GamesRoom
//
//  S3 — "common-sense flows" lane, step 3: release, decline, a full
//  night.
//
//  The rules under test are the ones the client can hold itself to
//  without a server: the seat escrow mirror (the in-memory store is
//  the same contract the live `release_seat` RPC implements) and the
//  seat-count arithmetic behind "All N seats are taken."
//
//  Every case here is a store-contract case: the live path is the
//  SQL in `Supabase/migrations/113_seat_flows.sql`, and the
//  in-memory store is the client-side mirror of it.
//

import Foundation

// MARK: - S3.3 — releasing a seat gives the deposit back

/// S3.3 — releasing a seat must not cost the member their deposit.
/// The claim holds it, the release returns it, and the member drops
/// off the host's arrival list (a released seat is not a no-show).
func runS3Tests(_ runner: TestRunner) {
    runner.runAsync("InMemoryRoomStore.releaseSeat returns the held deposit (S3.3)") {
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }

        try await store.claimSeatWithDeposit(eventId: event.id)
        let held = try await store.fetchMySeatDeposit(eventId: event.id)
        runner.assertEqual(held?.status, SeatDeposit.Status.held)

        try await store.releaseSeat(eventId: event.id, state: .unclaimed)

        let returned = try await store.fetchMySeatDeposit(eventId: event.id)
        runner.assertEqual(returned?.status, SeatDeposit.Status.returned)
        runner.assertEqual(
            try await store.fetchEventRSVPs(eventId: event.id)
                .first { $0.memberId == hosted.createdBy }?.state,
            MemberRSVPState.unclaimed
        )
        runner.assertTrue(
            try await store.loadArrivalCandidates(eventId: event.id).isEmpty,
            "a released seat is not an arrival candidate"
        )
    }

    runner.runAsync("InMemoryRoomStore.releaseSeat with .declined returns the deposit too (S3.3)") {
        // Declining is releasing with a different word: the member
        // is not coming, so their deposit comes straight back.
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }

        try await store.claimSeatWithDeposit(eventId: event.id)
        try await store.releaseSeat(eventId: event.id, state: .declined)

        let returned = try await store.fetchMySeatDeposit(eventId: event.id)
        runner.assertEqual(returned?.status, SeatDeposit.Status.returned)
        runner.assertEqual(
            try await store.fetchEventRSVPs(eventId: event.id)
                .first { $0.memberId == hosted.createdBy }?.state,
            MemberRSVPState.declined
        )
    }

    runner.runAsync("InMemoryRoomStore release is idempotent (S3.3)") {
        // Releasing a seat with nothing held must not throw and
        // must not change the seat again.
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }

        try await store.releaseSeat(eventId: event.id, state: .unclaimed)
        try await store.releaseSeat(eventId: event.id, state: .unclaimed)
        runner.assertEqual(
            try await store.fetchEventRSVPs(eventId: event.id)
                .first { $0.memberId == hosted.createdBy }?.state,
            MemberRSVPState.unclaimed
        )
        runner.assertNil(
            try await store.fetchMySeatDeposit(eventId: event.id),
            "no deposit row was invented"
        )
    }

    runner.runAsync("InMemoryRoomStore re-claim after a release re-takes the deposit (S3.3)") {
        // The Undo in the release toast re-claims the seat. The
        // deposit was returned, so the re-claim has to take it
        // again — otherwise the member is "in" with no deposit
        // behind them.
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }

        try await store.claimSeatWithDeposit(eventId: event.id)
        try await store.releaseSeat(eventId: event.id, state: .unclaimed)
        try await store.claimSeatWithDeposit(eventId: event.id)

        let held = try await store.fetchMySeatDeposit(eventId: event.id)
        runner.assertEqual(held?.status, SeatDeposit.Status.held)
        runner.assertEqual(held?.amount, hosted.seatDepositAmount)
        runner.assertEqual(
            try await store.fetchEventRSVPs(eventId: event.id)
                .first { $0.memberId == hosted.createdBy }?.state,
            MemberRSVPState.claimed
        )
    }

    // MARK: - S3.3 — the seat counts behind "All N seats are taken."

    runner.runAsync("InMemoryRoomStore release frees the chair in the briefing seat count (S3.3)") {
        // The full-night line is driven by the briefing's seat
        // count: a released chair has to come off the claimed
        // count or the table still reads as full.
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }
        let base = try await store.fetchBriefing(eventId: event.id)?.seatsClaimed ?? -1

        _ = try await store.upsertEventRSVP(eventId: event.id, state: .claimed)
        let claimed = try await store.fetchBriefing(eventId: event.id)?.seatsClaimed ?? -1
        runner.assertEqual(claimed, base + 1)

        try await store.releaseSeat(eventId: event.id, state: .unclaimed)
        let released = try await store.fetchBriefing(eventId: event.id)?.seatsClaimed ?? -1
        runner.assertEqual(released, base)
    }

    runner.runAsync("InMemoryRoomStore a declined chair leaves the claimed count (S3.3)") {
        let store = InMemoryRoomStore()
        let hosted = try await store.fetchRooms().first!
        guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
            runner.assertTrue(false, "seeded room has an active event")
            return
        }
        let baseClaimed = try await store.fetchBriefing(eventId: event.id)?.seatsClaimed ?? -1
        let baseDeclined = try await store.fetchBriefing(eventId: event.id)?.seatsDeclined ?? -1

        _ = try await store.upsertEventRSVP(eventId: event.id, state: .claimed)
        try await store.releaseSeat(eventId: event.id, state: .declined)

        let after = try await store.fetchBriefing(eventId: event.id)
        runner.assertEqual(after?.seatsClaimed ?? -1, baseClaimed)
        runner.assertEqual(after?.seatsDeclined ?? -1, baseDeclined + 1)
    }
}
