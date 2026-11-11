//
//  TestsNextNight.swift
//  games-room
//
//  1.2.5 Task 1 — "Same time next Tuesday?" at settle, and the recap
//  that ends on a person. Registered from main.swift through
//  `runNextNightTests(runner)`. Foundation only; every case drives the
//  production types in `GamesRoom/Models/NextNight.swift`.
//

import Foundation

func runNextNightTests(_ runner: TestRunner) {
    runNextNightDateTests(runner)
    runNextNightOfferTests(runner)
    runNextNightBookingTests(runner)
    runRecapClosingTests(runner)
    runRecapLayoutTests(runner)
}

// MARK: - Fixtures

private let sydney = TimeZone(identifier: "Australia/Sydney")!
private let brisbane = TimeZone(identifier: "Australia/Brisbane")!

/// A wall-clock time in `tz`.
private func nnDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ tz: TimeZone) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    return calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func nnWall(_ date: Date, _ tz: TimeZone) -> DateComponents {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = tz
    return calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
}

private func nnSettled(playedAt: Date, packs: [String] = ["casino"]) -> Event {
    Event(
        id: UUID(), roomId: UUID(), name: "night",
        playedAt: playedAt, createdAt: playedAt.addingTimeInterval(-86_400),
        settledAt: playedAt.addingTimeInterval(3 * 3_600),
        packSlugs: packs, packSlug: packs.first ?? "casino"
    )
}

private func nnOffer(_ tz: TimeZone = brisbane) -> NextNightOffer {
    let night = nnSettled(playedAt: nnDate(2026, 11, 10, 19, 0, tz))
    return NextNightOffer.offer(
        settled: night, isHost: true, hasFutureNight: false, settleInFlight: false,
        now: nnDate(2026, 11, 10, 23, 0, tz), timeZone: tz
    )!
}

// MARK: - Same time next week

private func runNextNightDateTests(_ runner: TestRunner) {
    // (label, settled start (wall clock), expected next start (wall clock), tz)
    let rows: [(String, (Int, Int, Int, Int, Int), (Int, Int, Int, Int, Int), TimeZone)] = [
        ("plain week", (2026, 11, 10, 19, 0), (2026, 11, 17, 19, 0), brisbane),
        ("month end", (2026, 10, 30, 19, 0), (2026, 11, 6, 19, 0), brisbane),
        ("year end", (2026, 12, 29, 19, 30), (2027, 1, 5, 19, 30), brisbane),
        ("DST starts (AEST to AEDT)", (2026, 9, 29, 19, 0), (2026, 10, 6, 19, 0), sydney),
        ("DST ends (AEDT to AEST)", (2026, 4, 1, 19, 0), (2026, 4, 8, 19, 0), sydney),
        ("DST and month end together", (2026, 9, 30, 20, 0), (2026, 10, 7, 20, 0), sydney),
    ]
    for (label, from, to, tz) in rows {
        runner.run("NextNight: same time next week keeps the wall clock — \(label)") {
            let start = nnDate(from.0, from.1, from.2, from.3, from.4, tz)
            let next = NextNightOffer.sameTimeNextWeek(after: start, timeZone: tz)!
            let wall = nnWall(next, tz)
            runner.assertEqual(wall.year, to.0)
            runner.assertEqual(wall.month, to.1)
            runner.assertEqual(wall.day, to.2)
            runner.assertEqual(wall.hour, to.3)
            runner.assertEqual(wall.minute, to.4)
            runner.assertEqual(wall.weekday, nnWall(start, tz).weekday)
        }
    }

    runner.run("NextNight: across DST the gap is 7 days less the hour, not 7 x 24h") {
        let start = nnDate(2026, 9, 29, 19, 0, sydney)
        let next = NextNightOffer.sameTimeNextWeek(after: start, timeZone: sydney)!
        runner.assertEqual(next.timeIntervalSince(start), 7 * 86_400 - 3_600)
    }

    runner.run("NextNight: the weekday is the room's, not UTC's") {
        // Wed 7am in Brisbane is Tue 9pm UTC.
        let night = nnSettled(playedAt: nnDate(2026, 11, 11, 7, 0, brisbane))
        let offer = NextNightOffer.offer(
            settled: night, isHost: true, hasFutureNight: false, settleInFlight: false,
            now: nnDate(2026, 11, 11, 11, 0, brisbane), timeZone: brisbane
        )
        runner.assertEqual(offer?.weekday, "Wednesday")
        runner.assertEqual(offer?.prompt, "Same time next Wednesday?")
    }

    runner.run("NextNight: the closing line reads like a person said it") {
        let tue = nnDate(2026, 11, 17, 19, 0, brisbane)
        runner.assertEqual(NextNightOffer.closingLine(for: tue, timeZone: brisbane), "Next: Tue 17 Nov, 7pm")
        let half = nnDate(2026, 11, 17, 19, 30, brisbane)
        runner.assertEqual(NextNightOffer.closingLine(for: half, timeZone: brisbane), "Next: Tue 17 Nov, 7:30pm")
    }
}

