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
    /// context: cancel every pending request this kind owns, then
    /// plan from the context's CANONICAL state and await each add
    /// (claimed = logistics only, unclaimed = reminder +
    /// once-per-install on-create prompt, declined = silence).
    ///
    /// Every path that wants briefing notifications on this device
    /// routes through here — addEvent, realtime INSERT, room open,
    /// claim (escrow and plain), claim-waived (when the affected
    /// member is this device's user), decline/release, mute and
    /// opt-in toggles, and the joined-late catch-up (via
    /// `RoomService.reconcileBriefing`).
    ///
    /// When a session exists, the on-create body (and only it) is
    /// LLM-generated via the `mascot-voice` edge function; every
    /// other body comes from the deterministic template matrix.
    func reconcileBriefing(
        context ctx: BriefingContext,
        mascotState: RoomState? = nil
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }

        var faceAttachment: UNNotificationAttachment?
        if let mascotState {
            faceAttachment = await MascotNotificationAttachment.attachment(
                personality: ctx.personality,
                ideology: ctx.ideology,
                state: mascotState
            )
        }

        let sink = UNCenterSink(attachment: faceAttachment, roomId: ctx.roomId)
        let ledger = UserDefaultsOnCreateLedger(
            defaults: .standard
        )

        // The on-create body is LLM-voiced when a session exists.
        // The provider runs only when the prompt will actually
        // fire (unclaimed, not yet fired this install).
        var onCreateBodyProvider: (() async -> String)?
        if ctx.kind == .cadence,
           let authToken = await SupabaseClientProvider.currentSession()?.accessToken,
           !authToken.isEmpty {
            let context = MascotEngine.RoomContext(
                activeEventTitle: ctx.eventName,
                lastEventDaysAgo: nil,
                memberCount: 1,
                memberNames: ctx.memberName.map { [$0] } ?? [],
                memberName: ctx.memberName
            )
            onCreateBodyProvider = {
                await MascotEngine.generateVoiceLLM(
                    mascotName: ctx.mascotName,
                    roomName: "",
                    personality: ctx.personality,
                    ideology: ctx.ideology,
                    kind: .briefingOnCreate,
                    context: context,
                    authToken: authToken,
                    roomId: nil,
                    eventId: ctx.eventId,
                    eventDate: ctx.playedAt,
                    hostNote: ctx.hostNote
                )
            }
        }

        await BriefingReconciler.reconcile(
            context: ctx,
            sink: sink,
            ledger: ledger,
            onCreateBodyProvider: onCreateBodyProvider
        )
    }

    /// The pre-2026-11-09 signature, kept as a thin adapter so any
    /// untouched call site compiles. It builds a context that cannot
    /// express the room opt-out, the per-event mute or a hidden
    /// night — all three default to "allowed", exactly as before.
    /// Callers that can answer those questions build the context.
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
        await reconcileBriefing(
            context: BriefingContext(
                eventId: eventId,
                roomId: roomId,
                eventName: eventName,
                playedAt: playedAt,
                userId: userId,
                memberName: memberName,
                mascotName: mascotName,
                seat: state,
                hostNote: hostNote,
                kind: .cadence,
                personality: mascotPersonality,
                ideology: mascotIdeology,
                now: Date()
            ),
            mascotState: mascotState
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

    /// Removes every pending AND delivered request that belongs to a
    /// room the user is no longer in: by the payload's room id, by
    /// one of the room's event ids, and by the event-id prefix sweep
    /// for anything older. Used by the foreground purge.
    func purgeRoom(roomId: UUID, eventIds: Set<UUID>) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let pendingIds = pending
            .filter {
                BriefingReconciler.requestBelongsToRoom(
                    userInfo: $0.content.userInfo, roomId: roomId, eventIds: eventIds
                )
            }
            .map(\.identifier)
        if !pendingIds.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: pendingIds)
        }
        let delivered = await center.deliveredNotifications()
        let deliveredIds = delivered
            .filter {
                BriefingReconciler.requestBelongsToRoom(
                    userInfo: $0.request.content.userInfo, roomId: roomId, eventIds: eventIds
                )
            }
            .map(\.request.identifier)
        if !deliveredIds.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: deliveredIds)
        }
        for eventId in eventIds {
            await cancelBriefingTrio(eventId: eventId)
        }
    }

    // MARK: - Joined-late catch-up (W2.7)

    // The catch-up is no longer a hand-rolled schedule path: it is a
    // `BriefingContext` with `kind: .catchUp`, planned and executed
    // by the same reconciler as the cadence, so it reads the CANONICAL
    // seat and honours the room opt-out and the per-event mute
    // (audit 04 D4). See `RoomService.scheduleCatchUpIfNeeded`.

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
    ) async throws {
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
        // Awaited, not detached (audit 04 D1): the request exists on
        // the center when this returns, so a cancel issued after a
        // reconcile can see it.
        try await center.add(request)
    }
}
