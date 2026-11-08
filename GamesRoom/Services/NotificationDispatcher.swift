//
//  NotificationDispatcher.swift
//  GamesRoom
//
//  Track D2 — iOS UNUserNotificationCenter wrapper.
//
//  Notification-etiquette fix (2026-11-04): a device schedules
//  briefing notifications for its signed-in user ONLY, and every
//  scheduling path goes through `reconcileBriefing`, which
//  cancels the event's pending requests and re-plans them from
//  the caller's CURRENT canonical RSVP state:
//
//                  claimed       unclaimed      declined
//   ─────────────────────────────────────────────────────────
//   on_create      skip          prompt (once   skip
//                                per install)
//   T-168h         logistics     reminder       skip
//   T-84h          logistics     reminder       skip
//   morning-of     logistics     reminder       skip
//   ─────────────────────────────────────────────────────────
//
//  `declined` is terminal — silence. `claimed` bodies never
//  contain claim language. The on-create prompt fires at most
//  once per (event, user) per install via a UserDefaults
//  fired-ledger (the UN delivered list is not durable — banner
//  dismissal empties it). The decision logic lives in
//  `BriefingReconciler` (Foundation-only, testable); this type is
//  the UNUserNotificationCenter edge.
//
//  Identifiers stay stable per (eventId, cadence, userId) so
//  `cancelBriefingTrio` can sweep by event-id prefix without
//  re-deriving the cadence.
//
//

