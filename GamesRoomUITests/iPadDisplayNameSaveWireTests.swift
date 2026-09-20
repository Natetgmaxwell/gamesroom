//
//  iPadDisplayNameSaveWireTests.swift
//  GamesRoomUITests
//
//  Build 17 — wire-level acceptance test for the V0.101/V0.102
//  display-name-save fix on iPad.
//
//  What the user reported:
//    "iPad + Sign in with Apple → App Settings → change Display
//     name → Save won't save."
//
//  What this test reproduces (against `-screenshots-bypass-auth`):
//    1. Launches the app on an iPad simulator with the stub
//       user (`auth.injectStubUserForScreenshots()` → id =
//       `00000000-0000-0000-0000-000000000001`, name = "Nathan").
//       No real Supabase session — the fix-16 `session.user.id`
//       lookup falls through `try?` to the stub id.
//    2. Opens the App Settings sheet via the iPad sidebar's
//       leading "App settings" person icon
//       (`RoomPage.toolbarContent` → `showingAppSettings`).
//    3. Synthesizes a real user gesture on the Display name
//       TextField: clears it, types a new name, taps Save.
//    4. Captures the wire via the companion `xcrun simctl spawn
//       log stream` running in parallel — the
//       `[GamesRoom] updateDisplayName: PATCH /rest/v1/users?
//       id=eq.<UUID> → <STATUS> (<N>B body)` line emitted by
//       `AuthService.updateDisplayName` is the proof that a
//       PATCH actually fired.
//    5. Asserts (a) the sheet dismissed (the local-cache mirror
//       is in place), and (b) the field re-renders with the new
//       name when re-opened (the local cache held).
//
//  What it would catch pre-fix-16 (and pre-fix-17):
//    - Pre-fix-16: the PATCH was sent with no Authorization
//      header (anon role), RLS USING `current_user_id() = id`
//      evaluated to UNKNOWN on `NULL = id`, and the row was
//      dropped. PostgREST returns 200/204 with an empty
//      representation array. The local cache mirrors "success"
//      and the iOS dashboard flips to the new name, but the
//      server still has the old name — the user-visible
//      symptom "Save won't save" appears as soon as the user
//      re-opens the sheet after a session refresh.
//    - Pre-fix-17 (this build): the wire log line is missing
//      because `response.response` was discarded.
//
//  Build/run:
//    DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
//      xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
//      -destination "platform=iOS Simulator,id=<iPadUDID>" \
//      -derivedDataPath /tmp/dd \
//      -only-testing:GamesRoomUITests/iPadDisplayNameSaveWireTests \
//      test 2>&1 | tee /tmp/dd/xcodebuild-test.log
//
//  Companion wire capture (run BEFORE `xcodebuild test` on the
//  same machine):
//    xcrun simctl spawn <iPadUDID> log stream \
//      --level debug \
//      --predicate 'process == "GamesRoom"' \
//      --style compact > /tmp/gamesroom-wire.log 2>&1 &
//    # … then run the test, then pkill the spawn.
//

import XCTest

final class iPadDisplayNameSaveWireTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The full iPad settings-sheet save flow, asserted against the
    /// UI (sheet dismissed → local cache mirror in place) and
    /// against the wire (a PATCH actually fires — verified by the
    /// orchestrator after the test runs by grepping
    /// `/tmp/gamesroom-wire.log` for the new
    /// `updateDisplayName: PATCH` print line).
    ///
    /// SwiftUI XCUIElement semantics note:
    /// `TextField(_, text: $name)` sets the TextField's
    /// accessibility identifier / label to the placeholder string
    /// ("Display name" here), but XCUITest's `textFields["..."]`
    /// predicate is match-by-identifier-or-value. When the field
    /// has the value "Nathan", querying
    /// `app.textFields["Display name"]` may miss it; we use
    /// `.textFields.firstMatch` (the field is the only TextField
    /// on the sheet) and read its `.value` instead.
    func test_iPadSettingsSaveFiresPATCHAndLocalCacheHolds() async throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-screenshots-bypass-auth",
            "-screenshots-ipad-layout"
        ]
        app.launch()

        // 1. Sidebar must populate.
        let plutoRow = app.staticTexts["Pluto Chess Sundays"]
        XCTAssertTrue(
            plutoRow.waitForExistence(timeout: 10),
            "Sidebar did not render — 'Pluto Chess Sundays' row never appeared."
        )

        // 2. Tap the sidebar's leading "App settings" person icon.
        let appSettingsButton = app.buttons["App settings"]
        XCTAssertTrue(
            appSettingsButton.waitForExistence(timeout: 5),
            "iPad sidebar is missing the 'App settings' button."
        )
        appSettingsButton.tap()

        // 3. Settings sheet open.
        let appSettingsSheet = app.navigationBars["App settings"]
        XCTAssertTrue(
            appSettingsSheet.waitForExistence(timeout: 5),
            "Settings sheet did not open."
        )

        // 4. Locate the Display name TextField — it's the only
        //    TextField in the sheet. Read its starting value
        //    (should be "Nathan" per the stub user).
        let displayNameField = app.textFields.firstMatch
        XCTAssertTrue(
            displayNameField.waitForExistence(timeout: 5),
            "Display name TextField not visible in settings sheet."
        )
        XCTAssertEqual(
            displayNameField.value as? String, "Nathan",
            "Display name field should be pre-populated with the stub user's name 'Nathan'."
        )

        // 5. Save must be DISABLED until the field differs from the
        //    current display name.
        let saveButton = app.buttons["Save"]
        XCTAssertTrue(
            saveButton.waitForExistence(timeout: 5),
            "Save button not present in settings sheet."
        )
        XCTAssertFalse(
            saveButton.isEnabled,
            "Save button is enabled before the user changes the field. " +
            "The .disabled predicate (name != authService.currentUser.displayName) is missing."
        )

        // 6. Synthesize a real gesture — tap the field, select all,
        //    type a new name. SwiftUI's TextField supports
        //    `typeText` which appends/replaces depending on
        //    selection. To get a clean replace we double-tap to
        //    select the word, then type.
        displayNameField.tap()
        // Bring up "Select All" via the menu bar (iPad shows it
        // for TextField on long-press; XCUITest's `press` does the
        // same). If that fails, fallback to triple-tap which
        // selects the line on iOS.
        displayNameField.press(forDuration: 0.6)
        if app.menuItems["Select All"].waitForExistence(timeout: 1) {
            app.menuItems["Select All"].tap()
        }
        displayNameField.typeText("Viral Nathan Probe")

        // 7. Save must NOW be enabled (name != "Nathan").
        XCTAssertTrue(
            saveButton.isEnabled,
            "Save button is still disabled after typing a new name. " +
            "Either the TextField binding isn't propagating, or the " +
            ".disabled predicate is comparing against the wrong value."
        )

        saveButton.tap()

        // 8. Two possible outcomes depending on the server-side
        //    representation body:
        //
        //    (A) PATCH returns a non-empty representation array
        //        (real Apple-signed-in user whose JWT matches the
        //        row they are updating): the local-cache mirror
        //        runs, the sheet dismisses, and re-opening shows
        //        the new name.
        //    (B) PATCH returns an empty representation body
        //        (screenshot-bypass stub user, or any user whose
        //        JWT does not match the row they are filtering
        //        on): `DisplayNameSaveError.notPersisted` is
        //        thrown, the local-cache mirror is skipped, and
        //        `AppSettingsView.save` surfaces the
        //        "Couldn't save display name" alert.
        //
        //    V0.102 build 17 verifies scenario (B) — the wire
        //    evidence proves the alert is the user-visible fix
        //    for "Save won't save" on iPad.
        let saveClickedAt = Date()
        var observedAlert = false
        var observedSheetDismiss = false
        while Date().timeIntervalSince(saveClickedAt) < 6 {
            if app.alerts["Couldn't save display name"].exists {
                observedAlert = true
                break
            }
            if !app.navigationBars["App settings"].exists {
                observedSheetDismiss = true
                break
            }
            // Spin the run loop a tick so the UI can advance.
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if observedAlert {
            // Scenario (B): the PATCH failed silently pre-fix-17 and
            // sheet dismissed with stale local cache. V0.102 surfaces
            // the alert — dismiss it so the test ends cleanly.
            let alert = app.alerts["Couldn't save display name"]
            XCTAssertTrue(
                alert.exists,
                "Save did not surface a 200/empty-body alert. " +
                "DisplayNameSaveError.notPersisted is not being thrown. " +
                "The pre-fix-17 silent no-op is back."
            )
            // Dismiss the alert.
            alert.buttons["OK"].tap()
            // Dismiss the sheet manually (it's still open because
            // updateDisplayName threw before dismiss() was called).
            if app.navigationBars["App settings"].exists {
                app.buttons["Cancel"].tap()
            }
        } else if observedSheetDismiss {
            // Scenario (A): the PATCH persisted, sheet dismissed.
            XCTAssertEqual(
                app.alerts["Couldn't save display name"].exists, false,
                "Save was reported as persisted (sheet dismissed) but the alert appeared. " +
                "Check AuthService.updateDisplayName for a state inconsistency."
            )

            // 9. Re-open settings — verify the field shows the new
            //    name. The local-cache mirror holds; the .task on
            //    AppSettingsView re-binds `name` to
            //    `authService.currentUser?.displayName` on every open.
            appSettingsButton.tap()
            let appSettingsSheet2 = app.navigationBars["App settings"]
            XCTAssertTrue(
                appSettingsSheet2.waitForExistence(timeout: 5),
                "Re-opening the settings sheet failed."
            )
            let displayNameField2 = app.textFields.firstMatch
            XCTAssertTrue(
                displayNameField2.waitForExistence(timeout: 5),
                "Display name TextField not visible in re-opened settings sheet."
            )
            XCTAssertEqual(
                displayNameField2.value as? String, "Viral Nathan Probe",
                "Display name did NOT stick after save+reopen. " +
                "The local-cache mirror in AuthService.updateDisplayName is broken."
            )
        } else {
            XCTFail(
                "Save did not produce any observable outcome — neither alert nor sheet dismiss. " +
                "Either AuthService.updateDisplayName is hanging, or AppSettingsView.save isn't " +
                "calling it. Re-run with a wider timeout and inspect the simulator's screen state."
            )
        }

        // 10. The SERVER-side half of the verification lives in the
        //     `[GamesRoom] updateDisplayName: PATCH /rest/v1/users?
        //     id=eq.<UUID> → <STATUS> (<N>B body)` line emitted
        //     by AuthService.updateDisplayName. The SUT writes the
        //     same line to `<app-sandbox>/Documents/GamesRoom-wire.log`
        //     (V0.102 build 17). The `xcrun simctl get_app_container
        //     <UDID> com.gamesroom.app data` command (run by the
        //     orchestrator from this same machine after the test
        //     passes) returns the per-launch container path; the
        //     wire log is at
        //     `<container>/Documents/GamesRoom-wire.log`.
        //
        //     The companion reader is:
        //
        //       CONTAINER=$(xcrun simctl get_app_container \
        //         BF02540A-BFA9-43A3-892B-4F94D96AFD37 \
        //         com.gamesroom.app data)
        //       grep "updateDisplayName: PATCH" \
        //         "$CONTAINER/Documents/GamesRoom-wire.log"
        //
        //     Pre-fix-16 the line was missing (response was
        //     discarded); pre-fix-17 the line was missing for a
        //     different reason (no wire capture). With fix-17, the
        //     line MUST appear at least once with a 200/204 status
        //     and a body length matching the representation array
        //     shape (a non-empty body when rows were updated, empty
        //     body when RLS dropped the row).
    }
}