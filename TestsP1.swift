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
    runP1StoreNightTests(runner)
    runP1V0StateTests(runner)
    runP1NightPlanPhaseTests(runner)
    runP1SeatModelTests(runner)
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

// MARK: - The fake holds nights, and ranks them like the server (D13)

private func runP1StoreNightTests(_ runner: TestRunner) {
    /// A seeded room with no nights left, so a case can build exactly
    /// the list it needs.
    func emptyRoom(_ store: InMemoryRoomStore) async throws -> UUID {
        let room = try await store.fetchRooms().first!
        if let seeded = try await store.fetchActiveEvent(roomId: room.id) {
            try await store.cancelEvent(eventId: seeded.id)
        }
        return room.id
    }

    func addNight(
        _ store: InMemoryRoomStore,
        roomId: UUID,
        name: String,
        playedAt: TimeInterval,
        settledAt: TimeInterval? = nil
    ) async throws -> UUID {
        let id = try await store.addEvent(
            roomId: roomId, name: name,
            playedAt: Date().addingTimeInterval(playedAt),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        if let settledAt {
            _ = try await store.settleEvent(eventId: id)
            // The mirror stamps "now"; tests that need an older settle
            // read the row they built instead of waiting for a clock.
            _ = settledAt
        }
        return id
    }

    runner.runAsync("P1: a room with a future night and a settled night keeps both") {
        // Audit 01 D1 — the recap used to exist only on the phone that
        // tapped Settle. The active slot is next week's night; the
        // recap is its own read.
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        let settledId = try await addNight(store, roomId: roomId, name: "Last night", playedAt: -10_800, settledAt: 0)
        let nextId = try await addNight(store, roomId: roomId, name: "Next week", playedAt: 7 * 86_400)

        let active = try await store.fetchActiveEvent(roomId: roomId)
        let recent = try await store.fetchRecentSettledEvent(roomId: roomId)
        runner.assertTrue(active?.id == nextId, "the future night is the active slot")
        runner.assertTrue(recent?.id == settledId, "the settled night is still the recap")
    }

    runner.runAsync("P1: a stranded night outranks the next scheduled night") {
        // Audit 01 D3 — a night nobody settled used to be invisible: the
        // future night took the slot and the settle action did not
        // exist. The stranded night has to win the slot to be fixable.
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        let strandedId = try await addNight(store, roomId: roomId, name: "Forgotten", playedAt: -30 * 3_600)
        _ = try await addNight(store, roomId: roomId, name: "Next week", playedAt: 7 * 86_400)
        let active = try await store.fetchActiveEvent(roomId: roomId)
        runner.assertEqual(active?.id, strandedId)
    }

    runner.runAsync("P1: a live night outranks both the stranded night and the future one") {
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        _ = try await addNight(store, roomId: roomId, name: "Forgotten", playedAt: -30 * 3_600)
        let liveId = try await addNight(store, roomId: roomId, name: "Tonight", playedAt: -3_600)
        _ = try await addNight(store, roomId: roomId, name: "Next week", playedAt: 7 * 86_400)
        let active = try await store.fetchActiveEvent(roomId: roomId)
        runner.assertEqual(active?.id, liveId)
    }

    runner.runAsync("P1: the soonest future night wins when two are booked") {
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        _ = try await addNight(store, roomId: roomId, name: "In a fortnight", playedAt: 14 * 86_400)
        let sooner = try await addNight(store, roomId: roomId, name: "In a week", playedAt: 7 * 86_400)
        let active = try await store.fetchActiveEvent(roomId: roomId)
        runner.assertEqual(active?.id, sooner)
    }

    runner.runAsync("P1: a room with no nights has no active slot and no recap") {
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        runner.assertNil(try await store.fetchActiveEvent(roomId: roomId))
        runner.assertNil(try await store.fetchRecentSettledEvent(roomId: roomId))
    }

    runner.runAsync("P1: a night settled outside the 24h window is not a recap") {
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        let id = try await store.addEvent(
            roomId: roomId, name: "Old night",
            playedAt: Date().addingTimeInterval(-30 * 86_400),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        // The mirror's settle stamps "now"; this case is about a night
        // that settled a month ago, so write that stamp instead.
        await store.backdateSettledAt(eventId: id, settledAt: Date().addingTimeInterval(-30 * 86_400))
        runner.assertNil(
            try await store.fetchRecentSettledEvent(roomId: roomId),
            "a settled night stops being a recap after 24h"
        )
        runner.assertNil(
            try await store.fetchActiveEvent(roomId: roomId),
            "and it is not the active slot either"
        )
    }

    runner.runAsync("P1: auto-close closes only the night past the window") {
        let store = InMemoryRoomStore()
        let roomId = try await emptyRoom(store)
        let staleId = try await addNight(store, roomId: roomId, name: "Stale", playedAt: -3 * 86_400)
        let freshId = try await addNight(store, roomId: roomId, name: "Fresh", playedAt: -2 * 3_600)
        let closed = try await store.autoCloseStaleEvents(roomId: roomId)
        runner.assertEqual(closed, 1)
        let recent = try await store.fetchRecentSettledEvent(roomId: roomId)
        runner.assertEqual(recent?.id, staleId)
        let active = try await store.fetchActiveEvent(roomId: roomId)
        runner.assertTrue(active?.id == freshId, "the live night keeps the slot")
    }
}


// MARK: - V0State (audit 03 C4: D2, D3, D4)

private func runP1V0StateTests(_ runner: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let roomId = UUID()

    func event(playedAt: TimeInterval, settledAt: TimeInterval? = nil) -> Event {
        Event(
            id: UUID(), roomId: roomId, name: "Friday",
            playedAt: now.addingTimeInterval(playedAt),
            createdAt: now.addingTimeInterval(-7 * 86_400)
        ).withSettledAt(settledAt.map { now.addingTimeInterval($0) })
    }

    func state(
        _ event: Event?,
        phase: NightPhase? = nil,
        rsvp: MemberRSVPState = .unclaimed,
        hasWithdrawn: Bool = false,
        hasLoaded: Bool = true,
        autoCloseHours: Int = 8
    ) -> V0State {
        let resolved = phase ?? NightPhaseResolver.phase(
            for: event, autoCloseHours: autoCloseHours, now: now
        )
        return V0State.resolve(
            hasLoaded: hasLoaded, phase: resolved, activeEvent: event,
            myRSVP: rsvp, hasWithdrawn: hasWithdrawn
        )
    }

    runner.run("P1: nothing loaded is .loading") {
        runner.assertEqual(state(nil, hasLoaded: false), .loading)
    }

    runner.run("P1: a loaded room with no night reads the standings") {
        runner.assertEqual(state(nil), .readStandings)
    }

    runner.run("P1: an upcoming unclaimed night is .upcoming") {
        let e = event(playedAt: 3_600)
        runner.assertEqual(state(e), .upcoming(e))
    }

    runner.run("P1: an upcoming claimed night is .claimed") {
        let e = event(playedAt: 3_600)
        runner.assertEqual(state(e, rsvp: .claimed), .claimed(e))
    }

    runner.run("P1: an upcoming declined night is .declined") {
        let e = event(playedAt: 3_600)
        runner.assertEqual(state(e, rsvp: .declined), .declined(e))
    }

    runner.run("P1: a live night before the viewer plays is .tonightEvent") {
        let e = event(playedAt: -3_600)
        runner.assertEqual(state(e), .tonightEvent(e))
    }

    runner.run("P1: a live night after the viewer plays is .inPlay") {
        let e = event(playedAt: -3_600)
        runner.assertEqual(state(e, hasWithdrawn: true), .inPlay(e))
    }

    runner.run("P1: a night settled 25 hours ago is .readStandings, never live") {
        // Audit 03 D2 — this used to fall through to the live card:
        // "The night has started" on a finished night.
        let e = event(playedAt: -30 * 3_600, settledAt: -25 * 3_600)
        runner.assertEqual(state(e), .readStandings)
    }

    runner.run("P1: a night settled an hour ago is .justSettled") {
        let e = event(playedAt: -10_800, settledAt: -3_600)
        runner.assertEqual(state(e), .justSettled(e))
    }

    runner.run("P1: a stranded night is .inPlay") {
        // Audit 01 D3 — the settle action has to exist somewhere.
        let e = event(playedAt: -30 * 3_600)
        runner.assertEqual(state(e), .inPlay(e))
    }

    runner.run("P1: a stranded night stays .inPlay even before the viewer plays") {
        // Stranded is not the play-just-started moment: the table is
        // long gone, the card is waiting on the host.
        let e = event(playedAt: -30 * 3_600)
        runner.assertEqual(state(e, hasWithdrawn: false), .inPlay(e))
    }

    runner.run("P1: a cancelled night reads the standings") {
        let e = event(playedAt: 3_600)
        runner.assertEqual(state(e, phase: .cancelled), .readStandings)
    }

    runner.run("P1: played-then-settled chips keeps the page in .inPlay") {
        // Audit 03 D3 — `myWorkingHand` returns to 0 when the chips are
        // settled, which used to flip the header back to "The night has
        // started". `hasWithdrawn` is sticky for the night.
        let e = event(playedAt: -3_600)
        runner.assertEqual(state(e, hasWithdrawn: true), .inPlay(e))
    }
}


// MARK: - NightPlan reads the phase (audit 01 §3.3 commit 5)

private func runP1NightPlanPhaseTests(_ runner: TestRunner) {
    func input(
        isHost: Bool,
        phase: NightPhase,
        packSlugs: [String] = ["monopoly_deal"],
        arrived: Int = 2,
        claimed: Int = 4,
        rounds: Int = 0
    ) -> NightInput {
        NightInput(
            isHost: isHost, packSlugs: packSlugs, phase: phase,
            arrivedCount: arrived, claimedCount: claimed, roundsScored: rounds,
            iHaveHeldDeposit: false, iHaveWithdrawn: true
        )
    }

    runner.run("P1: a stranded night asks the host to settle it") {
        let plan = NightPlan.plan(for: input(isHost: true, phase: .stranded))
        runner.assertEqual(plan.primary, .settleNight)
        runner.assertEqual(plan.caption, "The night is still open")
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("P1: a stranded night gives a member nothing to do") {
        let plan = NightPlan.plan(for: input(isHost: false, phase: .stranded))
        runner.assertNil(plan.primary)
        runner.assertEqual(plan.secondaries, [])
        runner.assertNil(plan.caption, "the caption is the host's explanation")
    }

    runner.run("P1: a stranded night asks for the settle even with no round scored") {
        // The window is gone, so the usual "score first" advice is moot:
        // the only way out is to close the night.
        let plan = NightPlan.plan(for: input(isHost: true, phase: .stranded, rounds: 0))
        runner.assertEqual(plan.primary, .settleNight)
    }

    runner.run("P1: a live night carries no caption") {
        let plan = NightPlan.plan(for: input(isHost: true, phase: .live))
        runner.assertNil(plan.caption)
    }

    runner.run("P1: a recap night offers the host the next night and no caption") {
        let plan = NightPlan.plan(for: input(isHost: true, phase: .recap))
        runner.assertEqual(plan.primary, .planNextNight)
        runner.assertNil(plan.caption)
    }

    runner.run("P1: a past night offers nothing to anyone") {
        runner.assertNil(NightPlan.plan(for: input(isHost: true, phase: .past)).primary)
        runner.assertNil(NightPlan.plan(for: input(isHost: false, phase: .past)).primary)
    }

    runner.run("P1: an upcoming night offers nothing - the RSVP CTA is the briefing slot") {
        let plan = NightPlan.plan(for: input(isHost: false, phase: .upcoming))
        runner.assertNil(plan.primary)
    }

    runner.run("P1: the recap sits above the next night and not above itself") {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let settled = Event(
            id: UUID(), roomId: UUID(), name: "Last night",
            playedAt: now.addingTimeInterval(-10_800), createdAt: now.addingTimeInterval(-86_400)
        ).withSettledAt(now.addingTimeInterval(-3_600))
        var next = Event(
            id: UUID(), roomId: UUID(), name: "Next week",
            playedAt: now.addingTimeInterval(7 * 86_400), createdAt: now
        )
        runner.assertTrue(
            NightPlan.recapAboveNextNight(recent: settled, active: next, now: now)?.id == settled.id,
            "recap above the next night"
        )
        runner.assertNil(NightPlan.recapAboveNextNight(recent: settled, active: settled, now: now))
        next = settled.withSettledAt(nil)
        runner.assertNil(NightPlan.recapAboveNextNight(recent: settled, active: next, now: now),
                         "an older settled night is not the slot's night")
    }
}


// MARK: - DepositMode / SeatPhase / SeatAvailability (audit 02 C1, C2; 03 C3)

private func runP1SeatModelTests(_ runner: TestRunner) {
    func room(trigger: SeatDepositTrigger, amount: Int) -> Room {
        Room(
            id: UUID(), name: "Room", mascotName: "Felty",
            mascotPersonality: .friendly, mascotPoliticalIdeology: .centrist,
            createdBy: UUID(), createdAt: Date(), updatedAt: Date(),
            isLive: false,
            joinStartingBonus: 200, userRole: .member,
            seatDepositAmount: amount, seatDepositTrigger: trigger
        )
    }

    func deposit(_ status: SeatDeposit.Status) -> SeatDeposit {
        SeatDeposit(id: UUID(), amount: 50, status: status, heldAt: Date())
    }

    runner.run("P1: DepositMode is escrow only when the trigger is escrow and the amount is above zero") {
        runner.assertEqual(room(trigger: .escrow, amount: 200).depositMode, .escrow(amount: 200))
        runner.assertEqual(room(trigger: .escrow, amount: 0).depositMode, .off)
        runner.assertEqual(room(trigger: .off, amount: 200).depositMode, .off)
        runner.assertEqual(room(trigger: .off, amount: 0).depositMode, .off)
        runner.assertNil(room(trigger: .off, amount: 200).depositMode.amount)
        runner.assertEqual(room(trigger: .escrow, amount: 50).depositMode.amount, 50)
    }

    runner.run("P1: SeatPhase has exactly one answer for every rsvp x deposit x mode") {
        let statuses: [SeatDeposit.Status?] = [nil, .held, .returned, .forfeited, .waived]
        let modes: [DepositMode] = [.off, .escrow(amount: 50)]
        for rsvp in [MemberRSVPState.unclaimed, .claimed, .declined] {
            for status in statuses {
                for mode in modes {
                    let phase = SeatPhase.phase(
                        rsvp: rsvp,
                        deposit: status.map(deposit),
                        mode: mode
                    )
                    // Every combination lands somewhere; the switch has
                    // no nil and no fall-through.
                    switch phase {
                    case .open, .declined, .claimedNoDeposit, .held, .arrived, .noShow, .missingDeposit:
                        break
                    }
                }
            }
        }
        runner.assertTrue(true, "every combination resolves")
    }

    runner.run("P1: an unclaimed seat is open whatever deposit row is lying around") {
        runner.assertEqual(SeatPhase.phase(rsvp: .unclaimed, deposit: deposit(.returned), mode: .escrow(amount: 50)), .open)
        runner.assertEqual(SeatPhase.phase(rsvp: .unclaimed, deposit: nil, mode: .escrow(amount: 50)), .open)
    }

    runner.run("P1: a declined seat is declined whatever deposit row is lying around") {
        runner.assertEqual(SeatPhase.phase(rsvp: .declined, deposit: deposit(.held), mode: .escrow(amount: 50)), .declined)
    }

    runner.run("P1: claimed with deposits off is claimedNoDeposit") {
        runner.assertEqual(
            SeatPhase.phase(rsvp: .claimed, deposit: nil, mode: .off),
            .claimedNoDeposit
        )
    }

    runner.run("P1: claimed with deposits on and no deposit row is the named impossible state") {
        runner.assertEqual(
            SeatPhase.phase(rsvp: .claimed, deposit: nil, mode: .escrow(amount: 50)),
            .missingDeposit
        )
    }

    runner.run("P1: the deposit status picks held, arrived or no-show") {
        let mode = DepositMode.escrow(amount: 50)
        let held = deposit(.held)
        runner.assertEqual(SeatPhase.phase(rsvp: .claimed, deposit: held, mode: mode), .held(deposit: held))
        let returned = deposit(.returned)
        runner.assertEqual(SeatPhase.phase(rsvp: .claimed, deposit: returned, mode: mode), .arrived(deposit: returned))
        let forfeited = deposit(.forfeited)
        runner.assertEqual(SeatPhase.phase(rsvp: .claimed, deposit: forfeited, mode: mode), .noShow(deposit: forfeited))
        let waived = deposit(.waived)
        runner.assertEqual(SeatPhase.phase(rsvp: .claimed, deposit: waived, mode: mode), .noShow(deposit: waived))
    }

    runner.run("P1: SeatAvailability is full only when every chair is taken and the viewer holds none") {
        runner.assertEqual(SeatAvailability.compute(rsvp: .unclaimed, seatsClaimed: 6, maxSeats: 6), .full)
        runner.assertEqual(SeatAvailability.compute(rsvp: .unclaimed, seatsClaimed: 5, maxSeats: 6), .open)
        runner.assertEqual(SeatAvailability.compute(rsvp: .unclaimed, seatsClaimed: 7, maxSeats: 6), .full)
        runner.assertEqual(SeatAvailability.compute(rsvp: .claimed, seatsClaimed: 6, maxSeats: 6), .youHoldOne)
        runner.assertEqual(SeatAvailability.compute(rsvp: .declined, seatsClaimed: 6, maxSeats: 6), .full)
    }

    runner.run("P1: a full night whose counts drop back to 7 of 8 is open again (the latch is gone)") {
        // Audit 03 D1 — the old latch said "All 8 seats are taken."
        // until the same member claimed, so a release by anyone else
        // never brought the button back.
        runner.assertEqual(SeatAvailability.compute(rsvp: .unclaimed, seatsClaimed: 8, maxSeats: 8), .full)
        runner.assertEqual(SeatAvailability.compute(rsvp: .unclaimed, seatsClaimed: 7, maxSeats: 8), .open)
    }
}
