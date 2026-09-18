//
//  iPadNoRedundantTopNavTests.swift
//  GamesRoomUITests
//
//  Acceptance test for the iPad redundant "Rooms & Settings" top
//  nav regression (build 13). User report: "remove the rooms &
//  settings nav at the top, it seems to be duplicated and now
//  redundant."
//
//  Pre-fix iPad layout: ContentView wrapped RoomPage + SettingsPage
//  in a two-tab `TabView`. iPadOS renders a TabView as a top tab
//  bar (Rooms / Settings) — duplicated chrome, because the iPad
//  split-view's sidebar already owned room selection AND the
//  Settings content was a separate tab the user had to leave the
//  sidebar to reach.
//
//  Post-fix iPad layout (V0.100): ContentView mounts RoomPage
//  directly on iPad regular width (no TabView). Settings is
//  reachable from a single gear in the sidebar's leading toolbar
//  slot (RoomPage.toolbarContent). iPhone keeps the V0.8 TabView
//  untouched.
//
//  What this test proves:
//    1. On iPad (regular width, no screenshot flags), the top tab
//       bar is GONE — the user does NOT see "Rooms" and "Settings"
//       as tab-bar labels at the top of the iPad layout.
//    2. The App Settings gear is reachable on iPad via the
//       sidebar's leading toolbar slot — tapping it opens the
//       settings sheet. Single way to reach Settings per
//       form factor (the rule the user requested).
//
//  Build/run:
//    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//      xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination "platform=iOS Simulator,id=<iPadUDID>" \
//      -derivedDataPath /tmp/dd \
//      -only-testing:GamesRoomUITests/iPadNoRedundantTopNavTests \
//      test
//

import XCTest

final class iPadNoRedundantTopNavTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// On iPad (regular width, bypass-auth), the sidebar owns
    /// navigation. Assert:
    ///   (a) The Rooms / Settings top tab bar is gone.
    ///   (b) Tapping the leading App Settings gear opens the
    ///       App settings sheet (the single Settings path on
    ///       iPad).
    ///
    /// The tab bar on iPadOS shows tab-bar buttons labelled with
    /// the tab's title. A pre-fix build shows TWO tab buttons
    /// ("Rooms" and "Settings") in the top tab bar. After the
    /// fix, NEITHER appears as a tab bar button — `tabBars` should
    /// contain neither label.
    func test_iPadSidebarHasNoTopTabBarAndSettingsReachableViaLeadingGear() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-screenshots-bypass-auth"
        ]
        app.launchArguments += [
            "-screenshots-ipad-layout"
        ]

        app.launch()

        // Sidebar must populate.
        let plutoRow = app.staticTexts["Pluto Chess Sundays"]
        XCTAssertTrue(
            plutoRow.waitForExistence(timeout: 10),
            "Sidebar did not render — 'Pluto Chess Sundays' row never appeared."
        )

        // (a) The Rooms / Settings top tab bar is gone.
        //
        // On iPadOS a TabView at the root renders a top tab bar
        // whose buttons carry the tab titles. After the fix, no
        // such tab bar exists at the iPad root. Assert the
        // "Rooms" / "Settings" labels are NOT tab-bar buttons.
        let tabBars = app.tabBars
        let roomsTab = tabBars.buttons["Rooms"]
        let settingsTab = tabBars.buttons["Settings"]

        XCTAssertFalse(
            roomsTab.exists,
            "iPad layout still shows a top 'Rooms' tab bar — ContentView " +
            "is wrapping RoomPage in a TabView on iPad. V0.100 fix missing."
        )
        XCTAssertFalse(
            settingsTab.exists,
            "iPad layout still shows a top 'Settings' tab bar — ContentView " +
            "is wrapping SettingsPage in a TabView on iPad. V0.100 fix missing."
        )

        // (b) The App Settings gear is reachable on iPad via the
        // sidebar's leading toolbar slot. Tapping it opens the
        // settings sheet. The sheet's nav title is "App settings"
        // (AppSettingsView.navigationTitle).
        let appSettingsButton = app.buttons["App settings"]
        XCTAssertTrue(
            appSettingsButton.waitForExistence(timeout: 5),
            "iPad sidebar is missing the App settings gear — the single " +
            "Settings path on iPad is unreachable."
        )

        appSettingsButton.tap()

        let appSettingsSheet = app.navigationBars["App settings"]
        XCTAssertTrue(
            appSettingsSheet.waitForExistence(timeout: 5),
            "Tapping the iPad sidebar's App settings gear did not open " +
            "the settings sheet."
        )
    }
}