// MARK: - When the prompt shows

private func runNextNightOfferTests(_ runner: TestRunner) {
    let tz = brisbane
    let night = nnSettled(playedAt: nnDate(2026, 11, 10, 19, 0, tz), packs: ["monopoly_deal", "casino", "pluto_chess"])
    let now = nnDate(2026, 11, 10, 23, 0, tz)

    // (label, isHost, hasFutureNight, settleInFlight, now, offered?)
    let rows: [(String, Bool, Bool, Bool, Date, Bool)] = [
        ("host, nothing booked, settled", true, false, false, now, true),
        ("member never sees it", false, false, false, now, false),
        ("a future night is already booked", true, true, false, now, false),
        ("the settle is still in its Undo window", true, false, true, now, false),
        ("same time next week has gone", true, false, false, nnDate(2026, 11, 18, 9, 0, tz), false),
    ]
    for (label, isHost, future, inFlight, at, offered) in rows {
        runner.run("NextNight: the prompt — \(label)") {
            let offer = NextNightOffer.offer(
                settled: night, isHost: isHost, hasFutureNight: future,
                settleInFlight: inFlight, now: at, timeZone: tz
            )
            runner.assertEqual(offer != nil, offered)
        }
    }

    runner.run("NextNight: the offer keeps the packs (chips first, retired packs dropped) and the default name") {
        let offer = NextNightOffer.offer(
            settled: night, isHost: true, hasFutureNight: false, settleInFlight: false,
            now: now, timeZone: tz
        )!
        runner.assertEqual(offer.packSlugs, ["casino", "monopoly_deal"])
        runner.assertEqual(offer.name, "tue 17 nov · 7pm session")
        runner.assertEqual(offer.prompt, "Same time next Tuesday?")
        runner.assertEqual(NextNightOffer.pickAnotherTime, "Pick another time")
    }

    // hasFutureNight reads the phase from NightPhaseResolver.
    let settledId = night.id
    let upcoming = Event(id: UUID(), roomId: night.roomId, name: "next", playedAt: now.addingTimeInterval(86_400), createdAt: now)
    let live = Event(id: UUID(), roomId: night.roomId, name: "live", playedAt: now.addingTimeInterval(-600), createdAt: now)
    let otherPast = Event(id: UUID(), roomId: night.roomId, name: "old", playedAt: now.addingTimeInterval(-9 * 86_400), createdAt: now, settledAt: now.addingTimeInterval(-8 * 86_400))
    let futureRows: [(String, Event?, Bool)] = [
        ("no active night", nil, false),
        ("the active night is the settled one", night, false),
        ("an upcoming night is booked", upcoming, true),
        ("another night is live", live, true),
        ("the other night is long past", otherPast, false),
    ]
    for (label, active, expected) in futureRows {
        runner.run("NextNight: a future night exists — \(label)") {
            runner.assertEqual(
                NextNightOffer.hasFutureNight(active: active, settledId: settledId, now: now),
                expected
            )
        }
    }
}

