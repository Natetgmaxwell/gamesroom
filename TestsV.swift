//
//  TestsV.swift
//  games-room
//
//  V lane (view-layer machines outside RoomDetailView) test group.
//  Registered from main.swift through `runVTests(runner)`. Foundation-only,
//  so it runs in the macOS test binary with no simulator and no network.
//
//  What is pinned here: the `WriteState` transition table, the
//  `WriteGate` serializer (including the D7 window — an edit that lands
//  while a save is in flight must be persisted), `SubmitOnce` (D16), and
//  the stable/unique ids of the three presentation enums that replace the
//  Bool clusters.
//

import Foundation

// MARK: - Helpers

/// A name store that parks its first write inside the RPC, so a test can
/// land an edit in the exact window D7 used to drop: a save is in flight and
/// the user types one more character.
final class SuspendingNameSaver {
    private(set) var saved: [String] = []
    private(set) var currentName: String
    private(set) var suspendNext = true
    private var pending: [CheckedContinuation<Void, Never>] = []

    init(currentName: String) {
        self.currentName = currentName
    }

    /// True while a write is parked inside the "network".
    var isWaiting: Bool { !pending.isEmpty }

    func update(_ name: String) async {
        if suspendNext {
            suspendNext = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                pending.append(continuation)
            }
        }
        saved.append(name)
        currentName = name
    }

    func release() {
        let waiters = pending
        pending = []
        for waiter in waiters { waiter.resume() }
    }
}

/// `AppSettingsView.save()` in miniature: the same `WriteGate`, the same
/// "already persisted" guard, the same refire. The view is SwiftUI and
/// cannot be built in the Foundation runner, so the test drives the
/// production gate through the same shape the view uses.
final class NameSaveHarness {
    let saver: SuspendingNameSaver
    var gate = WriteGate()
    var name: String

    init(saver: SuspendingNameSaver, name: String) {
        self.saver = saver
        self.name = name
    }

    func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != saver.currentName else { return }
        guard gate.begin() else { return }
        defer {
            if gate.end() {
                Task { await self.save() }
            }
        }
        await saver.update(trimmed)
    }
}

/// Polls until `condition` holds or `ticks` milliseconds pass. Used only to
/// let a detached refire run; there is no I/O behind it.
private func waitUntil(_ ticks: Int = 2_000, _ condition: () -> Bool) async -> Bool {
    var spent = 0
    while !condition(), spent < ticks {
        try? await Task.sleep(nanoseconds: 1_000_000)
        spent += 1
    }
    return condition()
}

private func vUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

private func vQuestion(_ n: Int, text: String = "Which decade would you live in?") -> RoomQuestion {
    RoomQuestion(
        id: vUUID(100 + n),
        roomId: vUUID(1),
        eventId: nil,
        source: .host,
        text: text,
        tag: nil,
        drawnAt: nil,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        authorId: nil,
        authorDisplayName: nil
    )
}

private func vRoom(_ n: Int, name: String) -> Room {
    Room(
        id: vUUID(n),
        name: name,
        mascotName: "Tally",
        mascotPersonality: .professional,
        mascotPoliticalIdeology: .apolitical,
        createdBy: vUUID(900),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
        isLive: false,
        userRole: .host
    )
}

// MARK: - V lane

