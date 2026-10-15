//
//  MembersInvitePlusTests.swift
//  GamesRoomUITests
//
//  v1.2.1: the Members "Invite a friend" text row became a plus on
//  the section header. This drives it against the seeded
//  InMemoryRoomStore (`-screenshots-bypass-auth`, Test Sandbox, host
//  role): the plus carries the VoiceOver name, no visible invite text
//  remains, and one tap opens Members with a fresh code to share.
//
//  Run:
//    xcodebuild test -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
//      -only-testing:GamesRoomUITests/MembersInvitePlusTests
//

import XCTest

final class MembersInvitePlusTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test_plusOnMembersHeaderMintsAnInviteCode() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-screenshots-bypass-auth"]
        app.launch()

        let room = app.staticTexts["Test Sandbox"].firstMatch
        XCTAssertTrue(room.waitForExistence(timeout: 20), "Test Sandbox row never appeared")
        for _ in 0..<4 where !room.isHittable { app.swipeUp(velocity: .slow) }
        room.tap()

        let readerDone = app.buttons["reader-card-done"]
        if readerDone.waitForExistence(timeout: 4) { readerDone.tap() }

        let plus = app.buttons["members-invite"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "Members plus missing")
        for _ in 0..<5 where !plus.isHittable { app.swipeUp(velocity: .slow) }
        XCTAssertEqual(plus.label, "Invite a friend", "VoiceOver name must stay 'Invite a friend'")
        XCTAssertFalse(app.staticTexts["Invite a friend"].exists, "The visible invite text row must be gone")
        XCTAssertFalse(app.buttons["Share invite code"].exists, "No code before the tap")

        plus.tap()

        let share = app.buttons["Share invite code"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "Tapping the plus must mint and show an invite code")
        XCTAssertTrue(app.buttons["Copy invite code"].exists, "Copy action rides with the code")
        XCTAssertTrue(app.buttons["Members"].exists, "Members header stays the toggle")
    }
}