// MARK: - Booking with Undo

private func runNextNightBookingTests(_ runner: TestRunner) {
    let offer = nnOffer()
    // (label, from, event, to)
    let rows: [(String, NextNightBooking, NextNightBookingEvent, NextNightBooking)] = [
        ("tap books it at once (Undo window)", .idle, .begin(offer), .undoing(offer)),
        ("Undo takes it back, nothing sent", .undoing(offer), .undo, .idle),
        ("the window passes, the create goes out", .undoing(offer), .commitStarted, .committing(offer)),
        ("no Undo once the create is out", .committing(offer), .undo, .committing(offer)),
        ("a second tap while sending is ignored", .committing(offer), .begin(offer), .committing(offer)),
        ("booked", .committing(offer), .commitSucceeded, .idle),
        ("already booked elsewhere: nothing to retry", .committing(offer), .alreadyBooked, .idle),
        ("failure brings the prompt back", .committing(offer), .commitFailed("x"), .failed(offer, message: "x")),
        ("retry after a failure", .failed(offer, message: "x"), .begin(offer), .undoing(offer)),
        ("a late success from an undone window is dropped", .idle, .commitSucceeded, .idle),
    ]
    for (label, from, event, to) in rows {
        runner.run("NextNight booking: \(label)") {
            runner.assertEqual(from.reduce(event), to)
        }
    }

    runner.run("NextNight booking: the recap shows the night as booked while pending") {
        runner.assertEqual(NextNightBooking.undoing(offer).pendingOffer, offer)
        runner.assertEqual(NextNightBooking.committing(offer).pendingOffer, offer)
        runner.assertNil(NextNightBooking.failed(offer, message: "x").pendingOffer)
        runner.assertNil(NextNightBooking.idle.pendingOffer)
        runner.assertEqual(NextNightBooking.undoing(offer).undoingOffer, offer)
        runner.assertNil(NextNightBooking.committing(offer).undoingOffer)
    }
}

// MARK: - The closing line

private func runRecapClosingTests(_ runner: TestRunner) {
    let tz = brisbane
    let offer = nnOffer(tz)
    let next = nnDate(2026, 11, 17, 19, 0, tz)
    let line = "Next: Tue 17 Nov, 7pm"

    // (label, isHost, nextNightAt, isReal, rsvp, offer, canPlan, expected)
    let rows: [(String, Bool, Date?, Bool, MemberRSVPState?, NextNightOffer?, Bool, RecapClosing)] = [
        ("member, next night booked, not answered", false, next, true, .unclaimed, nil, false, .nextNight(line: line, claim: true)),
        ("member, next night booked, already claimed", false, next, true, .claimed, nil, false, .nextNight(line: line, claim: false)),
        ("member, next night booked, declined", false, next, true, .declined, nil, false, .nextNight(line: line, claim: false)),
        ("host, next night booked", true, next, true, .unclaimed, nil, false, .nextNight(line: line, claim: false)),
        ("host, booking pending (optimistic)", true, next, false, nil, nil, false, .nextNight(line: line, claim: false)),
        ("host, nothing booked, offer ready", true, nil, false, nil, offer, true, .bookSameTime(offer)),
        ("host, nothing booked, no offer", true, nil, false, nil, nil, true, .planNextNight),
        ("host, nothing booked, nothing to plan", true, nil, false, nil, nil, false, .none),
        ("member, nothing booked: nothing", false, nil, false, nil, nil, false, .none),
    ]
    for (label, isHost, at, real, rsvp, offer, canPlan, expected) in rows {
        runner.run("Recap closing: \(label)") {
            runner.assertEqual(
                RecapClosing.resolve(
                    isHost: isHost, nextNightAt: at, nextNightIsReal: real,
                    myRSVPOnNext: rsvp, offer: offer, canPlan: canPlan, timeZone: tz
                ),
                expected
            )
        }
    }

    runner.run("Recap closing: the existing copy stays") {
        runner.assertEqual(RecapClosing.claimYourSeat, "Claim your seat")
        runner.assertEqual(RecapClosing.planNextNightTitle, "Plan the next night")
    }
}

