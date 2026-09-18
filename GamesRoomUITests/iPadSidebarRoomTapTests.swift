//
//  iPadSidebarRoomTapTests.swift
//  GamesRoomUITests
//
//  Acceptance test for the iPad sidebar tap regression (builds 11/12).
//
//  History:
//    - Build 11 shipped with a "tag fix" (.tag(room) on the
//      NavigationLink rows) that the orchestrator's sim verification
//      confirmed by setting `selectedRoom` programmatically and
//      screenshotting the detail pane. That verification did NOT
//      synthesize a real tap on the sidebar row — it drove the
//      binding by hand. As a result the test passed while the actual
//      user gesture was still dead on hardware (iPad Air M1, fresh
//      install).
//    - Build 12 swaps NavigationLink(value:) for plain rows so
//      List(selection:) + .tag owns the tap natively. This test
//      proves that a *real synthesized tap* on a sidebar row:
//        1. Drives the detail pane to render RoomDetailView for the
//           tapped room (asserted via the nav-bar title which is
//           `liveRoom.name`).
//        2. Switches the detail when a DIFFERENT room is tapped.
//
//  Verification rule this enforces (from the project brain):
//  "UI-fix verification must synthesize the real input (tap via
//   XCUITest), never drive state programmatically."
//
//  Run from the repo root after `xcodegen generate`:
//    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//      xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination "platform=iOS Simulator,id=<iPadUDID>" \
//      -derivedDataPath /tmp/dd \
//      -only-testing:GamesRoomUITests/iPadSidebarRoomTapTests \
//      test
//

import XCTest

final class iPadSidebarRoomTapTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The real-synthesized-tap acceptance test.
    ///
    /// What it does:
    ///   1. Launches the app on an iPad simulator with the
    ///      `-screenshots-bypass-auth` flag (DEBUG-only), which
    ///      swaps the live Supabase store for `InMemoryRoomStore`
    ///      (4 seeded rooms: Carwoola Crew, Pluto Chess Sundays,
    ///      Felt Faction, Friday Night Hold'em).
    ///   2. Waits for the sidebar to be populated.
    ///   3. **Synthesizes a real tap** on the "Pluto Chess Sundays"
    ///      row — same gesture a user's finger would generate.
    ///   4. Asserts the detail pane's nav bar shows "Pluto Chess
    ///      Sundays" — proves the sidebar tap drove selection,
    ///      which drove the detail render.
    ///   5. **Synthesizes a second tap** on a DIFFERENT room
    ///      ("Felt Faction") — proves the sidebar selection can
    ///      switch, not just initially select.
    ///   6. Asserts the detail pane switched to "Felt Faction" and
    ///      Pluto is no longer the active detail.
    func test_sidebarTapDrivesDetailPaneAndSecondTapSwitches() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-screenshots-bypass-auth"
        ]

        // Force the real iPad split-view layout. Do NOT also pass
        // -screenshots-ipad-column — that flag forces the iPhone
        // column-on-iPad layout (an App Store Connect screenshot
        // workaround) which would defeat the whole point of this
        // test.
        app.launch()

        // Sidebar lives in the leading column. The room names come
        // from InMemoryRoomStore's seed (see
        // InMemoryRoomStore.swift:197+ — names are literal strings
        // and not localized, so XCUIApplication.staticTexts matches
        // them exactly).
        let plutoRow = app.staticTexts["Pluto Chess Sundays"]
        let feltRow = app.staticTexts["Felt Faction"]

        // Wait for the sidebar to populate. The bypass store seeds
        // synchronously, but the sidebar still has to render
        // after RoomPage's .task fetches them into roomService.rooms.
        XCTAssertTrue(
            plutoRow.waitForExistence(timeout: 10),
            "Sidebar did not render — 'Pluto Chess Sundays' row never appeared. " +
            "Bypass-auth or InMemoryRoomStore may be broken; check launch args."
        )

        // FIRST TAP — real synthesized tap on Pluto Chess Sundays.
        plutoRow.tap()

        // Assert the detail pane now shows Pluto. RoomDetailView
        // renders `.navigationTitle(liveRoom.name)` (RoomDetailView.swift:284),
        // so the title appears as a nav-bar element. Allow a few
        // seconds for the detail view to render.
        let plutoDetail = app.navigationBars["Pluto Chess Sundays"]
        XCTAssertTrue(
            plutoDetail.waitForExistence(timeout: 5),
            "Detail pane did not show 'Pluto Chess Sundays' after sidebar tap. " +
            "The iPad sidebar tap regression is STILL present — selectedRoom " +
            "was not driven by the row tap."
        )

        // SECOND TAP on a different room — proves selection can switch.
        // If the detail was driven by something OTHER than
        // List(selection:) (e.g. a stale NavigationLink state), this
        // assertion will fail because the detail pane will remain on
        // Pluto even after tapping Felt.
        feltRow.tap()

        let feltDetail = app.navigationBars["Felt Faction"]
        XCTAssertTrue(
            feltDetail.waitForExistence(timeout: 5),
            "Detail pane did not switch to 'Felt Faction' after the second sidebar " +
            "tap. Selection is not being updated when a second row is tapped."
        )

        // And the original selection should no longer be the
        // current detail — guards against a regression where both
        // rooms appear simultaneously or stale nav state lingers.
        XCTAssertFalse(
            app.navigationBars["Pluto Chess Sundays"].exists,
            "Detail pane still shows 'Pluto Chess Sundays' after tapping Felt Faction."
        )
    }
}
