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

    // MARK: - S1.3 NightPlan

    runner.run("S1.3: a member holding a deposit checks in first") {
        // The deposit is what they came for: getting it back is the
        // primary, the casino withdrawal waits underneath it.
        let plan = NightPlan.plan(for: nightInput(
            packSlugs: ["casino", "monopoly_deal"],
            iHaveHeldDeposit: true
        ))
        runner.assertEqual(plan.primary, NightAction.checkIn)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a member who already withdrew skips the check-in") {
        let plan = NightPlan.plan(for: nightInput(
            packSlugs: ["casino"],
            iHaveHeldDeposit: true,
            iHaveWithdrawn: true
        ))
        runner.assertEqual(plan.primary, NightAction.withdrawChips)
    }

    runner.run("S1.3: a casino night asks the member to withdraw chips") {
        let plan = NightPlan.plan(for: nightInput(packSlugs: ["casino"]))
        runner.assertEqual(plan.primary, NightAction.withdrawChips)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a CAH night asks the member to count their cards") {
        let plan = NightPlan.plan(for: nightInput(packSlugs: ["cards_against_humanity"]))
        runner.assertEqual(plan.primary, NightAction.countCAH)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a Monopoly Deal only night has no member action") {
        // No casino pack, so no chip withdrawal: the member has
        // nothing of their own to do at the table.
        let plan = NightPlan.plan(for: nightInput(packSlugs: ["monopoly_deal"]))
        runner.assertNil(plan.primary, "no member action on a Monopoly Deal only night")
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: the host waits for the table when nobody has arrived") {
        // fx30 — the caption is the primary slot, and the one line under
        // it is the night's score action (a host can always record a
        // round). It is never the host's own chip actions.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.waitingForTable(arrived: 0, claimed: 6))
        runner.assertEqual(plan.secondaries, [NightAction.scoreRound(packs: ["casino", "monopoly_deal"])])
    }

    runner.run("S1.3: nobody claimed a seat means no '0 of 0 here' caption") {
        // fx30 — a deposit-free room with no seats claimed has no table
        // to wait for; the "0 of 0 here" line was pure clutter.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            claimedCount: 0
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["casino", "monopoly_deal"]))
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: the host scores the first round once people arrive") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["monopoly_deal"]))
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: the host scores first with nothing under the primary") {
        // fx30 — the host's card before anything is scored is ONE
        // primary and no grey lines. Withdraw, settle chips and count
        // CAH live in the score picker now.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "cards_against_humanity", "monopoly_deal"],
            arrivedCount: 3,
            claimedCount: 6
        ))
        runner.assertEqual(
            plan.primary,
            NightAction.scoreRound(packs: ["casino", "cards_against_humanity", "monopoly_deal"])
        )
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a casino-only night gives the host the chips to score") {
        // fx30 — casino is scored by settling chips, so it is a scorable
        // pack now: the host gets "Score a round" instead of a bare
        // "Settle the night" with nothing played.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["casino"]))
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: the host settles a night with no pack to score") {
        // The old rule's branch still exists: a night whose only pack
        // the registry does not know cannot offer a score line.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["not_a_registered_pack"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.settleNight)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: the host settles once a round is scored") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6,
            roundsScored: 1
        ))
        runner.assertEqual(plan.primary, NightAction.settleNight)
        runner.assertEqual(plan.secondaries, [NightAction.scoreRound(packs: ["monopoly_deal"])])
    }

    runner.run("S1.3: the host settles after a casino settlement") {
        // fx30 — a settled hand is "something scored tonight": the night
        // is under way, so the primary is the settle and the one line
        // under it is the score picker.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6,
            casinoSettlements: 1
        ))
        runner.assertEqual(plan.primary, NightAction.settleNight)
        runner.assertEqual(plan.secondaries, [NightAction.scoreRound(packs: ["casino", "monopoly_deal"])])
    }

    runner.run("S1.3: casino and Monopoly Deal offers both packs, Casino first") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["casino", "monopoly_deal"]))
    }

    runner.run("S1.3: the host's own chip action lives in the picker, not under the card") {
        // fx30 — the host plays too, but their actions are the picker's
        // entries, not grey lines under the primary.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.secondaries, [])
        runner.assertTrue(
            !plan.secondaries.contains(.withdrawChips),
            "withdraw is not a line under the host's card"
        )
    }

    runner.run("S1.3: the picker packs put Casino first and keep the night's order") {
        // fx30 — the picker lists every pack on the night: casino first
        // when the night has it, the rest in the night's own order.
        runner.assertEqual(
            NightPlan.scorablePacks(in: ["cards_against_humanity", "casino", "monopoly_deal"]),
            ["casino", "cards_against_humanity", "monopoly_deal"]
        )
        runner.assertEqual(
            NightPlan.scorablePacks(in: ["monopoly_deal", "cards_against_humanity"]),
            ["monopoly_deal", "cards_against_humanity"]
        )
        runner.assertEqual(NightPlan.scorablePacks(in: []), [])
    }

    runner.run("S1.3: the picker labels the casino entry Casino chips") {
        runner.assertEqual(NightPlan.pickerTitle(for: "casino"), "Casino chips")
        runner.assertEqual(
            NightPlan.pickerTitle(for: "monopoly_deal"),
            PackRegistry.shared.definition(for: "monopoly_deal")?.displayName ?? ""
        )
        runner.assertEqual(
            NightPlan.pickerTitle(for: "cards_against_humanity"),
            PackRegistry.shared.definition(for: "cards_against_humanity")?.displayName ?? ""
        )
    }

    runner.run("S1.3: CAH is a scorable pack for the host") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["cards_against_humanity"],
            arrivedCount: 3,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["cards_against_humanity"]))
    }

    runner.run("S1.3: the host plans the next night once the night is settled") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino"],
            settledAt: nightBase.addingTimeInterval(-3_600)
        ))
        runner.assertEqual(plan.primary, NightAction.planNextNight)
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a settled night gives members nothing to do") {
        let plan = NightPlan.plan(for: nightInput(
            packSlugs: ["casino"],
            settledAt: nightBase.addingTimeInterval(-3_600)
        ))
        runner.assertNil(plan.primary, "a member has no action on a settled night")
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a night settled over 24 hours ago is history") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino"],
            settledAt: nightBase.addingTimeInterval(-90_000)
        ))
        runner.assertNil(plan.primary, "the recap window has closed")
        runner.assertEqual(plan.secondaries, [])
    }

    runner.run("S1.3: a night that has not started has no plan") {
        let plan = NightPlan.plan(for: nightInput(
            packSlugs: ["casino"],
            playedAt: nightBase.addingTimeInterval(3_600)
        ))
        runner.assertNil(plan.primary, "the night has not started")
        runner.assertEqual(plan.secondaries, [])
    }
    runS1NextRoundTests(runner)
    runS1SectionTests(runner)
    runS1SeedTests(runner)
}

