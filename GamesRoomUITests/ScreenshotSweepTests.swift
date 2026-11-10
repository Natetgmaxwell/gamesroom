//
//  ScreenshotSweepTests.swift
//
//  16-state design-audit sweep (see originals/2026-10-19-games-room-detail-audit).
//  Each test launches with -screenshots-bypass-auth + -screenshots-state=<key>,
//  waits for a real element (no thin fixtures), and attaches one full-screen
//  shot via snap(_:). Runs on iPhone sims; attachments export from the xcresult.
//
//

import XCTest

final class ScreenshotSweepTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Fresh launch with the screenshot bypass seam plus the
    /// state's seed arguments.
    private func launchSweep(arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-screenshots-bypass-auth"] + arguments
        app.launch()
        return app
    }

    /// Attaches ONE full-screen screenshot with the stable state
    /// name. `XCUIScreen.main` (not `app`) so the capture is the
    /// true full screen including any sheet chrome.
    private func snap(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps a room row in the rooms list and waits for the detail
    /// to take the foreground. Exercises the real NavigationLink
    /// push (no programmatic state injection).
    private func openRoom(_ app: XCUIApplication, named roomName: String) {
        let row = app.staticTexts[roomName].firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 15),
            "'\(roomName)' row never appeared in the rooms list."
        )
        row.tap()
    }

    /// One screen of upward scroll, as a coordinate drag.
    ///
    /// v1.2.2 S6 T4 — NOT `app.swipeUp()`. On this simulator build
    /// that call does not move a scroll view at all: measured on the
    /// room page, the title sat at the same y across six
    /// `app.swipeUp()` calls, and `04b-upcoming-scrolled-end` came
    /// out pixel-identical to `04-room-page-…`, while the same
    /// gesture as an explicit coordinate drag moved the page ~420pt
    /// per pass. Both helpers below drag instead. The drag starts
    /// mid-page and ends high, clear of the floating tab bar at the
    /// bottom and the room toolbar at the top.
    private func scrollUp(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            )
    }

    /// Scrolls up (bounded) until the element is hittable. Returns
    /// false when the bound is exhausted without the element
    /// becoming hittable.
    @discardableResult
    private func scrollUntilHittable(
        _ app: XCUIApplication,
        element: XCUIElement,
        maxSwipes: Int = 12
    ) -> Bool {
        for _ in 0..<maxSwipes {
            if element.exists && element.isHittable { return true }
            scrollUp(app)
        }
        return element.exists && element.isHittable
    }

    /// Same intent as `scrollUntilHittable`, but it decides from
    /// frames instead of `isHittable`. XCUITest records a test
    /// failure ("Activation point invalid and no suggested hit
    /// points based on element frame") when `isHittable` is asked
    /// about an element that is still below the fold, so that call
    /// is only safe once the element is on screen. Use this one when
    /// the target starts out of frame.
    ///
    /// v1.2.2 S6 T4 — a miss is not a stop. The room page renders
    /// lazily, so a section further down is simply absent from the
    /// hierarchy until the scroll reaches it; this used to bail on
    /// the first miss and report "never scrolled into view" for rows
    /// that had not been rendered yet. It now keeps scrolling, and
    /// ends on whether the element is at least on screen (the tap
    /// that follows still proves it is reachable).
    @discardableResult
    private func scrollIntoFrame(
        _ app: XCUIApplication,
        element: XCUIElement,
        maxSwipes: Int = 12
    ) -> Bool {
        let bounds = app.frame
        for _ in 0..<maxSwipes {
            if element.exists {
                let frame = element.frame
                if frame.width > 0, frame.height > 0,
                   frame.midY > bounds.minY + 44, frame.midY < bounds.maxY - 44 {
                    return true
                }
            }
            scrollUp(app)
        }
        guard element.exists else { return false }
        let frame = element.frame
        return frame.height > 0 && frame.maxY > bounds.minY && frame.minY < bounds.maxY
    }

    // MARK: - 01 First launch (empty)

    func test_01_first_launch_empty() throws {
        let app = launchSweep(arguments: ["-screenshots-state=empty"])

        let headline = app.staticTexts["No rooms yet"].firstMatch
        XCTAssertTrue(
            headline.waitForExistence(timeout: 10),
            "Empty-state headline never rendered — the empty key must clear the rooms list."
        )

        snap(app, "01-first-launch-empty")
    }

    // MARK: - 02 Join with code

    func test_02_join_with_code() throws {
        let app = launchSweep(arguments: ["-screenshots-state=empty"])

        let joinCTA = app.buttons["Enter a join code"].firstMatch
        XCTAssertTrue(
            joinCTA.waitForExistence(timeout: 10),
            "Empty-state join CTA missing."
        )
        joinCTA.tap()

        let navBar = app.navigationBars["Join a room"].firstMatch
        XCTAssertTrue(
            navBar.waitForExistence(timeout: 10),
            "JoinRoomSheet never presented."
        )

        snap(app, "02-join-with-code")
    }

    // MARK: - 03 Room page, empty host

    func test_03_room_page_empty_host() throws {
        let app = launchSweep(arguments: [])

        openRoom(app, named: "Test Sandbox")

        let hostEmpty = app.staticTexts["No nights on the books yet"].firstMatch
        XCTAssertTrue(
            hostEmpty.waitForExistence(timeout: 10),
            "Host empty-room state never rendered (perpetual spinner?)."
        )

        snap(app, "03-room-page-empty-host")
    }

    // MARK: - 04 Room page, upcoming event, partial seats

    func test_04_room_page_upcoming_event_partial_seats() throws {
        let app = launchSweep(arguments: ["-screenshots-state=upcoming-partial"])

        openRoom(app, named: "Carwoola Crew")

        let claim = app.buttons["Claim seat"].firstMatch
        XCTAssertTrue(
            claim.waitForExistence(timeout: 10),
            "BriefingSlot never rendered for the upcoming partial event."
        )
        // v1.2 S2: aggregate caption gone; CONTAINS proves the RSVP rows are read.
        let comingRow = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Alex'")
        ).firstMatch
        XCTAssertTrue(
            comingRow.waitForExistence(timeout: 5),
            "Who's-coming rows never named Alex — the partial seat grid seed is not being read."
        )

        snap(app, "04-room-page-upcoming-event-partial-seats")
        // S6 T4 — `scrollUp`, not `app.swipeUp()`: the latter does
        // not move the page here, so this snapshot used to come out
        // identical to the one above it. The end state must clear
        // the floating tab bar.
        for _ in 0..<4 { scrollUp(app) }
        snap(app, "04b-upcoming-scrolled-end")
    }

    // MARK: - 05 Room page, tonight live

    func test_05_room_page_tonight_live() throws {
        let app = launchSweep(arguments: ["-screenshots-state=tonight-live"])

        openRoom(app, named: "Carwoola Crew")

        let witnessTitle = app.staticTexts["The night has started"].firstMatch
        XCTAssertTrue(
            witnessTitle.waitForExistence(timeout: 10),
            "WitnessSlot (.tonightEvent) never rendered."
        )
        // Every night is scored in chips, and the host plays too: with
        // no chips yet, the one thing to do is take them.
        let take = app.buttons["Take your chips"].firstMatch
        XCTAssertTrue(
            take.waitForExistence(timeout: 5),
            "'Take your chips' primary missing on the live card."
        )
        XCTAssertFalse(
            app.buttons["Score a round (host)"].exists,
            "Round scoring is back; every night is scored in chips."
        )

        snap(app, "05-room-page-tonight-live")
    }

    // MARK: - 05b Chips night, waiting on one player

    func test_05b_chips_night_waiting_on_a_player() throws {
        // The host and Alex have cashed out, Sam is still playing. The
        // board answers "who's up tonight?", and the host's card waits
        // on Sam instead of offering to settle over his chips.
        let app = launchSweep(arguments: ["-screenshots-state=night-chips"])

        openRoom(app, named: "Carwoola Crew")

        XCTAssertTrue(
            app.staticTexts["Alex is up 40"].firstMatch.waitForExistence(timeout: 10),
            "The Tonight board never named who is up."
        )
        XCTAssertTrue(
            app.staticTexts["2 of 3 cashed out"].firstMatch.exists,
            "The Tonight board's cash-out progress is missing."
        )
        XCTAssertTrue(
            app.staticTexts["Waiting on Sam to cash out"].firstMatch.exists,
            "The host's card should wait on Sam, not lead with Settle."
        )
        XCTAssertTrue(
            app.buttons["Settle the night (host)"].firstMatch.exists,
            "'Settle the night' should still be the quiet line under the wait."
        )

        snap(app, "05b-chips-night-waiting")
    }

    // MARK: - 06 Room page, settled last night

    func test_06_room_page_settled_last_night() throws {
        let app = launchSweep(arguments: ["-screenshots-state=settled-rich"])

        openRoom(app, named: "Carwoola Crew")

        let star = app.staticTexts["Tonight's Star"].firstMatch
        XCTAssertTrue(
            star.waitForExistence(timeout: 10),
            "CeremonialCard (.justSettled) star section never rendered."
        )
        XCTAssertTrue(
            app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 5),
            "Tonight's Star winner name never rendered."
        )
        // The recap is the memory of the night: whose night it was,
        // and how everyone finished.
        XCTAssertTrue(
            app.staticTexts["How the night went"].firstMatch.waitForExistence(timeout: 5),
            "The recap lost the night's results."
        )
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hosted by you")).firstMatch.exists,
            "The recap no longer credits the host."
        )

        snap(app, "06-room-page-settled-last-night")
    }

    // MARK: - 07 Room detail, member idle

    func test_07_room_detail_member_idle() throws {
        let app = launchSweep(arguments: [
            "-screenshots-as-member",
            "-screenshots-state=member-idle"
        ])

        openRoom(app, named: "Carwoola Crew")

        // S3 T4: the `member-idle` seed keeps its standings rows, so
        // `.readStandings` renders nothing in the hero. Wait for the
        // real Standings header (the room loads async), THEN assert the
        // empty-state copy is absent. Asserting absence first passed
        // vacuously on the loading screen and the swipes overshot.
        let standings = app.staticTexts["Standings"].firstMatch
        XCTAssertTrue(
            standings.waitForExistence(timeout: 10),
            "Member readStandings branch never rendered — the standings section is missing."
        )
        XCTAssertFalse(
            app.staticTexts["The ledger fills in after your first night."].firstMatch.exists,
            "Empty-state copy rendered above populated standings (S3 T4 regression)."
        )

        snap(app, "07-room-detail-member-idle")
    }

    // MARK: - 08 Claim seat card

    func test_08_claim_seat_card() throws {
        let app = launchSweep(arguments: ["-screenshots-state=claim-card"])

        openRoom(app, named: "Carwoola Crew")

        let claim = app.buttons["Claim seat"].firstMatch
        XCTAssertTrue(
            claim.waitForExistence(timeout: 10),
            "Claim-seat CTA never rendered."
        )
        XCTAssertTrue(
            app.buttons["Can't make it"].firstMatch.waitForExistence(timeout: 5),
            "Decline CTA missing under Claim seat."
        )

        snap(app, "08-claim-seat-card")
    }

    // MARK: - 09 Settling early asks first

    func test_09_settle_early_asks_first() throws {
        // Settling with Sam's chips still on the table is the one move
        // that strands someone, so it names him and asks.
        let app = launchSweep(arguments: ["-screenshots-state=night-chips"])

        openRoom(app, named: "Carwoola Crew")

        let settle = app.buttons["Settle the night (host)"].firstMatch
        XCTAssertTrue(
            settle.waitForExistence(timeout: 10),
            "'Settle the night' line missing on the chips night."
        )
        settle.tap()

        XCTAssertTrue(
            app.staticTexts["Sam hasn't cashed out. Settle the night anyway?"].firstMatch.waitForExistence(timeout: 5),
            "Settling early did not warn about Sam."
        )
        XCTAssertTrue(
            app.buttons["Keep playing"].firstMatch.exists,
            "The settle-early dialog has no way back."
        )

        snap(app, "09-settle-early-asks-first")
    }

    // MARK: - 10 Question box reader card

    func test_10_question_box_reader_card() throws {
        // Mirrors QuestionBoxAcceptanceTests' live-seed recipe: the
        // seeded event starts a minute ago, everyone claimed, and
        // the scaled cadence args make the opener land within
        // seconds of entering the room. The host (this device's
        // user) receives the opener, so the large-type reader card
        // presents itself app-wide.
        let app = launchSweep(arguments: [
            "-question-box-seed=live",
            "-question-box-minute-seconds=0.25",
            "-question-box-poll-seconds=0.5"
        ])

        openRoom(app, named: "Carwoola Crew")

        let readerTitle = app.staticTexts["reader-card-title"].firstMatch
        XCTAssertTrue(
            readerTitle.waitForExistence(timeout: 15),
            "Reader card never presented — the host opener turn did not fire."
        )
        XCTAssertTrue(
            app.staticTexts["Question from the box:"].firstMatch.exists,
            "Ritual opener line missing on the reader card."
        )

        snap(app, "10-question-box-reader-card")
    }

    // MARK: - 11 Take your chips

    func test_11_casino_chip_scan_sheet() throws {
        let app = launchSweep(arguments: ["-screenshots-state=chip-scan"])

        openRoom(app, named: "Carwoola Crew")

        // The host has no chips yet, so the card's one button takes
        // them, straight to the withdraw sheet (no picker in between).
        let take = app.buttons["Take your chips"].firstMatch
        XCTAssertTrue(
            take.waitForExistence(timeout: 10),
            "'Take your chips' CTA missing on the live night."
        )
        take.tap()

        let withdrawBar = app.navigationBars["Withdraw chips"].firstMatch
        XCTAssertTrue(
            withdrawBar.waitForExistence(timeout: 10),
            "WithdrawChipsSheet never presented from 'Take your chips'."
        )

        snap(app, "11-casino-chips-withdraw-sheet")
    }

    // MARK: - 12 Settled view with deltas

    func test_12_settled_view_with_deltas() throws {
        let app = launchSweep(arguments: ["-screenshots-state=settled-rich"])

        openRoom(app, named: "Carwoola Crew")

        let star = app.staticTexts["Tonight's Star"].firstMatch
        XCTAssertTrue(
            star.waitForExistence(timeout: 10),
            "CeremonialCard (.justSettled) never rendered."
        )

        // Scroll the standings board (mixed green/red deltas,
        // comeback + blowout rows) into frame under the recap.
        let standings = app.staticTexts["Standings"].firstMatch
        XCTAssertTrue(
            scrollUntilHittable(app, element: standings),
            "Standings section never became hittable — the seeded leaderboard rows are missing."
        )

        snap(app, "12-settled-view-with-deltas")
    }

    // MARK: - 13 Season person rows (win/loss)

    func test_13_season_person_rows_winloss() throws {
        let app = launchSweep(arguments: [])

        openRoom(app, named: "Carwoola Crew")

        // The seeded room carries two prior seasons ("The Comeback"
        // ordinal 2, "Genesis" ordinal 1) plus per-season grids.
        // Expand the fresher prior season, then open its
        // "Every night" grid sheet — one row per member with a
        // green/red/absent mark per night.
        let comebackRow = app.descendants(matching: .any)
            .matching(identifier: "season-row-2").firstMatch
        // v1.2.2 S6 — frames, not hittability, and for a real reason:
        // T2 put the event card on `cardGroupGap`, which made the
        // room page taller, so the Seasons rows now sit further down
        // than `scrollUntilHittable`'s 12-swipe bound could reach
        // (it passed at b12c83f and failed at a32ac05). The row is
        // still asserted to exist and then tapped — an unhittable
        // row fails the tap, so reachability is still proven.
// v1.2.2 S6 — frames, not hittability, and for a real reason:
        // T2 put the event card on `cardGroupGap`, which made the
        // room page taller, so the Seasons rows now sit further down
        // than `scrollUntilHittable`'s 12-swipe bound could reach
        // (it passed at b12c83f and failed at a32ac05). The row is
        // still asserted to exist and then tapped — an unhittable
        // row fails the tap, so reachability is still proven.
        // S6 T4 — `scrollIntoFrame` also stopped bailing on the first
        // miss and `scrollUp` drags instead of calling the no-op
        // `app.swipeUp()`, which is what let this pass.
        XCTAssertTrue(
            scrollIntoFrame(app, element: comebackRow),
            "Season row for 'The Comeback' never scrolled into view."
        )
        comebackRow.tap()

        let everyNight = app.buttons["Every night"].firstMatch
        XCTAssertTrue(
            everyNight.waitForExistence(timeout: 10),
            "'Every night' action never appeared — the season grid did not load."
        )
        everyNight.tap()

        let sheetBar = app.navigationBars["The Comeback"].firstMatch
        XCTAssertTrue(
            sheetBar.waitForExistence(timeout: 10),
            "SeasonGridSheet for 'The Comeback' never presented."
        )
        XCTAssertTrue(
            app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 5),
            "Member strip row never rendered in the season grid."
        )

        snap(app, "13-season-person-rows-winloss")
    }

    // MARK: - 14 Awards ceremonial card

    func test_14_awards_ceremonial_card() throws {
        let app = launchSweep(arguments: ["-screenshots-state=awards"])

        openRoom(app, named: "Felt Faction")

        let phoenixCaption = app.staticTexts["Climbed 4 ranks across the season."].firstMatch
        XCTAssertTrue(
            phoenixCaption.waitForExistence(timeout: 10),
            "AwardsCard (.seasonClose) never rendered its seeded award rows."
        )

        snap(app, "14-awards-ceremonial-card")
    }

    // MARK: - 15 Room settings members sheet

    func test_15_room_settings_members_sheet() throws {
        let app = launchSweep(arguments: [])

        openRoom(app, named: "Carwoola Crew")

        let gear = app.buttons["Room settings"].firstMatch
        XCTAssertTrue(
            gear.waitForExistence(timeout: 10),
            "Room-settings toolbar gear never appeared on the room detail."
        )
        gear.tap()

        let settingsBar = app.navigationBars["Room settings"].firstMatch
        XCTAssertTrue(
            settingsBar.waitForExistence(timeout: 10),
            "RoomSettingsSheet never presented."
        )

        let membersRow = app.staticTexts["Members"].firstMatch
        XCTAssertTrue(
            membersRow.waitForExistence(timeout: 5),
            "Members row missing in Room settings."
        )
        membersRow.tap()

        let membersBar = app.navigationBars["Members"].firstMatch
        XCTAssertTrue(
            membersBar.waitForExistence(timeout: 10),
            "RoomSettingsMembersSheet never pushed."
        )
        XCTAssertTrue(
            app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 10),
            "Roster rows never loaded in the members sheet."
        )

        snap(app, "15-room-settings-members-sheet")
    }

    // MARK: - 15b Room settings brought-by switch (V0.107)

    func test_15b_room_settings_brought_by_switch() throws {
        let app = launchSweep(arguments: [])

        openRoom(app, named: "Carwoola Crew")

        let gear = app.buttons["Room settings"].firstMatch
        XCTAssertTrue(
            gear.waitForExistence(timeout: 10),
            "Room-settings toolbar gear never appeared on the room detail."
        )
        gear.tap()

        XCTAssertTrue(
            app.navigationBars["Room settings"].firstMatch.waitForExistence(timeout: 10),
            "RoomSettingsSheet never presented."
        )

        let opsRow = app.staticTexts["Operations"].firstMatch
        XCTAssertTrue(
            opsRow.waitForExistence(timeout: 5),
            "Operations row missing in Room settings."
        )
        opsRow.tap()

        XCTAssertTrue(
            app.navigationBars["Operations"].firstMatch.waitForExistence(timeout: 10),
            "RoomSettingsOperationsSheet never pushed."
        )

        // V0.107 — the switch sits below the Features section, so on a
        // compact iPhone it starts under the fold.
        let broughtBy = app.switches["Show who brought newcomers"]
        XCTAssertTrue(
            scrollUntilHittable(app, element: broughtBy),
            "Host-only brought-by switch never became hittable in Operations."
        )
        XCTAssertEqual(
            broughtBy.value as? String,
            "1",
            "Brought-by switch should open on (the rooms.show_brought_by column default)."
        )

        // The switch lands on the last rendered cell of the form,
        // where its centre sits just past the bottom edge, so give it
        // one more scroll to bring the whole section into the frame
        // before anything reads or touches it.
        scrollUp(app)
        XCTAssertTrue(
            broughtBy.waitForExistence(timeout: 5) && broughtBy.isHittable,
            "Brought-by switch is not reachable after scrolling into it."
        )

        snap(app, "15b-room-settings-brought-by")

        // Tapping must move the switch, not bounce it back: the
        // binding is hoisted so the hub's autosave write captures it.
        // Aim at the trailing control: the row's centre is over the
        // label, which this Toggle does not take a tap on.
        broughtBy.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let turnedOff = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == '0'"),
            object: broughtBy
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [turnedOff], timeout: 5),
            .completed,
            "Tapping the brought-by switch did not turn it off."
        )

        // The caption sits directly under the switch row, and the
        // switch itself can land on the last rendered cell of the
        // form, so the footer is often one lazy-rendered row past
        // the fold. Match on the tail of the sentence so a label
        // normalisation cannot break it, and wait on existence
        // (a form footer is not a tap target, so hittability is the
        // wrong test).
        let footer = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "so the room knows who they came with")
        ).firstMatch
        for _ in 0..<5 {
            if footer.exists { break }
            scrollUp(app)
        }
        XCTAssertTrue(
            footer.waitForExistence(timeout: 5),
            "Brought-by footer caption missing."
        )
    }

    // MARK: - 16 Briefing

    func test_16_briefing() throws {
        let app = launchSweep(arguments: ["-screenshots-state=briefing"])

        openRoom(app, named: "Carwoola Crew")

        let claim = app.buttons["Claim seat"].firstMatch
        XCTAssertTrue(
            claim.waitForExistence(timeout: 10),
            "BriefingSlot never rendered for the briefing seed."
        )
        // v1.2 S2 — the "N seats left" count row is gone (the seat
        // grid is the count). The briefing still renders date/venue/
        // notes; assert the venue line from the briefing seed.
        XCTAssertTrue(
            app.staticTexts["The dining room"].firstMatch.waitForExistence(timeout: 5),
            "Briefing venue line missing (expected 'The dining room' from the briefing seed)."
        )

        // 1.2.5 Task 3 — the host's summary names the newcomer and
        // suggests a job. The briefing seed gives Sam zero nights and a
        // claimed seat, so exactly one line renders.
        let newcomerJob = app.descendants(matching: .any)["newcomer-job"].firstMatch
        XCTAssertTrue(
            newcomerJob.waitForExistence(timeout: 5),
            "Host's newcomer job line missing from the briefing (Task 3)."
        )
        XCTAssertTrue(
            newcomerJob.label.contains("Sam's first night. Give them a job: the bank, dealing, or the first question."),
            "Newcomer job line has the wrong copy: got '\(newcomerJob.label)'."
        )
        XCTAssertFalse(
            newcomerJob.label.contains("Alex's first night"),
            "A regular (Alex, 12 nights) was named as a newcomer."
        )
        _ = scrollIntoFrame(app, element: newcomerJob)
        snap(app, "16-briefing")
        // S6 T4 — `scrollUp`, not `app.swipeUp()` (a no-op here):
        // end state must clear the floating tab bar.
        for _ in 0..<4 { scrollUp(app) }
        snap(app, "16b-briefing-scrolled-end")
    }

    // MARK: - 16c Briefing, member view: no newcomer job line (Task 3)

    func test_16c_briefing_member_has_no_newcomer_job() throws {
        let app = launchSweep(arguments: [
            "-screenshots-as-member",
            "-screenshots-state=briefing"
        ])

        openRoom(app, named: "Carwoola Crew")

        XCTAssertTrue(
            app.staticTexts["The dining room"].firstMatch.waitForExistence(timeout: 10),
            "BriefingSlot never rendered for the member's briefing seed."
        )
        // The job line is the host's prompt. A member must never see it.
        XCTAssertFalse(
            app.descendants(matching: .any)["newcomer-job"].firstMatch.exists,
            "A member can see the host's newcomer job line (Task 3)."
        )
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Give them a job")).firstMatch.exists,
            "A member can see the host's newcomer job copy (Task 3)."
        )
    }

    // MARK: - 17 Briefing seat grid (V0.107 brought-by, S6 T3/T4)

    func test_17_briefing_brought_by() throws {
        let app = launchSweep(arguments: ["-screenshots-state=briefing"])

        openRoom(app, named: "Carwoola Crew")

        // v1.2.2 S6 T4 — the "Who's coming" list is gone from the event
        // card, so who claimed a seat AND who brought them is read off
        // the seat grid: the cell keeps its chair label ("Sam's seat,
        // with Alex, claimed") and tapping it opens the popover that
        // carries the grey caption the list used to show. The briefing
        // seed anchors Sam to Alex at zero sessions, so the caption
        // reads "with Alex · first night · into Bouldering".
        //
        // Query by identifier over any element type: the cell is a
        // button whose identifier is the seat it is, so this test does
        // not depend on how XCUITest types the container.
        let samSeat = app.descendants(matching: .any)["seat-Sam"].firstMatch
        XCTAssertTrue(
            samSeat.waitForExistence(timeout: 10),
            "Seat grid never rendered Sam's claimed seat — the briefing seed is not carrying its RSVPs."
        )

        // The list must stay gone rather than merely scrolled away.
        XCTAssertFalse(
            app.staticTexts["Who's coming"].exists,
            "The Who's coming list is back on the event card (S6 T3)."
        )

        _ = scrollIntoFrame(app, element: samSeat)
        snap(app, "17-briefing-seat-grid")

        samSeat.tap()

        // Match the tail of the caption: the assertion is that both
        // optional parts render, not that the Currently Into part
        // renders a particular way.
        let popoverCaption = app.descendants(matching: .any)["seat-popover-Sam"].firstMatch
        XCTAssertTrue(
            popoverCaption.waitForExistence(timeout: 10),
            "Tapping Sam's claimed seat did not open the seat popover (S6 T4)."
        )
        XCTAssertTrue(
            popoverCaption.label.contains("with Alex"),
            "Seat popover lost the anchor: got '\(popoverCaption.label)'."
        )
        XCTAssertTrue(
            popoverCaption.label.contains("first night"),
            "Seat popover lost the first-night part: got '\(popoverCaption.label)'."
        )
        snap(app, "17-seat-popover-brought-by")
    }

    // MARK: - 18 Host pending invites carry the anchor (V0.107)

    func test_18_host_pending_invites_via() throws {
        let app = launchSweep(arguments: ["-screenshots-state=briefing"])

        openRoom(app, named: "Carwoola Crew")

        // The Members section is collapsed on the room page; the plus
        // on its header is the one-tap path in (it mints a code, so
        // the section is also the host's invite surface).
        let plus = app.buttons["members-invite"]
        XCTAssertTrue(
            scrollIntoFrame(app, element: plus),
            "Members invite plus never scrolled into view on the room page."
        )
        plus.tap()

        let pending = app.staticTexts["Pending invites"].firstMatch
        XCTAssertTrue(
            pending.waitForExistence(timeout: 10),
            "Pending invites never rendered — Sam's tier-2 roster row is not being read."
        )
        let via = app.staticTexts["via Alex"].firstMatch
        XCTAssertTrue(
            via.waitForExistence(timeout: 5),
            "Pending invite is missing the \"via Alex\" line (spec §2, A6)."
        )

        _ = scrollIntoFrame(app, element: via)
        snap(app, "18-host-pending-invites-via")
    }
}