/// Runs the V lane's cases against the shared runner.
func runVTests(_ runner: TestRunner) {

    // MARK: Operation

    runner.run("V: Operation cases are the five write owners, raw values stable") {
        // The raw value is the case name and is used as the enum's `id`. A
        // rename would silently change a test id, so pin the set.
        runner.assertEqual(
            Operation.allCases.map(\.rawValue),
            ["settings", "displayName", "shareCode", "declareSeason", "deleteRoom"]
        )
        runner.assertEqual(Set(Operation.allCases.map(\.id)).count, 5)
    }

    // MARK: WriteState transition table

    runner.run("V: WriteState — an edit retires saved and failed, but not an in-flight save") {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        // D8: "Saved" must not outlive the next edit.
        runner.assertEqual(WriteState.saved(at: stamp).reduce(.edited), .idle)
        runner.assertEqual(
            WriteState.failed(.settings, "offline").reduce(.edited),
            .idle
        )
        // An edit during a write leaves the spinner up: something is still on
        // the wire, and the gate has already queued the refire.
        runner.assertEqual(WriteState.saving.reduce(.edited), .saving)
        runner.assertEqual(WriteState.idle.reduce(.edited), .idle)
    }

    runner.run("V: WriteState — begin, succeed and fail land in the right case") {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        runner.assertEqual(WriteState.idle.reduce(.begin(.settings)), .saving)
        // A second begin while saving stays saving (the gate, not the state,
        // decides that only one write runs).
        runner.assertEqual(WriteState.saving.reduce(.begin(.shareCode)), .saving)
        runner.assertEqual(
            WriteState.saving.reduce(.succeed(at: stamp)),
            .saved(at: stamp)
        )
        runner.assertEqual(
            WriteState.saved(at: stamp).reduce(.fail(.displayName, "Name taken")),
            .failed(.displayName, "Name taken")
        )
        runner.assertEqual(
            WriteState.failed(.settings, "offline").reduce(.begin(.settings)),
            .saving
        )
    }

    runner.run("V: WriteState — isBusy and the failure accessors") {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        runner.assertTrue(WriteState.saving.isBusy)
        runner.assertFalse(WriteState.idle.isBusy)
        runner.assertFalse(WriteState.saved(at: stamp).isBusy)
        runner.assertFalse(WriteState.failed(.settings, "offline").isBusy)

        runner.assertEqual(
            WriteState.failed(.shareCode, "Mint failed").failedOperation,
            .shareCode
        )
        runner.assertNil(WriteState.saved(at: stamp).failedOperation)
        runner.assertNil(WriteState.idle.failureMessage)
        runner.assertEqual(
            WriteState.failed(.shareCode, "Mint failed").failureMessage,
            "Mint failed"
        )
    }

    runner.run("V D9/D10: a share-code failure is not a settings failure") {
        // The whole point of the tag: the invite-code row asks about its own
        // operation and gets the message; the settings status row asks about
        // `.settings` and stays quiet.
        let state = WriteState.failed(.shareCode, "Mint failed")
        runner.assertEqual(state.failure(for: .shareCode), "Mint failed")
        runner.assertNil(state.failure(for: .settings))
        runner.assertNil(state.failure(for: .declareSeason))
        runner.assertNil(state.failure(for: .deleteRoom))
    }

    // MARK: WriteGate

    runner.run("V: WriteGate — one write at a time, exactly one refire") {
        var gate = WriteGate()
        runner.assertTrue(gate.begin(), "first write starts")
        runner.assertTrue(gate.isWriting)
        // Two overlapping edits queue one refire, not two.
        runner.assertFalse(gate.begin(), "second write must not start")
        runner.assertFalse(gate.begin(), "third write must not start either")
        runner.assertTrue(gate.end(), "the queued refire must run")
        runner.assertFalse(gate.isWriting)
        runner.assertFalse(gate.end(), "no second refire is invented")
        runner.assertTrue(gate.begin(), "the gate is reusable after a refire")
        runner.assertFalse(gate.end())
        runner.assertTrue(gate.begin())
    }

    runner.run("V: WriteGate — an uninterrupted write leaves no refire behind") {
        var gate = WriteGate()
        runner.assertTrue(gate.begin())
        runner.assertFalse(gate.end())
        runner.assertFalse(gate.end())
    }

    runner.runAsync("V D7: an edit during an in-flight name save is persisted") {
        let saver = SuspendingNameSaver(currentName: "Nathan")
        let harness = NameSaveHarness(saver: saver, name: "Nathan Max")

        let first = Task { await harness.save() }
        let parked = await waitUntil { saver.isWaiting }
        runner.assertTrue(parked, "the first save should be in flight")

        // The keystroke that used to be dropped: the old `guard !isSaving`
        // returned here and nothing rescheduled the write.
        harness.name = "Nathan Maxwell"
        await harness.save()
        runner.assertTrue(harness.gate.refire, "the edit must queue a refire")

        saver.release()
        await first.value
        let refired = await waitUntil { saver.saved.count >= 2 }
        runner.assertTrue(refired, "the refire should have run")
        runner.assertEqual(saver.saved, ["Nathan Max", "Nathan Maxwell"])
        runner.assertEqual(saver.currentName, "Nathan Maxwell")
    }

    runner.runAsync("V D7: a save that is already persisted does not write twice") {
        // The refire must not loop when the newest value is already the
        // server's: `save()` guards on "already persisted" before the gate.
        let saver = SuspendingNameSaver(currentName: "Nathan")
        let harness = NameSaveHarness(saver: saver, name: "Nathan")
        await harness.save()
        runner.assertEqual(saver.saved, [])
        runner.assertFalse(harness.gate.isWriting)
    }

    // MARK: SubmitOnce

    runner.run("V D16: SubmitOnce drops the Return echo, keeps a real second edit") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var once = SubmitOnce()
        // Return submits, Return resigns focus, focus loss submits again.
        runner.assertTrue(once.claim("Tea or coffee forever?", now: t0))
        runner.assertFalse(once.claim("Tea or coffee forever?", now: t0.addingTimeInterval(0.05)))
        // Trimming is part of the identity: the field is trimmed before write.
        runner.assertFalse(once.claim("  Tea or coffee forever? ", now: t0.addingTimeInterval(0.2)))
        // A different value is a new write.
        runner.assertTrue(once.claim("Coffee forever?", now: t0.addingTimeInterval(0.3)))
        // The same value after the window is the user asking again.
        runner.assertTrue(once.claim("Coffee forever?", now: t0.addingTimeInterval(SubmitOnce.echoWindow + 1)))
    }

    runner.run("V D16: SubmitOnce lets an empty clear through once, then dedupes it") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var once = SubmitOnce()
        runner.assertTrue(once.claim("Surfing", now: t0))
        runner.assertTrue(once.claim("", now: t0.addingTimeInterval(0.2)))
        runner.assertFalse(once.claim("   ", now: t0.addingTimeInterval(0.3)))
    }

    // MARK: Presentation enum ids

    runner.run("V D11: RoomSettingsConfirm ids are stable, unique and equal the case names") {
        runner.assertEqual(
            RoomSettingsConfirm.allCases.map(\.id),
            ["declareSeason", "deleteRoom", "leaveRoom"]
        )
        runner.assertEqual(Set(RoomSettingsConfirm.allCases.map(\.id)).count, 3)
        // One confirm at a time is the type's job now.
        runner.assertFalse(RoomSettingsConfirm.deleteRoom.id == RoomSettingsConfirm.leaveRoom.id, "delete and leave are different confirms")
    }

    runner.run("V D14: QBSheet ids separate add from each question") {
        let first = QBSheet.editing(vQuestion(1))
        let sameQuestion = QBSheet.editing(vQuestion(1))
        let otherQuestion = QBSheet.editing(vQuestion(2, text: "Best sandwich?"))
        runner.assertEqual(first.id, sameQuestion.id)
        runner.assertFalse(first.id == otherQuestion.id, "different questions are different sheets")
        runner.assertFalse(first.id == QBSheet.adding.id, "add is not an edit")
        runner.assertEqual(QBSheet.adding.id, "add")
        // A stable id is what lets `.sheet(item:)` keep the presented sheet
        // when the list reloads with the same row.
        runner.assertEqual(first.id, "edit-\(vUUID(101).uuidString)")
    }

    runner.run("V: RoomListPresentation ids are unique and carry the room for settings") {
        let roomA = vRoom(1, name: "Carwoola Crew")
        let roomB = vRoom(2, name: "Friday Night")
        let all = [
            RoomListPresentation.settings(roomA),
            RoomListPresentation.settings(roomB),
            RoomListPresentation.createRoom,
            RoomListPresentation.joinRoom,
            RoomListPresentation.appSettings
        ]
        runner.assertEqual(Set(all.map(\.id)).count, 5)
        runner.assertEqual(RoomListPresentation.settings(roomA).id, "settings-\(vUUID(1).uuidString)")
        runner.assertFalse(
            RoomListPresentation.settings(roomA).id == RoomListPresentation.settings(roomB).id,
            "settings ids carry the room"
        )
        runner.assertEqual(RoomListPresentation.createRoom.id, "createRoom")
        runner.assertEqual(RoomListPresentation.joinRoom.id, "joinRoom")
        runner.assertEqual(RoomListPresentation.appSettings.id, "appSettings")
        // Equatable payloads make "replace the presentation" testable.
        runner.assertEqual(RoomListPresentation.settings(roomA), RoomListPresentation.settings(roomA))
        runner.assertFalse(
            RoomListPresentation.settings(roomA) == RoomListPresentation.settings(roomB),
            "different rooms are different presentations"
        )
    }
}
