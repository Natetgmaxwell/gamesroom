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
        // The fake holds every night a room has, so clear the seeded
        // future night: this case settles the night it adds, and the
        // active slot ranks a live night above a future one anyway.
        if let seeded = try await store.fetchActiveEvent(roomId: hosted.id) {
            try await store.cancelEvent(eventId: seeded.id)
        }
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

    // MARK: - S1.3 NightPlan (every night is scored in chips)

    runner.run("S1.3: a member holding a deposit checks in before taking chips") {
        let plan = NightPlan.plan(for: nightInput(iHaveHeldDeposit: true))
        runner.assertEqual(plan.primary, NightAction.checkIn)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a member with no chips takes chips, on any night") {
        let plan = NightPlan.plan(for: nightInput())
        runner.assertEqual(plan.primary, NightAction.takeChips)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: chips on the table means cash out, with the top-up under it") {
        let plan = NightPlan.plan(for: nightInput(myChips: .playing))
        runner.assertEqual(plan.primary, NightAction.cashOut)
        runner.assertEqual(plan.secondaries, [NightAction.takeChips])
    }

    runner.run("S1.3: a held deposit never jumps ahead of chips already on the table") {
        let plan = NightPlan.plan(for: nightInput(iHaveHeldDeposit: true, myChips: .playing))
        runner.assertEqual(plan.primary, NightAction.cashOut)
    }

    runner.run("S1.3: a member who cashed out has nothing to tap and is told what happens next") {
        let plan = NightPlan.plan(for: nightInput(myChips: .cashedOut, othersPlaying: ["Sam"]))
        runner.assertNil(plan.primary)
        runner.assertEqual(plan.secondaries, [])
        runner.assertEqual(plan.caption, NightPlan.cashedOutCaption)
    }

    runner.run("S1.3: the host plays too - no chips means take chips") {
        let plan = NightPlan.plan(for: nightInput(isHost: true))
        runner.assertEqual(plan.primary, NightAction.takeChips)
    }

    runner.run("S1.3: the host cashes out their own chips before anything else") {
        let plan = NightPlan.plan(for: nightInput(isHost: true, myChips: .playing, othersPlaying: ["Sam"]))
        runner.assertEqual(plan.primary, NightAction.cashOut)
        runner.assertEqual(plan.secondaries, [NightAction.takeChips])
    }

    runner.run("S1.3: settle is never the primary while anyone is still playing") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true, myChips: .cashedOut, othersPlaying: ["Sam", "Jo"], othersCashedOut: true
        ))
        runner.assertEqual(plan.primary, NightAction.waitingForCashOut(names: ["Sam", "Jo"]))
        runner.assertEqual(plan.secondaries, [NightAction.settleNight])
        runner.assertEqual(NightPlan.waitingCaption(names: ["Sam", "Jo"]), "Waiting on Sam and Jo to cash out")
    }

    runner.run("S1.3: everyone cashed out means the host settles") {
        let plan = NightPlan.plan(for: nightInput(isHost: true, myChips: .cashedOut, othersCashedOut: true))
        runner.assertEqual(plan.primary, NightAction.settleNight)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a host who only hosted settles once the table has cashed out") {
        let done = NightPlan.plan(for: nightInput(isHost: true, othersCashedOut: true))
        runner.assertEqual(done.primary, NightAction.settleNight)
        let waiting = NightPlan.plan(for: nightInput(isHost: true, othersPlaying: ["Sam"], othersCashedOut: true))
        runner.assertEqual(waiting.primary, NightAction.waitingForCashOut(names: ["Sam"]))
    }

    runner.run("S1.3: settling early names who has not cashed out") {
        runner.assertEqual(NightPlan.settleEarlyWarning(names: ["Sam"]), "Sam hasn't cashed out. Settle the night anyway?")
        runner.assertEqual(NightPlan.settleEarlyWarning(names: ["Sam", "Jo"]), "Sam and Jo haven't cashed out. Settle the night anyway?")
    }

    runner.run("S1.3: the host plans the next night once the night is settled") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            settledAt: nightBase.addingTimeInterval(-3_600)
        ))
        runner.assertEqual(plan.primary, NightAction.planNextNight)
    }

    runner.run("S1.3: a settled night gives members nothing to do") {
        let plan = NightPlan.plan(for: nightInput(
            settledAt: nightBase.addingTimeInterval(-3_600)
        ))
        runner.assertNil(plan.primary)
    }

    runner.run("S1.3: a night settled over 24 hours ago is history") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            settledAt: nightBase.addingTimeInterval(-90_000)
        ))
        runner.assertNil(plan.primary)
    }

    runner.run("S1.3: a night that has not started has no plan") {
        let plan = NightPlan.plan(for: nightInput(
            playedAt: nightBase.addingTimeInterval(3_600)
        ))
        runner.assertNil(plan.primary, "the night has not started")
        runner.assertEqual(plan.secondaries, [])
    }
    runS1SectionTests(runner)
    runS1SeedTests(runner)
}

