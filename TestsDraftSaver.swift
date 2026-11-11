//
//  TestsDraftSaver.swift
//  games-room
//
//  Task E — the settings write sequencer, as a table test.
//
//  The settings sheet used to own its write sequencing: a `.task(id: draft)`
//  debounce on the NavigationStack, an onDisappear flush, and a `writeTask`
//  handle refired when the sheet went away mid-write. `DraftSaver`
//  (`GamesRoom/Services/DraftSaver.swift`) owns all of it now; the view
//  only submits and flushes.
//
//  These cases pin the three behaviours the sheet depends on:
//
//    1. N rapid submits coalesce into exactly one write.
//    2. A flush right after a submit lands the write with the latest draft.
//    3. An edit that lands during an in-flight write queues exactly one
//       more write, carrying the newer draft.
//
//  The debounce is injected, so the whole file runs in milliseconds and
//  needs no network. Foundation only — no simulator.
//
//  Registered from main.swift through `runDraftSaverTests(runner)`.
//

import Foundation

// MARK: - Test doubles

/// Records the drafts a write carried, in the order the writes happened.
///
/// An actor, not an array: the saver's write closure is `@Sendable`, so
/// whatever it captures has to be sendable, and a plain mutable array
/// captured by an escaping closure is not.
actor DraftWriteRecorder<Payload: Sendable> {
    private(set) var drafts: [Payload] = []

    func record(_ draft: Payload) {
        drafts.append(draft)
    }

    func all() -> [Payload] { drafts }
    func count() -> Int { drafts.count }
}

/// Parks a write inside the "network" until the test releases it, so an
/// edit can be landed while a write is genuinely on the wire.
final class DraftWriteLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends the caller until the latch is released.
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Lets every parked write through, and every write that parks later.
    func release() {
        lock.lock()
        isOpen = true
        let parked = waiters
        waiters = []
        lock.unlock()
        for waiter in parked { waiter.resume() }
    }
}

/// What the refusing writer throws.
enum DraftSaverTestError: Error {
    case refused
}

/// Waits until `condition` holds, up to two seconds.
private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2_000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return await condition()
}

// MARK: - The table

func runDraftSaverTests(_ runner: TestRunner) {

    // MARK: - 1. N rapid submits → exactly one write

    runner.runAsync("DraftSaver: N rapid submits coalesce into exactly one write") {
        let recorder = DraftWriteRecorder<Int>()
        let saver = DraftSaver<Int>(debounce: .milliseconds(100)) { draft in
            await recorder.record(draft)
        }

        for draft in 1...5 {
            await saver.submit(draft)
        }

        try await Task.sleep(for: .milliseconds(400))

        // One write, and it carries the newest draft.
        runner.assertEqual(await recorder.all(), [5])
        runner.assertEqual(await saver.lastWrittenDraft(), 5)

        // Nothing is pending, so the flush must not write a second time.
        await saver.flush()
        runner.assertEqual(await recorder.all(), [5])
    }

    // MARK: - 2. A flush right after a submit

    runner.runAsync("DraftSaver: a flush right after a submit lands the write with the latest draft") {
        let recorder = DraftWriteRecorder<Int>()
        // A long debounce: the flush must not wait it out.
        let saver = DraftSaver<Int>(debounce: .seconds(2)) { draft in
            await recorder.record(draft)
        }

        await saver.submit(41)
        let started = Date()
        await saver.flush()
        let elapsed = Date().timeIntervalSince(started)

        runner.assertEqual(await recorder.all(), [41])
        runner.assertEqual(await saver.lastWrittenDraft(), 41)
        runner.assertTrue(
            elapsed < 1.0,
            "flush waited \(elapsed)s — the debounce was not skipped"
        )
    }

    // MARK: - 3. An edit during an in-flight write

    runner.runAsync("DraftSaver: an edit during an in-flight write queues exactly one more write") {
        let recorder = DraftWriteRecorder<Int>()
        let latch = DraftWriteLatch()
        let saver = DraftSaver<Int>(debounce: .milliseconds(50)) { draft in
            await recorder.record(draft)
            await latch.wait()
        }

        await saver.submit(1)

        // Wait until the first write is genuinely on the wire.
        let onTheWire = await waitUntil { await recorder.count() > 0 }
        runner.assertTrue(onTheWire, "the first write never reached the wire")

        // Three edits land while that write is in flight.
        await saver.submit(2)
        await saver.submit(3)
        await saver.submit(4)

        latch.release()
        await saver.flush()

        // Exactly one more write, carrying the newest draft.
        runner.assertEqual(await recorder.all(), [1, 4])
        runner.assertEqual(await saver.lastWrittenDraft(), 4)
    }

    // MARK: - 4. A refused write

    runner.runAsync("DraftSaver: a refused write is not retried on its own") {
        let attempts = DraftWriteRecorder<Int>()
        let saver = DraftSaver<Int>(debounce: .milliseconds(50)) { draft in
            await attempts.record(draft)
            throw DraftSaverTestError.refused
        }

        await saver.submit(9)
        try await Task.sleep(for: .milliseconds(300))

        // One attempt, no retry storm.
        runner.assertEqual(await attempts.all(), [9])
        runner.assertNil(await saver.lastWrittenDraft())
    }

    runner.runAsync("DraftSaver: a flush retries a refused draft exactly once") {
        let attempts = DraftWriteRecorder<Int>()
        let saver = DraftSaver<Int>(debounce: .milliseconds(50)) { draft in
            await attempts.record(draft)
            throw DraftSaverTestError.refused
        }

        await saver.submit(9)
        await saver.flush()

        // The write, then the one dismiss-time retry. No more.
        runner.assertEqual(await attempts.all(), [9, 9])
    }

    // MARK: - 5. The idle paths

    runner.runAsync("DraftSaver: a flush with nothing pending writes nothing") {
        let recorder = DraftWriteRecorder<Int>()
        let saver = DraftSaver<Int>(debounce: .milliseconds(20)) { draft in
            await recorder.record(draft)
        }

        await saver.flush()
        await saver.flush()

        runner.assertEqual(await recorder.all(), [])
        runner.assertNil(await saver.lastWrittenDraft())
    }

    runner.runAsync("DraftSaver: the settings draft is a usable payload") {
        let recorder = DraftWriteRecorder<RoomSettingsDraft>()
        let saver = DraftSaver<RoomSettingsDraft>(debounce: .milliseconds(20)) { draft in
            await recorder.record(draft)
        }

        let draft = RoomSettingsDraft(
            name: "Friday Night",
            mascotName: "Biscuit",
            mascotPersonality: .friendly,
            mascotPoliticalIdeology: .centrist,
            maxSeats: 8,
            memberInviteQuota: 3,
            joinStartingBonus: 100,
            socialNarrationEnabled: true,
            briefing48hEnabled: true,
            socialPreferencesEnabled: false,
            autoCloseHours: 4,
            seatDepositAmount: 25,
            seatDepositTrigger: .escrow,
            seatDepositGraceMinutes: 15,
            showBroughtBy: true,
            hostJournal: "We did the thing.",
            seasonSubtitle: "Winter"
        )

        await saver.submit(draft)
        await saver.flush()

        runner.assertEqual(await recorder.all(), [draft])
        runner.assertEqual(await saver.lastWrittenDraft(), draft)
    }
}