import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class NotificationDispatcher {

    // MARK: - Singleton

    static let shared = NotificationDispatcher()

    // MARK: - State

    /// Tracks whether `requestAuthorization` has already been asked
    /// for this app install. iOS will only ever prompt once; if the
    /// user denied, the schedule methods fall through to a no-op.
    /// Keeping a flag avoids spamming the system call on every event.
    private var hasRequestedAuthorization = false

    private init() {}

    // MARK: - Authorization

    /// Requests `.alert`, `.sound`, `.badge` once per app install.
    /// Safe to call repeatedly: it short-circuits if the OS has
    /// already answered the prompt or we've already asked.
    ///
    /// Returns `true` only when the OS reports authorized/provisional/
    /// ephemeral. Denied or undetermined-but-rejected callers get `false`.
    @discardableResult
    private func requestAuthorizationIfNeeded() async -> Bool {
        if hasRequestedAuthorization {
            return true
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            hasRequestedAuthorization = true
            return true
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
                )
                hasRequestedAuthorization = true
                return granted
            } catch {
                hasRequestedAuthorization = true
                return false
            }
        case .denied:
            hasRequestedAuthorization = true
            return false
        @unknown default:
            hasRequestedAuthorization = true
            return false
        }
    }

    // MARK: - Reconcile (the one scheduling entry point)

    /// Reconcile this device's briefing notifications for one
    /// event against the signed-in user's CURRENT canonical RSVP
    /// state: cancel every pending request for the event, then
    /// re-plan (claimed = logistics only, unclaimed = reminder +
    /// once-per-install on-create prompt, declined = silence).
    ///
    /// Every path that wants briefing notifications on this device
    /// routes through here — addEvent, realtime INSERT, room open,
    /// claim (escrow and plain), claim-waived (when the affected
    /// member is this device's user), decline/release, mute and
    /// opt-in toggles (via `RoomService.reconcileBriefing`).
    ///
    /// When a session exists, the on-create body (and only it) is
    /// LLM-generated via the `mascot-voice` edge function; every
    /// other body comes from the deterministic template matrix.
    func reconcileBriefing(
        eventId: UUID,
        roomId: UUID,
        eventName: String,
        playedAt: Date,
        mascotName: String,
        userId: UUID,
        memberName: String?,
        state: MemberRSVPState,
        hostNote: String? = nil,
        mascotPersonality: MascotPersonality = .friendly,
        mascotIdeology: MascotPoliticalIdeology = .centrist,
        mascotState: RoomState? = nil
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }

        var faceAttachment: UNNotificationAttachment?
        if let mascotState {
            faceAttachment = await MascotNotificationAttachment.attachment(
                personality: mascotPersonality,
                ideology: mascotIdeology,
                state: mascotState
            )
        }

        let sink = UNCenterSink(attachment: faceAttachment, roomId: roomId)
        let ledger = UserDefaultsOnCreateLedger(
            defaults: .standard
        )

        // The on-create body is LLM-voiced when a session exists.
        // The provider runs only when the prompt will actually
        // fire (unclaimed, not yet fired this install).
        let authToken = await SupabaseClientProvider.currentSession()?.accessToken
        var onCreateBodyProvider: (() async -> String)?
        if let authToken, !authToken.isEmpty {
            let context = MascotEngine.RoomContext(
                activeEventTitle: eventName,
                lastEventDaysAgo: nil,
                memberCount: 1,
                memberNames: memberName.map { [$0] } ?? [],
                memberName: memberName
            )
            onCreateBodyProvider = {
                await MascotEngine.generateVoiceLLM(
                    mascotName: mascotName,
                    roomName: "",
                    personality: mascotPersonality,
                    ideology: mascotIdeology,
                    kind: .briefingOnCreate,
                    context: context,
                    authToken: authToken,
                    roomId: nil,
                    eventId: eventId,
                    eventDate: playedAt,
                    hostNote: hostNote
                )
            }
        }

        await BriefingReconciler.reconcile(
            sink: sink,
            ledger: ledger,
            eventId: eventId,
            eventName: eventName,
            playedAt: playedAt,
            mascotName: mascotName,
            userId: userId,
            memberName: memberName,
            state: state,
            hostNote: hostNote,
            personality: mascotPersonality,
            ideology: mascotIdeology,
            onCreateBodyProvider: onCreateBodyProvider
        )
    }

    /// Cancel every pending notifications requests associated with one
    /// event. Sweeps by event-id prefix so we don't need to know
    /// which RSVP states were scheduled.
    func cancelBriefingTrio(eventId: UUID) async {
        let center = UNUserNotificationCenter.current()
        let prefix = eventId.uuidString
        let pending = await center.pendingNotificationRequests()
        let ids = pending
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: - Joined-late catch-up (W2.7)

    /// Schedules the joined-late catch-up push for one member.
    /// Fires immediately (the member just joined and is looking at
    /// the room). The identifier is stable per event, so a re-join
    /// or a duplicate call overwrites instead of stacking — no
    /// duplicate pushes.
    func scheduleCatchUp(
        eventId: UUID,
        roomId: UUID,
        eventName: String,
        playedAt: Date,
        mascotName: String,
        leaderboardSummary: String,
        rsvpState: MemberRSVPState,
        memberName: String? = nil,
        personality: MascotPersonality = .friendly,
        ideology: MascotPoliticalIdeology = .centrist
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let center = UNUserNotificationCenter.current()
        let body = CatchUpMessage.body(
            eventName: eventName,
            playedAt: playedAt,
            mascotName: mascotName,
            leaderboardSummary: leaderboardSummary,
            rsvpState: rsvpState,
            memberName: memberName,
            personality: personality,
            ideology: ideology
        )
        await schedule(
            center: center,
            identifier: "\\(eventId.uuidString)-catchup",
            title: "\\(mascotName): \\(eventName)",
            body: body,
            kindRaw: NotificationKindRaw.catchUp,
            eventId: eventId,
            roomId: roomId,
            fireAt: Date().addingTimeInterval(1)
        )
    }

    // MARK: - Internal schedule primitive

    /// The `kind` value stored in `userInfo` for downstream handlers
    /// to branch on (e.g. a tap that deep-links into the briefing).
    private enum NotificationKindRaw: String {
        case onCreate = "on_create"
        case t168h = "t168h"
        case t48h = "t48h"
        case morningOf = "morning_of"
        case catchUp = "catch_up"
    }

    private func schedule(
        center: UNUserNotificationCenter,
        identifier: String,
        title: String,
        body: String,
        kindRaw: NotificationKindRaw,
        eventId: UUID,
        roomId: UUID,
        fireAt: Date,
        attachment: UNNotificationAttachment? = nil
    ) async {
        // 2026-09-02 dedupe guard — two paths can schedule the same
        // (event, kind, user) notification on one device. Same
        // identifier among PENDING
        // requests replaces silently, but if the first copy already
        // DELIVERED (the on-create push fires 1s after scheduling),
        // re-adding the same identifier delivers a second banner.
        // Skip when the id is pending OR already delivered.
        let pending = await center.pendingNotificationRequests()
        if pending.contains(where: { $0.identifier == identifier }) {
            return
        }
        let delivered = await center.deliveredNotifications()
        if delivered.contains(where: { $0.request.identifier == identifier }) {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "kind": kindRaw.rawValue,
            "event_id": eventId.uuidString,
            "room_id": roomId.uuidString
        ]
        // V0.95 D — the mascot's face rides on the push (lock-screen
        // thumbnail + expanded banner image). Attachment failure is
        // non-fatal: the notification ships text-only.
        if let attachment {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCenterSink.trigger(for: kindRaw.rawValue, fireAt: fireAt)
        )
        do {
            try await center.add(request)
        } catch {
            // Per-request failure is non-fatal — the next call will
            // overwrite via the same stable identifier, and the
            // UI doesn't depend on a particular push landing.
        }
    }

    // MARK: - Date formatting
    // V0.81 — `humanTime` / `humanWhen` were removed with the
    // plain-logistics push bodies; the voiced bodies carry the
    // date/time via the template placeholders instead.
}

