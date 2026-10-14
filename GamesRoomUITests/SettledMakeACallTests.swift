//
//  SettledMakeACallTests.swift
//  GamesRoomUITests
//
//  V1.2 slice 2b item 2 (docs/v1.2-settled-view-spec.md): the host's
//  Tonight's Star call moved from an inline form on the settled hero
//  into a sheet behind "Make a call". This drives the moved flow end
//  to end against the seeded InMemoryRoomStore
//  (`-screenshots-bypass-auth -screenshots-state=settled`, host role):
//  open the sheet, pick a member and a reason, save, and read the
//  new call back off the hero.
//
//  Run:
//    xcodebuild test -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:GamesRoomUITests/SettledMakeACallTests
//

import XCTest

final class SettledMakeACallTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_hostMakesACallFromTheSheetAndHeroShowsIt() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-screenshots-bypass-auth", "-screenshots-state=settled"]
        app.launch()

        let room = app.staticTexts["Carwoola Crew"].firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 20), "Carwoola Crew row never appeared")
        room.tap()

        let readerDone = app.buttons["reader-card-done"]
        if readerDone.waitForExistence(timeout: 4) { readerDone.tap() }

        let makeACall = app.buttons["make-a-call"]
        XCTAssertTrue(makeACall.waitForExistence(timeout: 10), "Make a call missing on the settled hero")
        XCTAssertFalse(app.buttons["Save the call"].exists, "The inline call form must be gone from the hero")
        makeACall.tap()

        let save = app.navigationBars["Tonight's Star"].buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5), "Call sheet never opened")
        XCTAssertTrue(app.collectionViews.buttons["Alex"].firstMatch.isSelected, "The current star should be preselected")

        app.collectionViews.buttons["Sam"].firstMatch.tap()
        app.collectionViews.buttons["Good sport"].firstMatch.tap()
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5), "Save must close the sheet")

        let line = app.staticTexts["Sam lost every pot and still had the table laughing."]
        XCTAssertTrue(line.waitForExistence(timeout: 5), "The saved call never reached the hero")
    }
}