// MARK: - S1.7 season awards + recap sections

func runS1SectionTests(_ runner: TestRunner) {
    let roomId = UUID()
    func season(_ ordinal: Int, endedDaysAgo: Double?) -> Season {
        Season(
            id: UUID(), roomId: roomId, ordinal: ordinal, subtitle: "S\(ordinal)",
            status: endedDaysAgo == nil ? .active : .ended,
            startedAt: nightBase.addingTimeInterval(-90 * 86_400),
            endedAt: endedDaysAgo.map { nightBase.addingTimeInterval(-$0 * 86_400) }
        )
    }
    func event(settledHoursAgo: Double?, startsInHours: Double = -3) -> Event {
        let e = Event(
            id: UUID(), roomId: roomId, name: "Night",
            playedAt: nightBase.addingTimeInterval(startsInHours * 3_600),
            createdAt: nightBase.addingTimeInterval(-30 * 86_400),
            packSlugs: ["casino"], packSlug: "casino"
        )
        return settledHoursAgo.map { e.withSettledAt(nightBase.addingTimeInterval(-$0 * 3_600)) } ?? e
    }

    runner.run("S1.7: the season that just ended shows to every member") {
        let latest = season(3, endedDaysAgo: 2)
        let shown = SeasonAwardsWindow.seasonToShow(
            [season(2, endedDaysAgo: 40), latest, season(4, endedDaysAgo: nil)],
            now: nightBase, isDismissed: { _ in false }
        )
        runner.assertEqual(shown?.id, latest.id)
    }

    runner.run("S1.7: the awards stop after 7 days") {
        let shown = SeasonAwardsWindow.seasonToShow(
            [season(3, endedDaysAgo: 8)], now: nightBase, isDismissed: { _ in false }
        )
        runner.assertNil(shown)
    }

    runner.run("S1.7: Done hides the awards and never brings back an older season") {
        let latest = season(3, endedDaysAgo: 1)
        let older = season(2, endedDaysAgo: 3)
        let shown = SeasonAwardsWindow.seasonToShow(
            [older, latest], now: nightBase, isDismissed: { $0 == latest.id }
        )
        runner.assertNil(shown)
        runner.assertEqual(
            SeasonAwardsWindow.dismissedKey(seasonId: latest.id),
            "seasonAwardsDismissed-\(latest.id.uuidString)"
        )
    }

    runner.run("S1.7: the recap sits above the next night for 24h") {
        let settled = event(settledHoursAgo: 2)
        let next = event(settledHoursAgo: nil, startsInHours: 7 * 24)
        runner.assertEqual(NightPlan.recapAboveNextNight(recent: settled, active: next, now: nightBase)?.id, settled.id)
        let stale = event(settledHoursAgo: 25)
        runner.assertNil(NightPlan.recapAboveNextNight(recent: stale, active: next, now: nightBase))
    }

    runner.run("S1.7: no recap section when the settled night is the page's own slot") {
        let settled = event(settledHoursAgo: 2)
        runner.assertNil(NightPlan.recapAboveNextNight(recent: settled, active: settled, now: nightBase))
        runner.assertNil(NightPlan.recapAboveNextNight(recent: settled, active: nil, now: nightBase))
    }
}

