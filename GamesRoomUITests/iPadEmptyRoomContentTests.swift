//
//  iPadEmptyRoomContentTests.swift
//  GamesRoomUITests
//
//  Acceptance test for the iPad empty-room content regression
//  (build 13). User report: "the test rooms stuff inside the room
//  isn't loading, but the felt faction room is." Felt Faction
//  loads because the seeded InMemoryRoomStore gives it an `.ended`
//  season + awards, which routes through `.seasonClose` — the
//  awards card surface. User-created "test rooms" start with zero
//  events, zero leaderboard rows, zero briefings, AND zero
//  seasons, which under the old state machine pinned the detail
//  at `.loading` forever (a spinner on a room that will never
//  load).
//
//  What this test proves:
//    1. Tapping a room with NO events + NO leaderboard + NO
//       season ("Test Sandbox" in the seed) drives the detail to
//       render the empty-state copy ("No nights on the books yet"
//       for hosts, "Standings" for members) within a few seconds
//       — NOT a perpetual spinner.
//    2. The host path surfaces the "Add an event" CTA so the
//       user can immediately schedule the first night without
//       hunting through the toolbar.
//
//  Verification rule this enforces (from the project brain):
//  "UI-fix verification must synthesize the real input (tap via
//   XCUITest), never drive state programmatically."
//
//  Build/run:
//    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//      xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination "platform=iOS Simulator,id=<iPadUDID>" \
//      -derivedDataPath /tmp/dd \
//      -only-testing:GamesRoomUITests/iPadEmptyRoomContentTests \
//      test
//

import XCTest

final class iPadEmptyRoomContentTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Synthesizes a real tap on the "Test Sandbox" sidebar row,
    /// then asserts the host empty-state copy appears (NOT a
    /// perpetual spinner).
    ///
    /// "Test Sandbox" is the cleanest empty-room target in the
    /// InMemoryRoomStore seed (V0.100 addition): no events, no
    /// leaderboard rows, no briefing, no season. Under the
    /// pre-fix state machine, this room pinned `.loading` and
    /// showed only a spinner. The fix flips
    /// `hasLoadedInitialData` after the first refresh resolves so
    /// the state machine resolves to `.readStandings` for
    /// genuinely-empty rooms, and the host path renders the
    /// "No nights on the books yet" copy + "Add an event" CTA.
    func test_emptyRoomRendersEmptyStateNotPerpetualSpinner() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-screenshots-bypass-auth"
        ]

        app.launch()

        let testSandboxRow = app.staticTexts["Test Sandbox"]
        XCTAssertTrue(
            testSandboxRow.waitForExistence(timeout: 10),
            "Sidebar did not render — 'Test Sandbox' row never appeared. " +
            "The V0.100 InMemoryRoomStore seed must include the Test Sandbox " +
            "empty-room for this test to find its target."
        )

        testSandboxRow.tap()

        // Host empty-state copy. "Test Sandbox" is seeded with
        // userRole = .host, so the host branch fires — NOT the
        // legacy member "Standings" copy.
        let hostEmptyState = app.staticTexts["No nights on the books yet"]
            .firstMatch

        // The empty-state copy must appear within a few seconds.
        // A perpetual spinner satisfies this predicate with
        // `false` — that's the regression this test exists to
        // catch.
        XCTAssertTrue(
            hostEmptyState.waitForExistence(timeout: 5),
            "Empty room showed a perpetual spinner. The .loading state machine " +
            "did not transition to .readStandings after the first refresh " +
            "resolved — the V0.100 hasLoadedInitialData gate is missing or broken."
        )

        // And the host path surfaces the CTA so the user can
        // immediately schedule the first night. Belt-and-braces:
        // proves the empty state isn't just placeholder text.
        let addEventCTA = app.buttons["Add an event"].firstMatch
        XCTAssertTrue(
            addEventCTA.waitForExistence(timeout: 3),
            "Host empty state rendered but the 'Add an event' CTA is missing. " +
            "The V0.100 .readStandings host branch is incomplete."
        )
    }
}

