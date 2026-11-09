//
//  DeviceStateKeys.swift
//  GamesRoom
//
//  The registry of everything THIS DEVICE keeps for a signed-in
//  member, and the one matcher the sign-out sweep uses (audit 04 D6).
//
//  Why a registry and not a list at the call site: sign-out used to
//  remove `lastViewedRoomId` and nothing else. Pending briefing
//  notifications from the previous user kept firing (their bodies
//  carry event names — a privacy smell, not just stale state), their
//  Live Activity kept running, and `calendarRowIdentifiers`,
//  `briefingOnCreateFiredLedger`, `notifPromptAnswered.*`,
//  `claimReminderAskAnswered.*`, `roomTimeZoneReported.*` all
//  survived. A key that is not in this registry is a key the next
//  account inherits.
//
//  Foundation-only so the unit runner can prove the coverage.
//

import Foundation

enum DeviceStateKeys {

    /// Keys written by `StorageKeys` consumers that belong to the
    /// signed-in ACCOUNT. Cleared on sign-out and on account delete.
    static let exact: [String] = [
        StorageKeys.lastViewedRoomId,
        StorageKeys.calendarRowIdentifiers,
        UserDefaultsOnCreateLedger.key
    ]

    /// Per-room and per-event key families. Each entry is the key the
    /// owning helper builds minus the id it appends, so the strings
    /// come from the same builders the writes use.
    static var prefixes: [String] {
        [
            prefix(of: StorageKeys.memberNotePromptDismissed(eventId: sentinel)),
            prefix(of: StorageKeys.claimReminderAskAnswered(roomId: sentinel)),
            prefix(of: StorageKeys.roomTimeZoneReported(roomId: sentinel)),
            prefix(of: StorageKeys.notifPromptAnswered(roomId: sentinel))
        ]
    }

    /// Everything this device persists for an account: exact keys and
    /// key families.
    static var all: [String] { exact + prefixes }

    /// True when `key` belongs to the signed-in account and must not
    /// survive a sign-out.
    static func matchesPersistedKey(_ key: String) -> Bool {
        exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }

    /// Drops every account-scoped key from `defaults`. Device
    /// preferences (`StorageKeys.devicePreferences`) are untouched:
    /// they describe the phone, not the person.
    static func removeAll(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
        where matchesPersistedKey(key) {
            defaults.removeObject(forKey: key)
        }
    }

    /// A fixed UUID used only to render a builder's key and strip the
    /// id back off it.
    private static let sentinel = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    private static func prefix(of key: String) -> String {
        key.replacingOccurrences(of: sentinel.uuidString, with: "")
    }
}
