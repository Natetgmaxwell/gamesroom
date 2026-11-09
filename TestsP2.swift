//
//  TestsP2.swift
//  games-room
//
//  Lane P2 (state machines) test group. Registered from main.swift
//  through `runP2Tests(runner)`. Foundation only, so it runs in the
//  macOS test binary with no simulator and no network.
//
//  Three machines live here: the room page's presentation selector,
//  the settle-with-Undo phase, and the hero invite code. Each test
//  drives the production type — no copies.
//

import Foundation

/// Runs the lane P2 cases against the shared runner.
func runP2Tests(_ runner: TestRunner) {
    runP2PresentationTests(runner)
    runP2SettleTests(runner)
    runP2InviteCodeTests(runner)
}

// MARK: - Fixtures

private func p2Event(_ suffix: String = "night") -> Event {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    return Event(
        id: UUID(),
        roomId: UUID(),
        name: suffix,
        playedAt: now.addingTimeInterval(-3_600),
        createdAt: now.addingTimeInterval(-86_400)
    )
}

private func p2Room() -> Room {
    Room(
        id: UUID(),
        name: "Test",
        mascotName: "M",
        mascotPersonality: .friendly,
        mascotPoliticalIdeology: .centrist,
        createdBy: UUID(),
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        isLive: false,
        userRole: .host
    )
}

// MARK: - Presentation (audit 03 C1 / D12)

private func runP2PresentationTests(_ runner: TestRunner) {
    let room = p2Room()
    let night = p2Event()
    let target = HostScoreTarget(event: night, packSlug: "casino")

    runner.run("P2: every RoomPresentation case has a stable, unique id") {
        let cases: [RoomPresentation] = [
            .settings(room),
            .editEvent(night),
            .addEvent(seed: nil),
            .addEvent(seed: night.playedAt),
            .withdraw(night),
            .settleScan(night),
            .cahScan(night),
            .hostScore(target),
            .createRoom,
        ]
        let ids = cases.map(\.id)
        runner.assertTrue(ids.count == Set(ids).count, "ids must be unique")
        // Stability: the same payload yields the same id, so a rebuilt
        // view does not re-present.
        runner.assertEqual(RoomPresentation.settings(room).id, RoomPresentation.settings(room).id)
        runner.assertEqual(RoomPresentation.createRoom.id, "createRoom")
        runner.assertEqual(RoomPresentation.addEvent(seed: nil).id, "addEvent:none")
    }

    runner.run("P2: a second presentation replaces the first because the id changes") {
        // `.sheet(item:)` swaps content when the item's id changes and
        // keeps the old content when it does not. The page therefore
        // rests on: two different cases never share an id.
        var presenting: RoomPresentation? = .createRoom
        let firstId = presenting?.id
        presenting = .settings(room)
        runner.assertEqual(presenting, .settings(room))
        runner.assertTrue(firstId != presenting?.id, "a new case must carry a new id")
        // Two nights on the same page are two different sheets.
        let otherNight = p2Event("next week")
        runner.assertTrue(
            RoomPresentation.withdraw(night).id != RoomPresentation.withdraw(otherNight).id,
            "the payload is part of the id"
        )
    }

    runner.run("P2: RoomConfirm ids separate the two pack lists on one night") {
        let one = RoomConfirm.scoreChoice(event: night, packs: ["casino", "cah"])
        let two = RoomConfirm.scoreChoice(event: night, packs: ["casino"])
        runner.assertTrue(one.id != two.id)
        runner.assertEqual(one.event.id, night.id)
        runner.assertEqual(two.packs, ["casino"])
    }

    runner.run("P2: PackEditor names the pack, and the Casino sheet names none") {
        let payout = PackEditor.payout(packSlug: "cah")
        let cah = PackEditor.cahConfig(packSlug: "cah")
        let casino = PackEditor.casinoConfig
        runner.assertEqual(payout.packSlug, "cah")
        runner.assertEqual(cah.packSlug, "cah")
        runner.assertNil(casino.packSlug)
        // Same pack, two sheets: the ids must still differ, or the
        // shelf would keep the first editor on screen for the second.
        runner.assertTrue(payout.id != cah.id)
        runner.assertTrue(cah.id != casino.id)
    }
}

// MARK: - Settle with Undo (audit 03 C2, D5, D6)

/// The view's 5 s window, reduced to the smallest thing that can be
/// tested: cancel the previous window, then wait and commit.
///
/// An actor, not a `@MainActor` type: the runner waits on a semaphore
/// from the main thread, so anything that needs the main actor would
/// deadlock the whole suite.
private actor SettleWindowHarness {
    var phase: SettlePhase = .idle
    var task: Task<Void, Never>?
    private(set) var commits: [UUID] = []

    func settle(_ event: Event, window: Duration = .milliseconds(40)) {
        guard !phase.isCommitting else { return }
        task?.cancel()
        let id = event.id
        task = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            await self?.recordCommit(id)
        }
        phase = phase.reduce(.begin(event))
    }

    private func recordCommit(_ id: UUID) {
        commits.append(id)
        phase = phase.reduce(.commitStarted(id))
    }
}

