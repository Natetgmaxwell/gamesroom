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
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.waitingForTable(arrived: 0, claimed: 6))
    }

    runner.run("S1.3: the host scores the first round once people arrive") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["monopoly_deal"]))
    }

    runner.run("S1.3: the host settles a night with nothing to score") {
        // Casino is a withdraw-and-return pack: there is no round to
        // score, so the night is ready to be settled.
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.settleNight)
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

    runner.run("S1.3: casino and Monopoly Deal scores Monopoly Deal, not the chip scanner") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["monopoly_deal"]))
    }

    runner.run("S1.3: the host gets their member action as a secondary") {
        let plan = NightPlan.plan(for: nightInput(
            isHost: true,
            packSlugs: ["casino", "monopoly_deal"],
            arrivedCount: 2,
            claimedCount: 6
        ))
        runner.assertEqual(plan.primary, NightAction.scoreRound(packs: ["monopoly_deal"]))
        runner.assertEqual(plan.secondaries, [NightAction.withdrawChips])
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
    iHaveHeldDeposit: Bool = false,
    iHaveWithdrawn: Bool = false
) -> NightInput {
    NightInput(
        isHost: isHost,
        packSlugs: packSlugs,
        playedAt: playedAt ?? nightBase.addingTimeInterval(-3_600),
        settledAt: settledAt,
        now: now,
        arrivedCount: arrivedCount,
        claimedCount: claimedCount,
        roundsScored: roundsScored,
        iHaveHeldDeposit: iHaveHeldDeposit,
        iHaveWithdrawn: iHaveWithdrawn
    )
}
