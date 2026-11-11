//
//  TestsQuestionDepth.swift
//  games-room
//
//  Task 2 (1.2.5 room dynamics): one deeper Question Box question per
//  night, and the floor goes to newer members first. Pins
//  `QuestionBoxPacing` and `QuestionBoxReaderPick` (Models/QuestionBox.swift),
//  the deeper house deck, and the in-memory store that mirrors the
//  server twin `question_box_advance` (migration 118).
//  Registered from main.swift through `runQuestionDepthTests(runner)`.
//

import Foundation

func runQuestionDepthTests(_ runner: TestRunner) {
    func qdUUID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Pacing

    runner.run("Question depth: the night opens light and serves one deeper question once") {
        struct Row {
            let name: String
            let isOpener: Bool
            let turnsServed: Int
            let deepServed: Bool
            let minutesIn: Int
            let expected: QuestionDepth
        }
        let rows: [Row] = [
            Row(name: "opener, even late",          isOpener: true,  turnsServed: 0, deepServed: false, minutesIn: 90, expected: .light),
            Row(name: "turn 2, early",              isOpener: false, turnsServed: 1, deepServed: false, minutesIn: 20, expected: .light),
            Row(name: "turn 3, early",              isOpener: false, turnsServed: 2, deepServed: false, minutesIn: 40, expected: .light),
            Row(name: "turn 4, early",              isOpener: false, turnsServed: 3, deepServed: false, minutesIn: 50, expected: .deep),
            Row(name: "turn 2 at 59 min",           isOpener: false, turnsServed: 1, deepServed: false, minutesIn: 59, expected: .light),
            Row(name: "turn 2 at 60 min",           isOpener: false, turnsServed: 1, deepServed: false, minutesIn: 60, expected: .deep),
            Row(name: "after the deeper one",       isOpener: false, turnsServed: 4, deepServed: true,  minutesIn: 80, expected: .light),
            Row(name: "after the deeper one, late", isOpener: false, turnsServed: 9, deepServed: true,  minutesIn: 200, expected: .light),
        ]
        for row in rows {
            let got = QuestionBoxPacing.depth(
                isOpener: row.isOpener,
                turnsServed: row.turnsServed,
                deepServedTonight: row.deepServed,
                playedAt: t0,
                now: t0.addingTimeInterval(TimeInterval(row.minutesIn * 60))
            )
            runner.assertTrue(got == row.expected, row.name)
        }
        runner.assertEqual(QuestionBoxPacing.warmUpTurns, 3)
        runner.assertEqual(QuestionBoxPacing.warmUpMinutes, 60)
    }

    runner.run("Question depth: a whole night has exactly one deeper question, never before turn 4 or 60 min") {
        // Walk a 4-hour night at a 20-minute cadence, opener at 30 min.
        for openerAt in [0, 30] {
            var deepTurns: [Int] = []
            var served = 0
            var deepServed = false
            var minute = openerAt
            while minute <= 240 {
                let depth = QuestionBoxPacing.depth(
                    isOpener: served == 0, turnsServed: served, deepServedTonight: deepServed,
                    playedAt: t0, now: t0.addingTimeInterval(TimeInterval(minute * 60))
                )
                served += 1
                if depth == .deep {
                    deepTurns.append(served)
                    deepServed = true
                    runner.assertTrue(served >= 4 || minute >= 60, "deeper too early: turn \(served) at \(minute) min")
                }
                minute += 20
            }
            runner.assertTrue(deepTurns.count == 1, "opener at \(openerAt) min")
        }
    }

    // MARK: Reader pick

    runner.run("Question depth: the reader pick favours newer members and never repeats") {
        let regular = qdUUID(1), newcomer = qdUUID(2), mid = qdUUID(3), host = qdUUID(9)
        struct Row {
            let name: String
            let rotation: [UUID]
            let cursor: Int
            let last: UUID?
            let reads: [UUID: Int]
            let nights: [UUID: Int]
            let unreachable: Set<UUID>
            let expected: UUID?
            let nextCursor: Int?
        }
        let rows: [Row] = [
            Row(name: "first-night member beats a 10-night regular",
                rotation: [regular, newcomer], cursor: 0, last: host,
                reads: [:], nights: [regular: 10, newcomer: 0], unreachable: [],
                expected: newcomer, nextCursor: 0),
            Row(name: "everyone equal keeps the old order",
                rotation: [regular, newcomer, mid], cursor: 1, last: host,
                reads: [:], nights: [:], unreachable: [],
                expected: newcomer, nextCursor: 2),
            Row(name: "everyone equal wraps from the cursor",
                rotation: [regular, newcomer, mid], cursor: 2, last: host,
                reads: [:], nights: [regular: 4, newcomer: 4, mid: 4], unreachable: [],
                expected: mid, nextCursor: 0),
            Row(name: "never the last reader, even the newest",
                rotation: [regular, newcomer], cursor: 0, last: newcomer,
                reads: [newcomer: 1], nights: [regular: 10, newcomer: 0], unreachable: [],
                expected: regular, nextCursor: 1),
            Row(name: "the floor once each before anyone twice",
                rotation: [regular, newcomer, mid], cursor: 0, last: mid,
                reads: [newcomer: 1, mid: 1], nights: [regular: 10, newcomer: 0, mid: 3], unreachable: [],
                expected: regular, nextCursor: 1),
            Row(name: "second round goes newest first again",
                rotation: [regular, newcomer, mid], cursor: 1, last: regular,
                reads: [regular: 1, newcomer: 1, mid: 1], nights: [regular: 10, newcomer: 0, mid: 3], unreachable: [],
                expected: newcomer, nextCursor: 2),
            Row(name: "an unreachable member is skipped",
                rotation: [regular, newcomer], cursor: 0, last: host,
                reads: [:], nights: [regular: 10, newcomer: 0], unreachable: [newcomer],
                expected: regular, nextCursor: 1),
            Row(name: "only the last reader is left: no turn",
                rotation: [newcomer], cursor: 0, last: newcomer,
                reads: [newcomer: 1], nights: [:], unreachable: [],
                expected: nil, nextCursor: nil),
            Row(name: "empty rotation: no turn",
                rotation: [], cursor: 0, last: nil,
                reads: [:], nights: [:], unreachable: [],
                expected: nil, nextCursor: nil),
        ]
        for row in rows {
            let pick = QuestionBoxReaderPick.pick(
                rotation: row.rotation, cursor: row.cursor, lastReader: row.last,
                readsTonight: row.reads, nightsAttended: row.nights,
                reachable: { !row.unreachable.contains($0) }
            )
            runner.assertTrue(pick?.reader == row.expected, row.name)
            runner.assertTrue(pick?.nextCursor == row.nextCursor, row.name + " (cursor)")
        }
    }

    runner.run("Question depth: a table of equals reads in exactly the old round-robin order") {
        let rot = [qdUUID(1), qdUUID(2), qdUUID(3), qdUUID(4)]
        var cursor = 0
        var last: UUID? = qdUUID(9)
        var reads: [UUID: Int] = [:]
        var order: [UUID] = []
        for _ in 0..<8 {
            guard let pick = QuestionBoxReaderPick.pick(
                rotation: rot, cursor: cursor, lastReader: last, readsTonight: reads
            ) else { break }
            order.append(pick.reader)
            reads[pick.reader, default: 0] += 1
            last = pick.reader
            cursor = pick.nextCursor
        }
        runner.assertEqual(order, rot + rot)
    }

    // MARK: The deeper deck

    runner.run("Question depth: 20 deeper house questions, short, plain, and the same as migration 118") {
        let deck = QuestionBoxDeepDeck.entries
        runner.assertEqual(deck.count, 20)
        runner.assertTrue(Set(deck).count == 20, "no duplicates")
        runner.assertTrue(deck.allSatisfy { $0.count <= RoomQuestion.maxLength }, "fits the 140 cap")
        runner.assertTrue(deck.allSatisfy { $0.hasSuffix("?") }, "every one is a question")
        runner.assertFalse(deck.contains { $0.contains("\u{2014}") || $0.contains("\u{2013}") }, "no em or en dashes")
        let light = Set(QuestionBoxHouseDeck.entries.map(\.text))
        runner.assertTrue(deck.allSatisfy { !light.contains($0) }, "not already in the light deck")
        let sql = try String(contentsOfFile: "Supabase/migrations/118_question_box_depth.sql", encoding: .utf8)
        for (i, text) in deck.enumerated() {
            let row = "(\(i + 1), '\(text.replacingOccurrences(of: "'", with: "''"))')"
            runner.assertTrue(sql.contains(row), "migration 118 row \(i + 1) matches: \(text)")
        }
    }

    runner.run("Question depth: older servers with no depth decode as light") {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","room_id":"00000000-0000-0000-0000-000000000002",
         "event_id":null,"source":"host","text":"Hi?","tag":null,"drawn_at":null,
         "created_at":"2026-11-10T10:00:00Z","author_id":null,"author_display_name":null}
        """
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let old = try dec.decode(RoomQuestion.self, from: Data(json.utf8))
        runner.assertEqual(old.depth, .light)
        let deep = try dec.decode(RoomQuestion.self, from: Data(json.replacingOccurrences(
            of: "\"tag\":null", with: "\"tag\":null,\"depth\":\"deep\"").utf8))
        runner.assertEqual(deep.depth, .deep)
    }

    // MARK: The in-memory store (what the sweep drives)

    runner.runAsync("Question depth: the in-memory box serves one deeper question at turn 4 and hands the floor to the newcomer") {
        let saved = InMemoryQuestionBoxState.secondsPerMinute
        InMemoryQuestionBoxState.secondsPerMinute = 0.0005
        defer { InMemoryQuestionBoxState.secondsPerMinute = saved }

        let store = InMemoryRoomStore()
        let room = try await store.fetchRooms().first!
        if let seeded = try await store.fetchActiveEvent(roomId: room.id) {
            try await store.cancelEvent(eventId: seeded.id)
        }
        let eventId = try await store.addEvent(
            roomId: room.id, name: "Tonight", playedAt: Date().addingTimeInterval(-300),
            packSlugs: ["casino"], hiddenFromUserIds: []
        )
        let host = await store.qbCurrentMemberId()
        let regular = qdUUID(501), newcomer = qdUUID(502)
        await store.seedQuestionBoxTable(
            eventId: eventId, roomId: room.id,
            withdrawals: [
                .init(memberId: regular, at: Date().addingTimeInterval(-200)),
                .init(memberId: newcomer, at: Date().addingTimeInterval(-100)),
                .init(memberId: host, at: Date().addingTimeInterval(-50)),
            ],
            nightsAttended: [regular: 10, newcomer: 0, host: 12]
        )
        // A host's own deeper question goes before the house's.
        _ = try await store.upsertRoomQuestion(
            roomId: room.id, id: nil, text: "What are you quietly proud of?", tag: nil, depth: .deep)
        _ = try await store.upsertRoomQuestion(
            roomId: room.id, id: nil, text: "Best pie in town?", tag: nil, depth: nil)

        for _ in 0..<6 {
            try await Task.sleep(nanoseconds: 30_000_000)
            try await store.questionBoxTick(eventId: eventId)
        }
        let turns = await store.questionBoxServedTurns(eventId: eventId)
        runner.assertEqual(turns.count, 6)
        runner.assertEqual(turns.map(\.depth), [.light, .light, .light, .deep, .light, .light])
        runner.assertEqual(turns.first?.kind, "opener")
        runner.assertEqual(turns.first?.reader, host)
        runner.assertTrue(turns.dropFirst().first?.reader == newcomer, "the first-night member reads first")
        for i in 1..<turns.count {
            runner.assertTrue(turns[i].reader != turns[i - 1].reader, "no back-to-back reader at turn \(i + 1)")
        }
        let questions = try await store.fetchRoomQuestions(roomId: room.id)
        runner.assertTrue(
            questions.first { $0.text == "What are you quietly proud of?" }?.drawnAt != nil,
            "the host's deeper question was the one served")
        runner.assertTrue(questions.first { $0.text == "Best pie in town?" }?.depth == .light, "added questions default to light")
    }
}
