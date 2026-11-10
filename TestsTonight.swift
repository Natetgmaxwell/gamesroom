//
//  TestsTonight.swift
//  games-room
//
//  Tonight's chip board (TonightScore), the one "cashed out" rule
//  (WorkingHand.isCashedOut) and the "Tonight / In 3 days" label
//  (NightWhen). Registered from main.swift through
//  `runTonightTests(runner)`. Foundation only.

import Foundation

func runTonightTests(_ runner: TestRunner) {
    let alex = UUID(), sam = UUID(), jo = UUID(), host = UUID()
    let names = [alex: "Alex", sam: "Sam", jo: "Jo", host: "Host"]
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func hand(_ id: UUID, inHand: Int, scanned: Int? = nil) -> WorkingHand {
        WorkingHand(
            memberId: id, displayName: names[id] ?? "?", workingHand: inHand,
            pointsBalance: 1_000, hasScanned: scanned != nil, scannedValue: scanned
        )
    }
    func settlement(_ id: UUID, _ amount: Int64) -> EventTransaction {
        EventTransaction(
            id: UUID(), memberId: id, memberDisplayName: names[id] ?? "?",
            kind: "casino_settlement", amountPoints: amount, createdAt: t0
        )
    }
    func withdrawal(_ id: UUID, _ amount: Int64) -> EventTransaction {
        EventTransaction(
            id: UUID(), memberId: id, memberDisplayName: names[id] ?? "?",
            kind: "casino_withdrawal", amountPoints: -amount, createdAt: t0
        )
    }

    runner.run("Tonight: cashed out is scanned with nothing taken since") {
        runner.assertFalse(hand(alex, inHand: 0).isCashedOut, "no chips is not cashed out")
        runner.assertFalse(hand(alex, inHand: 200).isCashedOut, "chips on the table")
        runner.assertTrue(hand(alex, inHand: 240, scanned: 240).isCashedOut)
        // A top-up after the scan puts them back in the game.
        runner.assertFalse(hand(alex, inHand: 340, scanned: 240).isCashedOut)
        runner.assertTrue(hand(alex, inHand: 0, scanned: 0).tookChips, "scanned 0 still played")
    }

    runner.run("Tonight: before anyone takes chips, claimed seats show and the headline says start") {
        let score = TonightScore.tally(hands: [], transactions: [], players: [alex, sam], names: names)
        runner.assertEqual(score.rows.map(\.status), [.noChips, .noChips])
        runner.assertEqual(score.headline, "Everyone takes chips to start")
        runner.assertNil(score.progressCaption)
    }

    runner.run("Tonight: while everyone plays, nobody leads yet") {
        let score = TonightScore.tally(
            hands: [hand(alex, inHand: 200), hand(sam, inHand: 200)],
            transactions: [withdrawal(alex, 200), withdrawal(sam, 200)],
            names: names
        )
        runner.assertEqual(score.headline, "Game on. Scores land as people cash out.")
        runner.assertEqual(score.progressCaption, "0 of 2 cashed out")
        runner.assertEqual(score.leaders.count, 0)
    }

    runner.run("Tonight: the net is the server's settlement rows, cashed out first, highest first") {
        let score = TonightScore.tally(
            hands: [hand(alex, inHand: 240, scanned: 240), hand(sam, inHand: 150, scanned: 150), hand(jo, inHand: 200)],
            transactions: [withdrawal(alex, 200), settlement(alex, 40), settlement(sam, -50)],
            players: [host],
            names: names
        )
        runner.assertEqual(score.rows.map(\.name), ["Alex", "Sam", "Jo", "Host"])
        runner.assertEqual(score.rows.map(\.status), [.cashedOut(net: 40), .cashedOut(net: -50), .playing, .noChips])
        runner.assertEqual(score.headline, "Alex is up 40")
        runner.assertEqual(score.progressCaption, "2 of 3 cashed out")
    }

    runner.run("Tonight: a re-scan's correction row nets out") {
        // Latest scan wins server-side: the second row corrects the first.
        let score = TonightScore.tally(
            hands: [hand(alex, inHand: 220, scanned: 220)],
            transactions: [settlement(alex, 40), settlement(alex, -20)],
            names: names
        )
        runner.assertEqual(score.rows.first?.net, 20)
    }

    runner.run("Tonight: a tie at the top names everyone on it") {
        let score = TonightScore.tally(
            hands: [hand(alex, inHand: 1, scanned: 1), hand(sam, inHand: 1, scanned: 1)],
            transactions: [settlement(alex, 30), settlement(sam, 30)],
            names: names
        )
        runner.assertEqual(score.headline, "Alex and Sam are up 30")
    }

    runner.run("Tonight: everyone down means nobody is up") {
        let score = TonightScore.tally(
            hands: [hand(alex, inHand: 1, scanned: 1)],
            transactions: [settlement(alex, -10)],
            names: names
        )
        runner.assertEqual(score.headline, "Nobody has finished up yet")
    }

    runner.run("NameList: one, two, three names") {
        runner.assertEqual(NameList.joined(["Sam"]), "Sam")
        runner.assertEqual(NameList.joined(["Sam", "Jo"]), "Sam and Jo")
        runner.assertEqual(NameList.joined(["Sam", "Jo", "Alex"]), "Sam, Jo and Alex")
    }

    runner.run("NightWhen: tonight, today, tomorrow, in N days, then just the date") {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Australia/Brisbane")!
        func at(_ day: Int, _ hour: Int) -> Date {
            cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
        }
        let now = at(10, 9)
        runner.assertEqual(NightWhen.label(playedAt: at(10, 19), now: now, calendar: cal), "Tonight")
        runner.assertEqual(NightWhen.label(playedAt: at(10, 13), now: now, calendar: cal), "Today")
        runner.assertEqual(NightWhen.label(playedAt: at(11, 19), now: now, calendar: cal), "Tomorrow")
        runner.assertEqual(NightWhen.label(playedAt: at(13, 19), now: now, calendar: cal), "In 3 days")
        runner.assertNil(NightWhen.label(playedAt: at(20, 19), now: now, calendar: cal))
        runner.assertNil(NightWhen.label(playedAt: at(10, 8), now: now, calendar: cal))
    }
}