// MARK: - UN center sink

/// `BriefingNotificationSink` adapter over `UNUserNotificationCenter`.
/// The only type that touches the real notification center for
/// briefing scheduling — tests inject a fake sink instead.
/// `UNUserNotificationCenter` is thread-safe; state here is immutable.
private final class UNCenterSink: BriefingNotificationSink, @unchecked Sendable {

    private let center = UNUserNotificationCenter.current()
    private let attachment: UNNotificationAttachment?
    /// The room every request from this sink belongs to. It rides
    /// on the payload so a tap can open the room without a lookup.
    private let roomId: UUID?

    init(attachment: UNNotificationAttachment?, roomId: UUID?) {
        self.attachment = attachment
        self.roomId = roomId
    }

    /// The trigger for one request.
    ///
    /// The "now" prompts (the on-create briefing, the joined-late
    /// catch-up) fire on a one-second INTERVAL, so the push lands
    /// after its body was built — a calendar trigger computed
    /// before the mascot-voice round trip never fires (audit 01 #2).
    /// The timed reminders keep their fixed local date-time.
    static func trigger(
        for kindRaw: String, fireAt: Date
    ) -> UNNotificationTrigger {
        switch BriefingReconciler.fireMode(kindRaw: kindRaw, fireAt: fireAt) {
        case .shortly:
            return UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        case .at(let date):
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            return UNCalendarNotificationTrigger(
                dateMatching: components, repeats: false
            )
        }
    }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map(\.request.identifier)
    }

    func removePending(identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(
        identifier: String,
        title: String,
        body: String,
        kindRaw: String,
        eventId: UUID,
        fireAt: Date
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var userInfo: [String: String] = [
            "kind": kindRaw,
            "event_id": eventId.uuidString
        ]
        if let roomId {
            userInfo["room_id"] = roomId.uuidString
        }
        content.userInfo = userInfo
        if let attachment {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCenterSink.trigger(for: kindRaw, fireAt: fireAt)
        )
        Task {
            do {
                try await center.add(request)
            } catch {
                // Per-request failure is non-fatal — the next
                // reconcile overwrites via the same stable
                // identifier.
            }
        }
    }
}