// MARK: - S1.8 sweep seeds

func runS1SeedTests(_ runner: TestRunner) {
    func seeded(_ key: String) async throws -> (InMemoryRoomStore, Room, Event?) {
        let store = InMemoryRoomStore()
        let room = try await store.fetchRooms().first!
        let base = try await store.fetchActiveEvent(roomId: room.id) ?? Event(
            id: UUID(), roomId: room.id, name: "Night",
            playedAt: Date().addingTimeInterval(86_400), createdAt: Date(),
            packSlugs: ["casino"], packSlug: "casino"
        )
        await store.applyAuditSweepSeeds(key: key, carwoola: room, carwoolaEvent: base)
        return (store, room, try await store.fetchActiveEvent(roomId: room.id))
    }

    runner.runAsync("S1.8: night-arrivals seeds a live night with 2 of 5 arrived") {
        let (store, _, event) = try await seeded("night-arrivals")
        guard let event else { runner.assertNotNil(event, "seeded night"); return }
        runner.assertTrue(event.playedAt <= Date() && event.settledAt == nil, "the night is live")
        runner.assertEqual(event.packSlugs, ["monopoly_deal"])
        let claimed = try await store.fetchEventRSVPs(eventId: event.id).filter { $0.state == .claimed }
        let waiting = try await store.loadArrivalCandidates(eventId: event.id)
        runner.assertEqual(claimed.count, 5)
        runner.assertEqual(claimed.count - waiting.count, 2)
    }

    runner.runAsync("S1.8: night-chips seeds a table half cashed out, so the host waits on Sam") {
        let (_, room, event) = try await seeded("night-chips")
        guard let event else { runner.assertNotNil(event, "seeded night"); return }
        let hands = SweepChipSeeds.shared.hands(eventId: event.id) ?? []
        let txs = SweepChipSeeds.shared.transactions(eventId: event.id) ?? []
        let score = TonightScore.tally(hands: hands, transactions: txs)
        runner.assertEqual(score.headline, "Alex is up 40")
        let others = score.rows.filter { $0.memberId != room.createdBy }
        let plan = NightPlan.plan(for: NightInput(
            isHost: true,
            phase: NightPhaseResolver.phase(for: event),
            myChips: .cashedOut,
            othersPlaying: others.filter { $0.status == .playing }.map(\.name),
            othersCashedOut: others.contains { $0.net != nil }
        ))
        runner.assertEqual(plan.primary, .waitingForCashOut(names: ["Sam"]))
        runner.assertEqual(plan.secondaries, [.settleNight])
    }

    runner.runAsync("S1.8: night-settled seeds a night settled inside the recap window") {
        let (_, _, event) = try await seeded("night-settled")
        guard let event, let settledAt = event.settledAt else {
            runner.assertNotNil(event?.settledAt, "seeded settled night"); return
        }
        runner.assertTrue(settledAt > Date().addingTimeInterval(-NightPlan.recapWindow), "inside 24h")
    }
}

// MARK: - NightPlan fixtures

/// The clock every NightPlan fixture is measured against.
private let nightBase = Date(timeIntervalSince1970: 1_800_000_000)

/// Builds a NightInput for the tests. The default is a live night
/// that started an hour ago with nobody at the table.
private func nightInput(
    isHost: Bool = false,
    playedAt: Date? = nil,
    settledAt: Date? = nil,
    now: Date = nightBase,
    iHaveHeldDeposit: Bool = false,
    myChips: MyChips = .none,
    othersPlaying: [String] = [],
    othersCashedOut: Bool = false
) -> NightInput {
    NightInput(
        isHost: isHost,
        phase: NightPhaseResolver.phase(NightFacts(
            playedAt: playedAt ?? nightBase.addingTimeInterval(-3_600),
            settledAt: settledAt,
            autoCloseHours: NightPhaseResolver.defaultAutoCloseHours,
            now: now
        )),
        iHaveHeldDeposit: iHaveHeldDeposit,
        myChips: myChips,
        othersPlaying: othersPlaying,
        othersCashedOut: othersCashedOut
    )
}
