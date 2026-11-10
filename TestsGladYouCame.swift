//
//  TestsGladYouCame.swift
//  games-room
//
//  1.2.5 Task 4 — "Glad you came": the batched sentence, the delivery
//  time rule (server twin `public.glad_push_deliver_at`, migration
//  119), who may send, who is listed, and the Send-with-Undo machine.
//  Registered from main.swift through `runGladYouCameTests(runner)`.
//  Foundation only.

import Foundation

func runGladYouCameTests(_ runner: TestRunner) {
    let me = UUID(), connor = UUID(), sam = UUID(), jo = UUID(), max = UUID(), outsider = UUID()
    let event = UUID(), otherEvent = UUID()
    let names = [me: "Nathan", connor: "Connor", sam: "Sam", jo: "Jo", max: "Max"]
    let brisbane = TimeZone(identifier: "Australia/Brisbane")!
    let sydney = TimeZone(identifier: "Australia/Sydney")!

    func eq<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
        runner.assertTrue(actual == expected, "\(message): got \(actual), want \(expected)")
    }
    func rsvp(_ id: UUID, _ state: MemberRSVPState = .claimed) -> EventRSVP {
        EventRSVP(eventId: event, memberId: id, displayName: names[id] ?? "?", state: state)
    }
    /// A wall-clock instant in `zone`.
    func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ zone: TimeZone) -> Date {
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d; c.hour = h; c.minute = mi
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: c)!
    }

    // MARK: The sentence (batching copy) — the same table pins glad-push

    runner.run("Glad: batching copy for 1, 2, 3 and 4 senders") {
        let table: [([String], String?)] = [
            ([], nil),
            (["Connor"], "Connor was glad you came."),
            (["Connor", "Sam"], "Connor and Sam were glad you came."),
            (["Connor", "Sam", "Jo"], "Connor, Sam and Jo were glad you came."),
            (["Connor", "Sam", "Jo", "Max"], "Connor, Sam and 2 others were glad you came."),
            (["Connor", "Sam", "Jo", "Max", "Ali"], "Connor, Sam and 3 others were glad you came."),
        ]
        for (input, expected) in table {
            eq(GladYouCame.line(senderNames: input), expected, "\(input)")
        }
    }

    runner.run("Glad: blank names are dropped, never 'Someone'") {
        runner.assertEqual(GladYouCame.line(senderNames: ["  ", "Sam"]), "Sam was glad you came.")
        runner.assertNil(GladYouCame.line(senderNames: ["", " "]))
    }

    runner.run("Glad: copy is AU casual, no em dash, no emoji, no number of anything but 'others'") {
        let lines = [
            GladYouCame.prompt,
            GladYouCame.line(senderNames: ["A"])!,
            GladYouCame.line(senderNames: ["A", "B", "C", "D"])!,
            GladYouCame.sentLine(names: ["A", "B"])!,
        ]
        for l in lines {
            runner.assertFalse(l.contains("\u{2014}"), "em dash in \(l)")
            runner.assertFalse(l.unicodeScalars.contains { $0.properties.isEmojiPresentation }, "emoji in \(l)")
        }
        runner.assertEqual(GladYouCame.prompt, "Who were you glad to see?")
    }

    // MARK: Delivery time — settle at 13:00, 21:30, 23:30 (+ edges)

    runner.run("Glad: push time — 13:00 / 21:30 / 23:30 and the edges, in the room's zone") {
        let z = brisbane
        let table: [(settled: Date, expected: Date, why: String)] = [
            (local(2026, 11, 13, 13, 0, z), local(2026, 11, 13, 14, 0, z), "13:00 -> next whole hour"),
            (local(2026, 11, 13, 21, 30, z), local(2026, 11, 14, 9, 0, z), "21:30 -> 22:00 is quiet, so 09:00"),
            (local(2026, 11, 13, 23, 30, z), local(2026, 11, 14, 9, 0, z), "23:30 -> next morning 09:00"),
            (local(2026, 11, 14, 0, 45, z), local(2026, 11, 14, 9, 0, z), "after midnight -> 09:00 that morning"),
            (local(2026, 11, 13, 8, 59, z), local(2026, 11, 13, 9, 0, z), "08:59 -> 09:00"),
            (local(2026, 11, 13, 9, 0, z), local(2026, 11, 13, 10, 0, z), "09:00 -> 10:00"),
            (local(2026, 11, 13, 20, 59, z), local(2026, 11, 13, 21, 0, z), "20:59 -> 21:00, the last slot"),
            (local(2026, 11, 13, 21, 0, z), local(2026, 11, 14, 9, 0, z), "21:00 -> 22:00 is quiet"),
            (local(2026, 11, 13, 22, 0, z), local(2026, 11, 14, 9, 0, z), "22:00 -> next morning"),
        ]
        for row in table {
            let got = GladPushTime.deliverAt(settledAt: row.settled, timeZone: z)
            eq(got, row.expected, row.why)
            runner.assertFalse(GladPushTime.isQuiet(got, timeZone: z), "landed in quiet hours: \(row.why)")
        }
    }

    runner.run("Glad: push time follows the room's zone, not the phone's or UTC") {
        // The same instant is 23:30 in Sydney (AEDT, +11) and 22:30 in
        // Brisbane (+10): both wait for 09:00 in their own zone.
        let settled = local(2026, 11, 13, 23, 30, sydney)
        runner.assertEqual(GladPushTime.deliverAt(settledAt: settled, timeZone: sydney), local(2026, 11, 14, 9, 0, sydney))
        runner.assertEqual(GladPushTime.deliverAt(settledAt: settled, timeZone: brisbane), local(2026, 11, 14, 9, 0, brisbane))
        // 13:00 Brisbane is 14:00 Sydney: each gets its own next hour.
        let lunch = local(2026, 11, 13, 13, 0, brisbane)
        runner.assertEqual(GladPushTime.deliverAt(settledAt: lunch, timeZone: sydney), local(2026, 11, 13, 15, 0, sydney))
    }

    runner.run("Glad: the delivery is never inside 22:00 to 08:00, for every minute of a day") {
        let start = local(2026, 11, 13, 0, 0, brisbane)
        for minute in stride(from: 0, to: 24 * 60, by: 7) {
            let settled = start.addingTimeInterval(TimeInterval(minute * 60))
            let at = GladPushTime.deliverAt(settledAt: settled, timeZone: brisbane)
            runner.assertFalse(GladPushTime.isQuiet(at, timeZone: brisbane), "minute \(minute)")
            runner.assertTrue(at >= settled, "never before the settle, minute \(minute)")
            runner.assertTrue(at.timeIntervalSince(settled) <= 12 * 3_600, "never more than a night away, minute \(minute)")
        }
    }

    // MARK: Who can send, and who is listed

    runner.run("Glad: only a seated viewer, only in the recap window, can send") {
        for phase in [NightPhase.none, .upcoming, .live, .stranded, .recap, .past, .cancelled] {
            eq(GladYouCame.canSend(phase: phase, viewerHadSeat: true), phase == .recap, "\(phase) seated")
            runner.assertFalse(GladYouCame.canSend(phase: phase, viewerHadSeat: false), "\(phase) unseated")
        }
        let rsvps = [rsvp(me), rsvp(connor), rsvp(sam, .declined)]
        runner.assertTrue(GladYouCame.hadSeat(me, rsvps: rsvps))
        runner.assertFalse(GladYouCame.hadSeat(sam, rsvps: rsvps), "declined is no seat")
        runner.assertFalse(GladYouCame.hadSeat(outsider, rsvps: rsvps), "no row is no seat")
        runner.assertFalse(GladYouCame.hadSeat(nil, rsvps: rsvps))
    }

    runner.run("Glad: the window closes with the recap (24 h), via NightPhaseResolver") {
        let settled = local(2026, 11, 13, 22, 0, brisbane)
        let played = settled.addingTimeInterval(-3 * 3_600)
        func phase(hoursAfter h: Double) -> NightPhase {
            NightPhaseResolver.phase(NightFacts(playedAt: played, settledAt: settled, now: settled.addingTimeInterval(h * 3_600)))
        }
        runner.assertTrue(GladYouCame.canSend(phase: phase(hoursAfter: 23.9), viewerHadSeat: true))
        runner.assertFalse(GladYouCame.canSend(phase: phase(hoursAfter: 24), viewerHadSeat: true), "exactly 24 h is past")
    }

    runner.run("Glad: the sheet lists that night's table, never the viewer, never the unseated") {
        let rsvps = [rsvp(connor), rsvp(me), rsvp(sam, .declined), rsvp(jo), rsvp(max, .unclaimed), rsvp(connor)]
        runner.assertEqual(GladYouCame.table(rsvps: rsvps, viewerId: me).map(\.memberId), [connor, jo])
    }

    runner.run("Glad: sending twice to the same person does nothing") {
        let table = GladYouCame.table(rsvps: [rsvp(connor), rsvp(sam), rsvp(jo), rsvp(me)], viewerId: me)
        let told = GladYouCame.alreadyTold(
            notes: [
                GladNote(eventId: event, fromUser: me, toUser: connor),
                GladNote(eventId: otherEvent, fromUser: me, toUser: sam),   // another night
                GladNote(eventId: event, fromUser: jo, toUser: sam),        // someone else's row
            ],
            eventId: event, viewerId: me
        )
        runner.assertEqual(told, [connor])
        runner.assertEqual(
            GladYouCame.toSend(picked: [connor, sam, me], alreadyTold: told, table: table, viewerId: me),
            [sam]
        )
        runner.assertEqual(GladYouCame.toSend(picked: [connor], alreadyTold: told, table: table, viewerId: me), [])
    }

    runner.run("Glad: the recipient's line names their senders in send order, nothing else") {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let notes = [
            GladNote(eventId: event, fromUser: sam, toUser: me, createdAt: t.addingTimeInterval(60)),
            GladNote(eventId: event, fromUser: connor, toUser: me, createdAt: t),
            GladNote(eventId: event, fromUser: me, toUser: jo, createdAt: t),          // my own sent row
            GladNote(eventId: otherEvent, fromUser: jo, toUser: me, createdAt: t),     // another night
            GladNote(eventId: event, fromUser: outsider, toUser: me, createdAt: t),    // nameless: skipped
        ]
        runner.assertEqual(
            GladYouCame.receivedLine(notes: notes, eventId: event, viewerId: me, names: names),
            "Connor and Sam were glad you came."
        )
        // Jo sees only the row addressed to Jo; a third party sees nothing.
        runner.assertEqual(
            GladYouCame.receivedLine(notes: notes, eventId: event, viewerId: jo, names: names),
            "Nathan was glad you came."
        )
        runner.assertNil(GladYouCame.receivedLine(notes: notes, eventId: event, viewerId: max, names: names))
        runner.assertNil(GladYouCame.receivedLine(notes: [], eventId: event, viewerId: me, names: names))
    }

    // MARK: Send with Undo

    runner.run("Glad: Send is optimistic with Undo, nothing goes out while undoing") {
        var p = GladSendPhase.idle
        p = p.reduce(.send([connor, sam]))
        runner.assertEqual(p, .undoing([connor, sam]))
        runner.assertTrue(p.canUndo)
        eq(p.pendingOrSent, [connor, sam], "reads as sent from the first tap")
        runner.assertEqual(p.reduce(.undo), .idle)
        p = p.reduce(.commitStarted)
        runner.assertEqual(p, .committing([connor, sam]))
        runner.assertFalse(p.canUndo, "no Undo once the write is out")
        eq(p.reduce(.undo), p, "undo while committing is ignored")
        eq(p.reduce(.send([jo])), p, "a second send while committing is ignored")
        runner.assertEqual(p.reduce(.succeeded), .sent([connor, sam]))
        runner.assertEqual(p.reduce(.failed), .failed([connor, sam]))
        eq(GladSendPhase.failed([sam]).pendingOrSent, [], "a failure does not read as sent")
        eq(GladSendPhase.idle.reduce(.send([])), .idle, "an empty send is no send")
        runner.assertEqual(GladSendPhase.idle.reduce(.commitStarted), .idle)
    }
}