// MARK: - The recap's order

private func runRecapLayoutTests(_ runner: TestRunner) {
    let next = RecapClosing.nextNight(line: "Next: Tue 17 Nov, 7pm", claim: true)
    // (label, star, canMakeACall, hasResults, memberNote, closing, expected)
    let rows: [(String, RecapStar, Bool, Bool, Bool, RecapClosing, [RecapSection])] = [
        ("Star first, results, next night last", .hostPick, false, true, false, next, [.star, .results, .closing]),
        ("no Star: results, then next night", .none, false, true, false, next, [.results, .closing]),
        ("no Star, host can make a call", .none, true, true, false, .planNextNight, [.makeACall, .results, .closing]),
        ("chip-swing Star sits with the results", .chipSwing, false, true, false, next, [.results, .star, .closing]),
        ("Star, no results yet", .hostPick, false, false, false, next, [.star, .closing]),
        ("nothing booked, member: the recap ends on the results", .hostPick, false, true, false, .none, [.star, .results]),
        ("member note sits before the closing line", .hostPick, false, true, true, next, [.star, .results, .memberNote, .closing]),
    ]
    for (label, star, call, results, note, closing, expected) in rows {
        runner.run("Recap order: \(label)") {
            runner.assertEqual(
                RecapLayout.sections(
                    star: star, canMakeACall: call, hasResults: results,
                    showsMemberNote: note, closing: closing
                ),
                expected
            )
        }
    }

    runner.run("Recap order: results never lead when the host picked a Star") {
        let sections = RecapLayout.sections(star: .hostPick, canMakeACall: true, hasResults: true, showsMemberNote: false, closing: next)
        runner.assertEqual(sections.first, .star)
        runner.assertEqual(sections.last, .closing)
    }

    // (label, sections from `RecapLayout.sections`, expected with Glad placed)
    let gladRows: [(String, [RecapSection], [RecapSection])] = [
        ("directly under the Star, above the results", [.star, .results, .closing], [.star, .glad, .results, .closing]),
        ("under a chip-swing Star, which sits after the results", [.results, .star, .closing], [.results, .star, .glad, .closing]),
        ("under Make a call when there is no Star", [.makeACall, .results, .closing], [.makeACall, .glad, .results, .closing]),
        ("no Star: above the results", [.results, .closing], [.glad, .results, .closing]),
        ("before the member note", [.star, .results, .memberNote, .closing], [.star, .glad, .results, .memberNote, .closing]),
        ("an otherwise empty recap still has it", [], [.glad]),
    ]
    for (label, sections, expected) in gladRows {
        runner.run("Recap order: Glad you came — \(label)") {
            let placed = RecapLayout.placingGlad(in: sections)
            runner.assertEqual(placed, expected)
            if sections.last == .closing { runner.assertEqual(placed.last, .closing) }
        }
    }

    runner.run("Recap order: the Star's source decides where it sits") {
        let pick = TonightStarCard(memberId: UUID(), memberDisplayName: "Alex", overrideCategory: .custom, customText: "x", source: "host_pick")
        let swing = TonightStarCard(memberId: UUID(), memberDisplayName: "Sam", overrideCategory: nil, customText: nil, source: "chip_swing")
        runner.assertEqual(RecapLayout.star(for: pick), .hostPick)
        runner.assertEqual(RecapLayout.star(for: swing), .chipSwing)
        runner.assertEqual(RecapLayout.star(for: nil), .none)
    }
}