private func runP2SettleTests(_ runner: TestRunner) {
    let night = p2Event()

    runner.run("P2: settle — begin opens the undo window and the toast, undo closes both") {
        var phase = SettlePhase.idle
        runner.assertFalse(phase.showsToast, "idle shows no toast")
        phase = phase.reduce(.begin(night))
        runner.assertEqual(phase, .undoing(event: night))
        runner.assertEqual(phase.undoingEvent?.id, night.id)
        runner.assertTrue(phase.showsToast, "the toast is up during the window")
        phase = phase.reduce(.undo)
        runner.assertEqual(phase, .idle)
        runner.assertFalse(phase.showsToast)
    }

    runner.run("P2: settle — the toast stays through committing (D5)") {
        var phase = SettlePhase.undoing(event: night)
        phase = phase.reduce(.commitStarted(night.id))
        runner.assertEqual(phase, .committing(eventId: night.id))
        runner.assertTrue(phase.showsToast, "the toast must not vanish before the RPC answers")
        runner.assertTrue(phase.isCommitting)
        runner.assertNil(phase.undoingEvent, "Undo is gone once the write is out (D6)")
        phase = phase.reduce(.commitSucceeded(night.id))
        runner.assertEqual(phase, .idle)
        runner.assertFalse(phase.showsToast)
    }

    runner.run("P2: settle — a failed commit is .failed, never .idle") {
        var phase = SettlePhase.undoing(event: night)
        phase = phase.reduce(.commitStarted(night.id))
        phase = phase.reduce(.commitFailed(night.id, SettlePhase.failureMessage))
        runner.assertEqual(phase, .failed(eventId: night.id, message: SettlePhase.failureMessage))
        runner.assertEqual(phase.failedEventId, night.id)
        runner.assertEqual(phase.failedMessage, "Couldn't settle. Try again.")
        runner.assertFalse(phase.showsToast, "the toast is not the failure surface")
    }

    runner.run("P2: settle — a retry from .failed reopens the window") {
        var phase = SettlePhase.failed(eventId: night.id, message: SettlePhase.failureMessage)
        phase = phase.reduce(.begin(night))
        runner.assertEqual(phase, .undoing(event: night))
        runner.assertNil(phase.failedMessage)
    }

    runner.run("P2: settle — a message for another night is ignored") {
        let other = p2Event("other")
        var phase = SettlePhase.undoing(event: night)
        phase = phase.reduce(.commitStarted(other.id))
        runner.assertTrue(phase == .undoing(event: night), "a stale window cannot move the phase")
        phase = phase.reduce(.commitStarted(night.id))
        let moved = phase.reduce(.commitFailed(other.id, "boom"))
        runner.assertEqual(moved, .committing(eventId: night.id))
    }

    runner.run("P2: settle — a second settle while committing does not send twice") {
        var phase = SettlePhase.undoing(event: night)
        phase = phase.reduce(.commitStarted(night.id))
        let unchanged = phase.reduce(.begin(p2Event("same night, second tap")))
        runner.assertEqual(unchanged, .committing(eventId: night.id))
    }

    runner.runAsync("P2: settle — a second settle while undoing cancels the first window") {
        let harness = await SettleWindowHarness()
        let first = p2Event("first")
        let second = p2Event("second")
        await harness.settle(first)
        await harness.settle(second)
        try? await Task.sleep(for: .milliseconds(200))
        let commits = await harness.commits
        runner.assertTrue(commits == [second.id], "only the surviving window commits")
        let phase = await harness.phase
        runner.assertEqual(phase, .committing(eventId: second.id))
    }
}

// MARK: - Hero invite code (audit 03 C6)

private func runP2InviteCodeTests(_ runner: TestRunner) {
    runner.run("P2: invite — ready carries the code and no error") {
        let phase = InviteCodePhase.ready("GR-1234")
        runner.assertEqual(phase.code, "GR-1234")
        runner.assertNil(phase.errorMessage)
        runner.assertFalse(phase.isMinting)
    }

    runner.run("P2: invite — a retry clears the previous failure at mint start") {
        // The old code cleared the error only on success, so the second
        // attempt showed the first attempt's failure for its whole
        // round trip. `.minting` is now the moment the error goes.
        var phase = InviteCodePhase.failed(InviteCodePhase.failureMessage)
        runner.assertEqual(phase.errorMessage, "Couldn't make a join code. Try again.")
        phase = .minting
        runner.assertNil(phase.errorMessage)
        runner.assertTrue(phase.isMinting)
        runner.assertNil(phase.code)
        phase = .ready("GR-9999")
        runner.assertEqual(phase.code, "GR-9999")
    }
}
