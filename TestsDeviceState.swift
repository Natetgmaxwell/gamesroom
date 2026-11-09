//
//  TestsDeviceState.swift
//  GamesRoom
//
//  Tests for the device-state registry and the sign-out purge
//  (audit 04 D6), compiled into the Foundation test binary by
//  build-and-run-tests.sh and invoked from main.swift via
//  runDeviceStateTests().
//
//  The registry exists so a key cannot be added to `StorageKeys`
//  without a decision: purge it on sign-out, or declare it a device
//  preference that outlives the account. The coverage test fails on a
//  key that has neither.
//

import Foundation

func runDeviceStateTests() {
    let sentinelRoom = UUID()
    let sentinelEvent = UUID()

    // Every key StorageKeys owns is either purged or declared a device
    // preference. A new key with neither fails here.
    runner.run("device state: the registry covers every account-scoped StorageKeys key") {
        let covered = Set(DeviceStateKeys.exact)
        let kept = Set(StorageKeys.devicePreferences)
        for key in StorageKeys.persistedKeys {
            if kept.contains(key) { continue }
            runner.assertTrue(
                covered.contains(key),
                "\(key) is written to the device but not purged on sign-out"
            )
        }
        runner.assertEqual(StorageKeys.persistedKeys.count, 3)
    }

    // The on-create ledger and the calendar row map are the two
    // account-scoped keys with no per-id family.
    runner.run("device state: registry owns the ledger and calendar keys") {
        runner.assertTrue(DeviceStateKeys.matchesPersistedKey(StorageKeys.calendarRowIdentifiers))
        runner.assertTrue(DeviceStateKeys.matchesPersistedKey(UserDefaultsOnCreateLedger.key))
        runner.assertTrue(DeviceStateKeys.matchesPersistedKey(StorageKeys.lastViewedRoomId))
    }

    // Every per-room / per-event prompt flag, built by the same helper
    // the write uses.
    runner.run("device state: every prompt helper's key is matched") {
        let keys = [
            StorageKeys.memberNotePromptDismissed(eventId: sentinelEvent),
            StorageKeys.claimReminderAskAnswered(roomId: sentinelRoom),
            StorageKeys.roomTimeZoneReported(roomId: sentinelRoom),
            StorageKeys.notifPromptAnswered(roomId: sentinelRoom)
        ]
        for key in keys {
            runner.assertTrue(
                DeviceStateKeys.matchesPersistedKey(key),
                "\(key) survives a sign-out"
            )
        }
    }

    // No over-reach: a device preference and an unrelated key are not
    // touched.
    runner.run("device state: the matcher does not over-reach") {
        runner.assertFalse(DeviceStateKeys.matchesPersistedKey(StorageKeys.keepScanPhotos))
        runner.assertFalse(DeviceStateKeys.matchesPersistedKey("somethingElse"))
        runner.assertFalse(
            DeviceStateKeys.matchesPersistedKey("x-notifPromptAnswered.\(sentinelRoom.uuidString)")
        )
    }

    // The sweep removes exactly the registry's keys from a defaults
    // store and leaves the rest.
    runner.run("device state: removeAll clears the registry and nothing else") {
        let suite = "test-device-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let noteKey = StorageKeys.memberNotePromptDismissed(eventId: sentinelEvent)
        let promptKey = StorageKeys.notifPromptAnswered(roomId: sentinelRoom)
        defaults.set("room-id", forKey: StorageKeys.lastViewedRoomId)
        defaults.set(["event": "ek-row"], forKey: StorageKeys.calendarRowIdentifiers)
        defaults.set(["event-on_create-user"], forKey: UserDefaultsOnCreateLedger.key)
        defaults.set(true, forKey: noteKey)
        defaults.set(true, forKey: promptKey)
        defaults.set(true, forKey: StorageKeys.keepScanPhotos)
        defaults.set("keep-me", forKey: "somethingElse")

        DeviceStateKeys.removeAll(in: defaults)

        runner.assertNil(defaults.string(forKey: StorageKeys.lastViewedRoomId))
        runner.assertNil(defaults.dictionary(forKey: StorageKeys.calendarRowIdentifiers))
        runner.assertNil(defaults.stringArray(forKey: UserDefaultsOnCreateLedger.key))
        runner.assertFalse(defaults.bool(forKey: noteKey))
        runner.assertFalse(defaults.bool(forKey: promptKey))
        runner.assertTrue(defaults.bool(forKey: StorageKeys.keepScanPhotos))
        runner.assertEqual(defaults.string(forKey: "somethingElse"), "keep-me")

        defaults.removePersistentDomain(forName: suite)
    }
}