// MARK: - S1.6 next round

func runS1NextRoundTests(_ runner: TestRunner) {
    let eventId = UUID()
    let roomId = UUID()
    let host = UUID()
    let sam = UUID()
    let alex = UUID()
    func round(_ pack: String, _ index: Int, winners: [UUID], at offset: TimeInterval = 0) -> EventRound {
        EventRound(
            id: UUID(),
            eventId: eventId,
            roomId: roomId,
            packSlug: pack,
            roundIndex: index,
            entries: winners.map { ScoreEntry(memberId: $0, pointsDelta: 3) },
            createdBy: host,
            createdAt: nightBase.addingTimeInterval(offset)
        )
    }

    runner.run("S1.6: a night with no rounds starts on round 1") {
        let next = NextRound.after([])
        runner.assertEqual(next.index, 1)
        runner.assertEqual(next.lastWinnerIds, [])
        runner.assertNil(NextRound.lastLine(winnerNames: ["Sam"], round: next.index))
    }

    runner.run("S1.6: the next round follows the highest round across every pack") {
        // Monopoly Deal reached round 3, CAH only round 1: a CAH save
        // must not land on round 2 and overwrite nothing it can see.
        let rounds = [
            round("monopoly_deal", 1, winners: [alex]),
            round("monopoly_deal", 3, winners: [sam], at: 60),
            round("cards_against_humanity", 1, winners: [alex], at: 30),
        ]
        let next = NextRound.after(rounds)
        runner.assertEqual(next.index, 4)
        runner.assertEqual(next.lastWinnerIds, [sam])
    }

    runner.run("S1.6: a corrected round names the winners from its latest row") {
        let rounds = [
            round("monopoly_deal", 2, winners: [alex], at: 0),
            round("monopoly_deal", 2, winners: [sam], at: 120),
        ]
        let next = NextRound.after(rounds)
        runner.assertEqual(next.index, 3)
        runner.assertEqual(next.lastWinnerIds, [sam])
    }

    runner.run("S1.6: the last-round caption names one, two or more winners") {
        runner.assertEqual(NextRound.lastLine(winnerNames: ["Sam"], round: 3), "Last: Sam won round 2")
        runner.assertEqual(NextRound.lastLine(winnerNames: ["Sam", "Alex"], round: 2), "Last: Sam and Alex won round 1")
        runner.assertEqual(NextRound.lastLine(winnerNames: ["Sam", "Alex", "Jo"], round: 5), "Last: Sam, Alex and Jo won round 4")
        runner.assertNil(NextRound.lastLine(winnerNames: [], round: 4))
    }
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

    runner.runAsync("S1.8: night-one-round seeds one scored round, so the host settles") {
        let (store, _, event) = try await seeded("night-one-round")
        guard let event else { runner.assertNotNil(event, "seeded night"); return }
        let rounds = try await store.fetchEventRounds(eventId: event.id)
        runner.assertEqual(rounds.count, 1)
        runner.assertEqual(NextRound.after(rounds).index, 2)
        let plan = NightPlan.plan(for: NightInput(
            isHost: true, packSlugs: event.packSlugs,
            phase: NightPhaseResolver.phase(for: event),
            arrivedCount: 3, claimedCount: 3,
            roundsScored: rounds.count, iHaveHeldDeposit: false, iHaveWithdrawn: false
        ))
        runner.assertEqual(plan.primary, .settleNight)
        runner.assertEqual(plan.secondaries, [.scoreRound(packs: ["monopoly_deal"])])
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
    packSlugs: [String] = [],
    playedAt: Date? = nil,
    settledAt: Date? = nil,
    now: Date = nightBase,
    arrivedCount: Int = 0,
    claimedCount: Int = 0,
    roundsScored: Int = 0,
    casinoSettlements: Int = 0,
    iHaveHeldDeposit: Bool = false,
    iHaveWithdrawn: Bool = false
) -> NightInput {
    NightInput(
        isHost: isHost,
        packSlugs: packSlugs,
        phase: NightPhaseResolver.phase(NightFacts(
            playedAt: playedAt ?? nightBase.addingTimeInterval(-3_600),
            settledAt: settledAt,
            autoCloseHours: NightPhaseResolver.defaultAutoCloseHours,
            now: now
        )),
        arrivedCount: arrivedCount,
        claimedCount: claimedCount,
        roundsScored: roundsScored,
        casinoSettlements: casinoSettlements,
        iHaveHeldDeposit: iHaveHeldDeposit,
        iHaveWithdrawn: iHaveWithdrawn
    )
}
