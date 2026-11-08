//
//  TestsS2.swift
//  GamesRoom
//
//  Lane S2 tests: calendar-anchored reminder times (step 2 of the
//  lane brief, audit 01 #4, #5, #6) and the on-create delivery
//  contract (step 3, audit 01 #2, #20).
//
//  Every date here is a local date-time built with the device's
//  calendar, and every assertion is an exact local stamp, so the
//  tests hold in any time zone.
//

import Foundation

func runS2Tests() {
    let cal = Calendar.current

    func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        guard let date = cal.date(from: comps) else {
            fatalError("TestsS2: could not build \(year)-\(month)-\(day) \(hour):\(minute)")
        }
        return date
    }

    /// Local date-time stamp, e.g. "2026-06-20 18:00".
    func stamp(_ date: Date) -> String {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
    }

    func planFor(playedAt: Date, now: Date) -> [PlannedBriefingNotification] {
        BriefingReconciler.plan(
            eventId: UUID(),
            eventName: "Friday Night Hold'em",
            playedAt: playedAt,
            mascotName: "Ace",
            userId: UUID(),
            memberName: "Nathan",
            state: .claimed,
            includeOnCreate: false,
            now: now,
            calendar: cal
        )
    }

    func slot(
        _ planned: [PlannedBriefingNotification], _ kindRaw: String
    ) -> Date? {
        planned.first { $0.kindRaw == kindRaw }?.fireAt
    }

    func assertSlot(
        _ planned: [PlannedBriefingNotification],
        _ kindRaw: String,
        equals expected: String,
        _ message: String
    ) {
        guard let date = slot(planned, kindRaw) else {
            runner.assertTrue(false, "\(message): expected a \(kindRaw) slot, found none")
            return
        }
        runner.assertTrue(
            stamp(date) == expected,
            "\(message): \(kindRaw) fire time is \(stamp(date)), expected \(expected)"
        )
    }

    func assertNoSlot(
        _ planned: [PlannedBriefingNotification],
        _ kindRaw: String,
        _ message: String
    ) {
        runner.assertNil(slot(planned, kindRaw), "\(message): no \(kindRaw) slot expected")
    }

    // Case (a): Saturday 14:00 event, created 14 days earlier at
    // 10:00. The three slots land on the prior Saturday evening,
    // the Wednesday evening and the Saturday morning.
    runner.run("S2 reminder times: week-before, few-days and morning-of anchor to the calendar") {
        let event = at(2026, 6, 20, 14, 0)      // Saturday 14:00
        let onCreate = at(2026, 6, 6, 10, 0)    // 14 days earlier, 10:00
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 3)
        assertSlot(
            planned, BriefingReconciler.t168hKindRaw,
            equals: "2026-06-13 18:00", "case a"
        )
        assertSlot(
            planned, BriefingReconciler.t84hKindRaw,
            equals: "2026-06-17 18:00", "case a"
        )
        assertSlot(
            planned, BriefingReconciler.morningOfKindRaw,
            equals: "2026-06-20 09:00", "case a"
        )
    }

    // Case (b): Friday 08:00 event. The morning-of cannot be three
    // hours before the start (that is 05:00), so it floors at 07:00.
    runner.run("S2 reminder times: an 08:00 event floors the morning-of at 07:00") {
        let event = at(2026, 6, 19, 8, 0)       // Friday 08:00
        let onCreate = at(2026, 6, 11, 10, 0)   // 8 days earlier, 10:00
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 3)
        assertSlot(
            planned, BriefingReconciler.t168hKindRaw,
            equals: "2026-06-12 18:00", "case b"
        )
        assertSlot(
            planned, BriefingReconciler.t84hKindRaw,
            equals: "2026-06-16 18:00", "case b"
        )
        assertSlot(
            planned, BriefingReconciler.morningOfKindRaw,
            equals: "2026-06-19 07:00", "case b"
        )
    }

    // Case (c): Friday 19:30 event created Tuesday 09:00 the same
    // week. The week-before slot is already behind us, the
    // few-days slot (Tuesday 18:00) lands inside the on-create
    // prompt's 24-hour window, so only the morning-of survives.
    runner.run("S2 reminder times: a short-notice event keeps only the morning-of") {
        let event = at(2026, 6, 19, 19, 30)     // Friday 19:30
        let onCreate = at(2026, 6, 16, 9, 0)    // Tuesday 09:00, same week
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 1)
        assertNoSlot(planned, BriefingReconciler.t168hKindRaw, "case c")
        assertNoSlot(planned, BriefingReconciler.t84hKindRaw, "case c")
        assertSlot(
            planned, BriefingReconciler.morningOfKindRaw,
            equals: "2026-06-19 09:00", "case c"
        )
    }

    // Case (d): an event created 85 hours before the start. The
    // few-days slot (Wednesday 18:00) falls 17 hours after the
    // on-create prompt, inside its 24-hour window, so it is
    // dropped rather than fired.
    runner.run("S2 reminder times: an event created 85h out drops the few-days reminder") {
        let event = at(2026, 6, 20, 14, 0)      // Saturday 14:00
        let onCreate = at(2026, 6, 17, 1, 0)    // 85 hours earlier
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 1)
        assertNoSlot(planned, BriefingReconciler.t168hKindRaw, "case d")
        assertNoSlot(planned, BriefingReconciler.t84hKindRaw, "case d")
        assertSlot(
            planned, BriefingReconciler.morningOfKindRaw,
            equals: "2026-06-20 09:00", "case d"
        )
    }

    // The week-before slot has the same 24-hour guard as the
    // few-days slot: an event created 169 hours out would fire
    // the week-before reminder five hours later.
    runner.run("S2 reminder times: an event created 169h out drops the week-before reminder") {
        let event = at(2026, 6, 27, 14, 0)      // Saturday 14:00
        let onCreate = at(2026, 6, 20, 13, 0)   // 169 hours earlier
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 2)
        assertNoSlot(planned, BriefingReconciler.t168hKindRaw, "case e")
        assertSlot(
            planned, BriefingReconciler.t84hKindRaw,
            equals: "2026-06-24 18:00", "case e"
        )
        assertSlot(
            planned, BriefingReconciler.morningOfKindRaw,
            equals: "2026-06-27 09:00", "case e"
        )
    }

    // The morning-of keeps its own 2-hour guard, so a same-day
    // event does not double-ping an hour after the on-create
    // prompt.
    runner.run("S2 reminder times: a same-day morning-of inside 2h of on-create is dropped") {
        let event = at(2026, 6, 20, 14, 0)      // Saturday 14:00
        let onCreate = at(2026, 6, 20, 8, 0)    // Saturday 08:00
        let planned = planFor(playedAt: event, now: onCreate)

        runner.assertEqual(planned.count, 0)
        assertNoSlot(planned, BriefingReconciler.morningOfKindRaw, "case f")
    }

    // The identifier contract is unchanged: the calendar anchor
    // moved the fire times, not the names.
    runner.run("S2 reminder times: identifiers keep their kinds") {
        let event = at(2026, 6, 20, 14, 0)
        let onCreate = at(2026, 6, 6, 10, 0)
        let planned = planFor(playedAt: event, now: onCreate)

        let kinds = planned.map(\.kindRaw).sorted()
        runner.assertEqual(kinds, ["morning_of", "t168h", "t48h"])
        runner.assertEqual(
            planned.map(\.identifier).filter { $0.contains("-t168h-") }.count, 1
        )
        runner.assertEqual(
            planned.map(\.identifier).filter { $0.contains("-t48h-") }.count, 1
        )
        runner.assertEqual(
            planned.map(\.identifier).filter { $0.contains("-morning_of-") }.count, 1
        )
    }

    // MARK: - Step 3: the on-create prompt actually lands

    // The "now" prompts fire on a one-second interval, so the push
    // lands after its body was built. A calendar trigger computed
    // before the mascot-voice round trip never fires (audit 01 #2).
    runner.run("S2 on-create fires on an interval, the reminders keep their clock time") {
        let fireAt = at(2026, 6, 20, 14, 0)

        runner.assertEqual(
            BriefingReconciler.fireMode(
                kindRaw: BriefingReconciler.onCreateKindRaw, fireAt: fireAt
            ),
            .shortly
        )
        runner.assertEqual(
            BriefingReconciler.fireMode(
                kindRaw: BriefingReconciler.catchUpKindRaw, fireAt: fireAt
            ),
            .shortly
        )
        for kind in [
            BriefingReconciler.t168hKindRaw,
            BriefingReconciler.t84hKindRaw,
            BriefingReconciler.morningOfKindRaw
        ] {
            runner.assertEqual(
                BriefingReconciler.fireMode(kindRaw: kind, fireAt: fireAt),
                .at(fireAt)
            )
        }
    }

    // Every local briefing kind is listed in Notification Center
    // while the app is open; the Question Box turn is not.
    runner.run("S2 briefing kinds are the ones the app lists in Notification Center") {
        for kind in BriefingReconciler.briefingKindRaws {
            runner.assertTrue(
                BriefingReconciler.isBriefingKind(["kind": kind]),
                "\(kind) should be a briefing kind"
            )
        }
        runner.assertFalse(
            BriefingReconciler.isBriefingKind(["type": "question_turn"]),
            "the Question Box turn is not a briefing kind"
        )
        runner.assertFalse(
            BriefingReconciler.isBriefingKind(["type": "anchor_nudge"]),
            "the anchor nudge is not a local briefing kind"
        )
        runner.assertFalse(
            BriefingReconciler.isBriefingKind([:]),
            "an empty payload is not a briefing kind"
        )
    }

    // A tap on a briefing or on the anchor nudge opens the room.
    runner.run("S2 a tapped briefing or anchor nudge routes to its room") {
        let roomId = UUID()
        let eventId = UUID()

        let briefing = BriefingReconciler.tapRoute([
            "kind": BriefingReconciler.onCreateKindRaw,
            "event_id": eventId.uuidString,
            "room_id": roomId.uuidString
        ])
        runner.assertEqual(
            briefing,
            .openRoom(roomId: roomId, eventId: eventId)
        )

        let anchor = BriefingReconciler.tapRoute([
            "type": BriefingReconciler.anchorKindRaw,
            "event_id": eventId.uuidString,
            "room_id": roomId.uuidString
        ])
        runner.assertEqual(
            anchor,
            .openRoom(roomId: roomId, eventId: eventId)
        )

        // A request scheduled before the payload carried a room id
        // still identifies its night.
        let roomless = BriefingReconciler.tapRoute([
            "kind": BriefingReconciler.morningOfKindRaw,
            "event_id": eventId.uuidString
        ])
        runner.assertEqual(
            roomless,
            .openRoom(roomId: nil, eventId: eventId)
        )

        // The Question Box turn is not ours to route.
        runner.assertEqual(
            BriefingReconciler.tapRoute([
                "type": "question_turn",
                "event_id": eventId.uuidString
            ]),
            .none
        )
        // A payload with no event id cannot name a room.
        runner.assertEqual(
            BriefingReconciler.tapRoute([
                "kind": BriefingReconciler.onCreateKindRaw,
                "room_id": roomId.uuidString
            ]),
            .none
        )
    }

    // MARK: - Step 4: the catch-up request id is per event

    // The catch-up id used to be the literal text
    // "\(eventId.uuidString)-catchup" (an escaped interpolation), so
    // every event shared ONE request id: the second night's catch-up
    // replaced the first, and the event-id prefix sweep that cancels
    // an event's cadence never matched it.
    runner.run("S2 catch-up identifiers are per event and stable") {
        let first = UUID()
        let second = UUID()

        let firstId = BriefingReconciler.catchUpIdentifier(eventId: first)
        let secondId = BriefingReconciler.catchUpIdentifier(eventId: second)

        runner.assertTrue(
            firstId != secondId,
            "two events must not share a catch-up identifier"
        )
        runner.assertEqual(firstId, "\(first.uuidString)-catchup")
        runner.assertEqual(secondId, "\(second.uuidString)-catchup")
        runner.assertEqual(
            BriefingReconciler.catchUpIdentifier(eventId: first),
            firstId
        )
        // The id carries the event id as its prefix, so the cadence
        // sweep that cancels an event's pending requests takes the
        // catch-up with it.
        runner.assertTrue(
            firstId.hasPrefix(first.uuidString),
            "the catch-up identifier must start with the event id"
        )
    }

    // MARK: - Step 5: foreground purge decisions

    runner.run("S2 removed rooms are the ones missing from the fresh list") {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        runner.assertEqual(
            BriefingReconciler.removedRoomIds(old: [a, b, c], new: [c, a, d]),
            [b]
        )
        runner.assertEqual(BriefingReconciler.removedRoomIds(old: [], new: [a]), [])
        runner.assertEqual(BriefingReconciler.removedRoomIds(old: [a, b], new: [a, b]), [])
        runner.assertEqual(
            BriefingReconciler.removedRoomIds(old: [a, b, a], new: []),
            [a, b]
        )
    }

    runner.run("S2 a request belongs to a room by room id or by one of its events") {
        let room = UUID(), other = UUID(), event = UUID(), otherEvent = UUID()
        runner.assertTrue(
            BriefingReconciler.requestBelongsToRoom(
                userInfo: ["room_id": room.uuidString, "event_id": otherEvent.uuidString],
                roomId: room, eventIds: []
            ),
            "the payload room id matches"
        )
        runner.assertTrue(
            BriefingReconciler.requestBelongsToRoom(
                userInfo: ["kind": "t48h", "event_id": event.uuidString],
                roomId: room, eventIds: [event]
            ),
            "a request without a room id matches by its event"
        )
        runner.assertTrue(
            !BriefingReconciler.requestBelongsToRoom(
                userInfo: ["room_id": other.uuidString, "event_id": otherEvent.uuidString],
                roomId: room, eventIds: [event]
            ),
            "another room's request is left alone"
        )
        runner.assertTrue(
            !BriefingReconciler.requestBelongsToRoom(
                userInfo: ["kind": "question_box_turn"],
                roomId: room, eventIds: [event]
            ),
            "a request with no room or event is left alone"
        )
    }
}
