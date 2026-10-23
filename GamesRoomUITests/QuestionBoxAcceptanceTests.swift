//
//  QuestionBoxAcceptanceTests.swift
//  GamesRoomUITests
//
//  V0.106 acceptance (docs/V0.106_QUESTION_BOX_SPEC.md §5), driven by
//  real taps against the seeded InMemoryRoomStore
//  (`-screenshots-bypass-auth` + `-question-box-seed=<mode>`):
//
//    1. A member who ignores both fields completes RSVP in the same
//       taps as today (one tap on "Claim seat", no sheet, no gate).
//    2. Never more than one optional field on the claimed-state card,
//       including after the Currently Into answer flips the ask.
//    3. Host gets the opener at start time; subsequent turns rotate
//       through members with a withdrawal (Sam withdrew before Alex),
//       on the interval only. `-question-box-minute-seconds=0.25`
//       scales the 20-minute default to 5 s.
//    6. Currently Into older than 30 days does not render in the
//       Briefing (Sam's is 40 days old; Alex's is 2 days old).
//       Since S6 T3/T4 that is read from the seat popover on the
//       event card, not from the removed who's-coming list.
//
//  Run:
//    xcodebuild test -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination "platform=iOS Simulator,id=<iPadUDID>" \
//      -only-testing:GamesRoomUITests/QuestionBoxAcceptanceTests
//

import XCTest

final class QuestionBoxAcceptanceTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(seed: String, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-screenshots-bypass-auth", "-question-box-seed=\(seed)"] + extra
        app.launch()
        let room = app.staticTexts["Carwoola Crew"].firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 15), "Carwoola Crew row never appeared")
        room.tap()
        return app
    }

    private func optionalFieldCount(_ app: XCUIApplication) -> Int {
        ["claimed-currently-into-field", "claimed-question-field"]
            .filter { app.textFields[$0].exists }
            .count
    }

    // MARK: 1 + 2

    func test_acceptance1_claimIsStillOneTap_andAcceptance2_atMostOneOptionalField() throws {
        let app = launch(seed: "briefing")

        let claim = app.buttons["Claim seat"].firstMatch
        XCTAssertTrue(claim.waitForExistence(timeout: 10), "Claim seat CTA missing on the upcoming briefing")
        XCTAssertEqual(optionalFieldCount(app), 0, "No optional field before claiming")

        // Acceptance 1: one tap, straight to the claimed state.
        claim.tap()
        XCTAssertTrue(app.staticTexts["You're in."].firstMatch.waitForExistence(timeout: 5),
                      "One tap on Claim seat must land on the claimed state")
        XCTAssertFalse(app.sheets.firstMatch.exists, "Claiming must not open a sheet")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Claiming must not raise an alert")

        // Acceptance 2: exactly one optional field — Currently Into first
        // (the synthetic member has none yet).
        let currentlyInto = app.textFields["claimed-currently-into-field"]
        XCTAssertTrue(currentlyInto.waitForExistence(timeout: 5), "Stale/empty Currently Into must be the one ask")
        XCTAssertEqual(optionalFieldCount(app), 1)

        // Answering it flips the ask to the question field — still one.
        currentlyInto.tap()
        currentlyInto.typeText("Bouldering\n")
        let question = app.textFields["claimed-question-field"]
        XCTAssertTrue(question.waitForExistence(timeout: 5), "After a fresh Currently Into the question field takes the slot")
        XCTAssertFalse(currentlyInto.exists)
        XCTAssertEqual(optionalFieldCount(app), 1)
    }

    // MARK: 3

    func test_acceptance3_hostOpenerThenWithdrawalRotationOnInterval() throws {
        let app = launch(seed: "live", extra: [
            "-question-box-minute-seconds=0.25",
            "-question-box-poll-seconds=0.5"
        ])

        // Opener: this device's user is the host, so the reader card is theirs.
        let title = app.staticTexts["reader-card-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "Host must get the opener at start time")
        XCTAssertTrue(app.staticTexts["Question from the box:"].exists, "Ritual opener line missing")
        XCTAssertTrue(app.staticTexts["reader-card-question"].exists)
        app.buttons["reader-card-done"].tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5), "Done must close the reader card")

        // Interval turns go to withdrawers in first-withdrawal order: Sam, then Alex.
        // The host sees only the quiet fallback, never the reader card.
        let fallback = app.buttons["host-question-fallback"]
        XCTAssertTrue(fallback.waitForExistence(timeout: 10), "Host fallback never appeared for the first interval turn")
        XCTAssertTrue(fallback.label.contains("Sam's asking"), "First interval reader should be Sam, got: \(fallback.label)")
        XCTAssertFalse(title.exists, "A turn for someone else must not open the reader card on this device")

        let alex = NSPredicate(format: "label CONTAINS %@", "Alex's asking")
        expectation(for: alex, evaluatedWith: fallback)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(title.exists)
    }

    // MARK: 6

    func test_acceptance6_staleCurrentlyIntoHiddenInBriefing() throws {
        let app = launch(seed: "briefing")

        // v1.2.2 S6 T3/T4 — this used to read the who's-coming list on
        // the event card, which listed both claimants' names at once.
        // The list is gone; a claimed seat is a button and tapping it
        // opens who claimed it plus the grey caption, so the two
        // members are read one popover at a time.
        let alexSeat = app.descendants(matching: .any)["seat-Alex"].firstMatch
        XCTAssertTrue(alexSeat.waitForExistence(timeout: 10),
                      "Alex's claimed seat never rendered on the seat grid")
        alexSeat.tap()

        // Fresh (2 days) renders. Match on the tail of the sentence:
        // `BroughtBy` prefixes the member's own words with "into ", so
        // the assertion is about the value, not the phrasing.
        let alexCaption = app.descendants(matching: .any)["seat-popover-Alex"].firstMatch
        XCTAssertTrue(alexCaption.waitForExistence(timeout: 10),
                      "Seat popover never opened for Alex")
        XCTAssertTrue(alexCaption.label.contains("Learning the banjo"),
                      "Fresh Currently Into should render in Alex's seat popover, got '\(alexCaption.label)'")

        // Dismiss Alex's popover (a tap low on the backdrop closes it)
        // so Sam's seat can be tapped underneath.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        let closed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: alexCaption
        )
        XCTAssertEqual(XCTWaiter().wait(for: [closed], timeout: 10), .completed,
                       "Alex's seat popover never dismissed")

        // Stale (40 days) does not: Sam's popover opens with his name
        // and NO caption line at all, because every part of it is
        // empty once the 30-day staleness rule drops his Currently
        // Into.
        let samSeat = app.descendants(matching: .any)["seat-Sam"].firstMatch
        XCTAssertTrue(samSeat.waitForExistence(timeout: 10),
                      "Sam's claimed seat never rendered on the seat grid")
        samSeat.tap()
        XCTAssertTrue(app.staticTexts["Sam"].firstMatch.waitForExistence(timeout: 10),
                      "Sam's seat popover never opened")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Sourdough starters")
        ).firstMatch.exists,
                       "Currently Into older than 30 days must not render")
        // Bounded wait so a late render cannot sneak past the
        // assertion above: the caption must not appear late.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertFalse(app.descendants(matching: .any)["seat-popover-Sam"].firstMatch.exists,
                       "A stale Currently Into rendered a caption in Sam's seat popover")
    }
}
