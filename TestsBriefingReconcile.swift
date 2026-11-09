//
//  TestsBriefingReconcile.swift
//  GamesRoom
//
//  Briefing-reconcile tests for the notification-etiquette fix
//  (2026-11-04), compiled into the Foundation test binary by
//  build-and-run-tests.sh alongside main.swift and invoked from
//  main.swift via runBriefingReconcileTests(). Separate file so
//  the over-cap main.swift does not grow (pre-commit ratchet).
//
//  Proves, via a fake notification center + fake fired-ledger:
//   a. an escrow claim leaves zero claim language pending;
//   b. room re-open after claim schedules no claim language and
//      never re-adds on-create, even with the delivered list
//      empty;
//   c. declined leaves zero pending requests;
//   d. unclaimed reminders keep the reminder clause;
//   e. a host device schedules only the host's own identifiers;
//   plus the 25-voice claimed-body claim-language matrix scan.
//

import Foundation

func runBriefingReconcileTests() {
    // MARK: - Briefing reconcile (notification-etiquette fix, 2026-11-04)

    final class FakeBriefingSink: BriefingNotificationSink, @unchecked Sendable {
        var pending: [String] = []
        var delivered: [String] = []
        var added: [PlannedBriefingNotification] = []
        /// Every add and removal, in the order the reconciler issued
        /// them: `"add:<id>"` / `"remove:<id>"`. Audit 04 D1.
        var log: [String] = []
        /// When true, `add` suspends once before landing. A detached
        /// add (the pre-fix shape) would then lose the race against
        /// an assertion that runs right after `reconcile` returns.
        var yieldsOnAdd = false

        func pendingIdentifiers() async -> [String] { pending }
        func deliveredIdentifiers() async -> [String] { delivered }

        func removePending(identifiers: [String]) {
            pending.removeAll { identifiers.contains($0) }
            added.removeAll { identifiers.contains($0.identifier) }
            for id in identifiers { log.append("remove:\(id)") }
        }

        func add(
            identifier: String,
            title: String,
            body: String,
            kindRaw: String,
            eventId: UUID,
            fireAt: Date
        ) async throws {
            if yieldsOnAdd { await Task.yield() }
            pending.append(identifier)
            added.append(PlannedBriefingNotification(
                identifier: identifier,
                title: title,
                body: body,
                kindRaw: kindRaw,
                eventId: eventId,
                fireAt: fireAt
            ))
            log.append("add:\(identifier)")
        }

        func claimLanguageCount() -> Int {
            added.filter { $0.body.lowercased().contains("claim") }.count
        }

        /// True when some identifier was removed before it was ever
        /// added — the exact inversion D1 describes.
        func hasRemoveBeforeMatchingAdd() -> Bool {
            var addedIds = Set<String>()
            for entry in log {
                if entry.hasPrefix("add:") {
                    addedIds.insert(String(entry.dropFirst(4)))
                } else if entry.hasPrefix("remove:") {
                    let id = String(entry.dropFirst(7))
                    if !addedIds.contains(id) { return true }
                }
            }
            return false
        }
    }

    final class FakeOnCreateLedger: BriefingOnCreateLedger, @unchecked Sendable {
        var fired: Set<String> = []

        func hasFiredOnCreate(eventId: UUID, userId: UUID) -> Bool {
            fired.contains("\(eventId.uuidString)-on_create-\(userId.uuidString)")
        }

        func markOnCreateFired(eventId: UUID, userId: UUID) {
            fired.insert("\(eventId.uuidString)-on_create-\(userId.uuidString)")
        }
    }

    /// Runs the reconciler exactly as `RoomService.reconcileBriefing`
    /// → `NotificationDispatcher.reconcileBriefing` does in production,
    /// with the fake sink + fake ledger standing in for
    /// `UNUserNotificationCenter` + UserDefaults.
    func runBriefingReconcile(
        sink: FakeBriefingSink,
        ledger: FakeOnCreateLedger,
        state: MemberRSVPState,
        eventId: UUID,
        userId: UUID,
        personality: MascotPersonality = .friendly,
        ideology: MascotPoliticalIdeology = .centrist,
        now: Date,
        playedAt: Date
    ) async {
        await BriefingReconciler.reconcile(
            sink: sink,
            ledger: ledger,
            eventId: eventId,
            eventName: "Friday Night Hold'em",
            playedAt: playedAt,
            mascotName: "Ace",
            userId: userId,
            memberName: "Nathan",
            state: state,
            personality: personality,
            ideology: ideology,
            now: now
        )
    }

    // Fixed clock: an evening "now" with the event 14 days out, so
    // T-168h, T-84h and the 09:00 morning-of slots are all in the
    // future and every reconcile plans the full trio.
    let brNow = Date(timeIntervalSince1970: 1_792_000_000)
    let brPlayedAt = brNow.addingTimeInterval(14 * 24 * 3600)

    // Done-when (a): after an escrow claim (state flips to .claimed
    // with requests previously scheduled as .unclaimed), pending
    // requests for that event contain zero claim language.
    runner.runAsync("briefing reconcile: escrow claim leaves zero claim language") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        // Event created → unclaimed trio + on-create scheduled.
        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertTrue(
            sink.claimLanguageCount() > 0,
            "unclaimed baseline should carry the claim clause"
        )

        // Escrow claim → reconcile to .claimed.
        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .claimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertEqual(sink.claimLanguageCount(), 0)
        runner.assertEqual(sink.pending.count, 3)
        runner.assertFalse(
            sink.pending.contains {
                $0.hasPrefix("\(eventId.uuidString)-on_create-\(userId.uuidString)")
            },
            "claimed member must not have an on-create prompt pending"
        )
    }

    // Done-when (b): room re-open after claim (realtime INSERT path
    // and room-open path both route through reconcileBriefing) — no
    // claim language, and on-create is NOT re-added even when the
    // delivered list is empty (banner dismissed).
    runner.runAsync("briefing reconcile: room re-open after claim, empty delivered") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        // Claim, then the banner is delivered AND dismissed — the
        // pre-fix code re-added on-create in exactly this state.
        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .claimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        sink.delivered = []

        // Two re-opens in a row (realtime echo + room open).
        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .claimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .claimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertEqual(sink.claimLanguageCount(), 0)
        runner.assertEqual(sink.pending.count, 3)
        let onCreateCount = sink.pending.filter {
            $0.contains("on_create")
        }.count
        runner.assertEqual(onCreateCount, 0)
    }

    // Done-when (c): declined → zero pending requests for that event.
    runner.runAsync("briefing reconcile: declined cancels everything") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertFalse(sink.pending.isEmpty)

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .declined,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertEqual(sink.pending.count, 0)
        runner.assertEqual(sink.added.count, 0)
    }

    // Done-when (d): unclaimed reminders still carry the reminder
    // clause — the fix must not silence members who never responded.
    runner.runAsync("briefing reconcile: unclaimed reminders keep the claim clause") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertEqual(sink.pending.count, 4)
        let reminderBodies = sink.added
            .filter { $0.kindRaw != BriefingReconciler.onCreateKindRaw }
            .map(\.body)
        runner.assertEqual(reminderBodies.count, 3)
        runner.assertTrue(
            reminderBodies.allSatisfy { $0.lowercased().contains("claim") },
            "every unclaimed reminder carries the claim clause"
        )
        runner.assertTrue(
            ledger.hasFiredOnCreate(eventId: eventId, userId: userId)
        )
    }

    // Done-when (e): a device schedules for its signed-in user only.
    // addEvent on the host device reconciles the HOST — the pending
    // identifiers contain the host's userId and no other member's.
    runner.runAsync("briefing reconcile: host device schedules only host identifiers") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID()
        let hostId = UUID()
        let memberA = UUID(), memberB = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: hostId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertTrue(
            sink.pending.allSatisfy { $0.contains(hostId.uuidString) },
            "every identifier belongs to the host"
        )
        runner.assertFalse(
            sink.pending.contains { $0.contains(memberA.uuidString) }
        )
        runner.assertFalse(
            sink.pending.contains { $0.contains(memberB.uuidString) }
        )
        runner.assertEqual(sink.pending.count, 4)
    }

    // The locked-rule matrix scan: no "claim" (case-insensitive) in
    // ANY claimed-state body across every personality × ideology
    // cell, for T-168h, T-84h and morning-of.
    runner.run("briefing reconcile: claimed bodies claim-free across the 25-voice matrix") {
        for personality in MascotPersonality.allCases {
            for ideology in MascotPoliticalIdeology.allCases {
                for morning in [false, true] {
                    let body = BriefingReconciler.reminderBody(
                        eventName: "Friday Night Hold'em",
                        playedAt: brPlayedAt,
                        state: .claimed,
                        memberName: "Nathan",
                        morning: morning,
                        hostNote: nil,
                        personality: personality,
                        ideology: ideology,
                        mascotName: "Ace"
                    )
                    runner.assertFalse(
                        body.lowercased().contains("claim"),
                        "claimed body contains claim language (\(personality)/\(ideology)/\(morning ? "morning" : "48h")): \(body)"
                    )
                }
            }
        }
    }

    // The once-per-install on-create gate — even with the delivered
    // list empty (dismissed banner), a second unclaimed reconcile must
    // not stack a second on-create prompt.
    runner.runAsync("briefing reconcile: on-create fires once per install, delivered empty") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        sink.delivered = []

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        let onCreateCount = sink.pending.filter { $0.contains("on_create") }.count
        runner.assertEqual(onCreateCount, 1)
        runner.assertEqual(sink.pending.count, 4)
    }

    // A delivered on-create banner must not be re-added even if the
    // ledger was somehow reset (belt-and-braces delivered check).
    runner.runAsync("briefing reconcile: delivered on-create never re-added") {
        let sink = FakeBriefingSink()
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()
        let onCreateId = BriefingReconciler.identifier(
            eventId: eventId, kindRaw: BriefingReconciler.onCreateKindRaw, userId: userId
        )

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        // The prompt fired: it leaves pending and lands in delivered
        // (mirrors UN semantics), then the user dismisses the banner
        // and the ledger is somehow reset.
        sink.pending.removeAll { $0 == onCreateId }
        sink.delivered = [onCreateId]
        ledger.fired = []

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        let onCreateCount = sink.pending.filter { $0 == onCreateId }.count
        runner.assertEqual(onCreateCount, 0)
    }

    // Claimed and declined members never qualify for the on-create
    // prompt (it asks them to claim — the exact bug this fixes).
    runner.run("briefing reconcile: on-create gate refuses claimed and declined") {
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()
        runner.assertFalse(
            BriefingReconciler.shouldFireOnCreate(
                state: .claimed, eventId: eventId, userId: userId, ledger: ledger
            )
        )
        runner.assertFalse(
            BriefingReconciler.shouldFireOnCreate(
                state: .declined, eventId: eventId, userId: userId, ledger: ledger
            )
        )
        runner.assertTrue(
            BriefingReconciler.shouldFireOnCreate(
                state: .unclaimed, eventId: eventId, userId: userId, ledger: ledger
            )
        )
    }

    // Identifiers keep the historical
    // "\(eventId)-\(kind)-\(userId)" shape so `cancelBriefingTrio`'s
    // event-id prefix sweep still catches pre-fix pending requests.
    runner.run("briefing reconcile: identifiers match the legacy format") {
        let eventId = UUID(), userId = UUID()
        runner.assertEqual(
            BriefingReconciler.identifier(
                eventId: eventId, kindRaw: "on_create", userId: userId
            ),
            "\(eventId.uuidString)-on_create-\(userId.uuidString)"
        )
        runner.assertEqual(
            BriefingReconciler.identifier(
                eventId: eventId, kindRaw: "t48h", userId: userId
            ),
            "\(eventId.uuidString)-t48h-\(userId.uuidString)"
        )
    }

    // The UserDefaults fired-ledger round-trips and isolates per
    // (event, user).
    runner.run("UserDefaultsOnCreateLedger round-trip") {
        let suite = "test-oncreate-ledger-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let ledger = UserDefaultsOnCreateLedger(defaults: defaults)

        let event1 = UUID(), event2 = UUID(), user1 = UUID(), user2 = UUID()
        runner.assertFalse(ledger.hasFiredOnCreate(eventId: event1, userId: user1))
        ledger.markOnCreateFired(eventId: event1, userId: user1)
        runner.assertTrue(ledger.hasFiredOnCreate(eventId: event1, userId: user1))
        runner.assertFalse(ledger.hasFiredOnCreate(eventId: event1, userId: user2))
        runner.assertFalse(ledger.hasFiredOnCreate(eventId: event2, userId: user1))
        defaults.removePersistentDomain(forName: suite)
    }

    // Audit 04 D1 — the add is awaited. The fake sink suspends once
    // inside `add`; a detached add (the pre-fix shape) would leave
    // `pending` empty at the moment `reconcile` returns, so a claim
    // followed by a mute in the same second cancelled nothing.
    runner.runAsync("briefing reconcile: every add lands before reconcile returns") {
        let sink = FakeBriefingSink()
        sink.yieldsOnAdd = true
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        await runBriefingReconcile(
            sink: sink, ledger: ledger, state: .unclaimed,
            eventId: eventId, userId: userId,
            now: brNow, playedAt: brPlayedAt
        )
        runner.assertEqual(sink.pending.count, 4)
        runner.assertEqual(sink.log.filter { $0.hasPrefix("add:") }.count, 4)
    }

    // Audit 04 D1 — the ordered log. Across claim → mute-while-claimed
    // → decline, no `remove` may precede the matching `add`: a cancel
    // that runs before its request exists is the bug.
    runner.runAsync("briefing reconcile: remove never precedes a matching add") {
        let sink = FakeBriefingSink()
        sink.yieldsOnAdd = true
        let ledger = FakeOnCreateLedger()
        let eventId = UUID(), userId = UUID()

        // Scheduled as unclaimed, then claimed, then declined — the
        // claim → mute → decline sequence in one sitting.
        for state in [MemberRSVPState.unclaimed, .claimed, .declined] {
            await runBriefingReconcile(
                sink: sink, ledger: ledger, state: state,
                eventId: eventId, userId: userId,
                now: brNow, playedAt: brPlayedAt
            )
        }
        runner.assertFalse(
            sink.hasRemoveBeforeMatchingAdd(),
            "a removal landed before the request it cancels: \(sink.log)"
        )
        runner.assertEqual(sink.pending.count, 0)
    }
}

