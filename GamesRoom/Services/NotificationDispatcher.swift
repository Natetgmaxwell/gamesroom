//
//  NotificationDispatcher.swift
//  GamesRoom
//
//  Track D2 — iOS UNUserNotificationCenter wrapper.
//
//  Schedules the 3×3 cadence × response-state matrix that drives the
//  V0.8 pre-play briefing window (per the brief §"Pre-play Briefing
//  covers the full pre-event window"):
//
//                  claimed       unclaimed      declined
//   ─────────────────────────────────────────────────────────
//   on_create      push          push           push          (event.createdAt)
//   T-48h          logistics     reminder       skip          (playedAt − 48h)
//   morning-of     logistics     reminder       skip          (09:00 local, playedAt day)
//   ─────────────────────────────────────────────────────────
//
//  The `declined` state is **terminal** — no T-48h, no morning-of,
//  no further nudges for that member for that event. Only the
//  on-create push reaches a declined member (so they have the
//  option to change their mind before the room forgets about them,
//  but they don't get a secondary nudge).
//
//  Body-text conventions:
//   - on-create (all states): "{mascot}: {event} is on the books — open the room to claim your seat."
//   - T-48h claimed        : "{event} is in two days — {date} at {time}, {venue}."
//   - T-48h unclaimed      : "reminder — {event} is in two days. Open the room to claim your seat."
//   - morning-of claimed   : "{event} today — {time}, {venue}."
//   - morning-of unclaimed : "reminder — {event} is today. Open the room to confirm."
//
//  Identifiers are stable per (eventId, cadence, userId) so a
//  duplicate call is idempotent at the UN layer and `cancel` can
//  sweep by event-id prefix without re-deriving the cadence.
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

    // MARK: - Schedule trio

    /// Schedule the pre-play briefing pushes for every member of the
    /// `perMemberCadence` map, branching on the 3×3 matrix above.
    ///
    /// - Parameters:
    ///   - eventId: Unique event identifier. Drives the notification
    ///     identifier prefix so the same notification is not
    ///     scheduled twice across re-calls.
    ///   - eventName: Display name (e.g. "Friday Night Hold'em").
    ///     Used as the notification title.
    ///   - playedAt: When the event starts. Drives T-48h and the
    ///     morning-of push times.
    ///   - mascotName: Display name of the room's mascot. Used as a
    ///     body prefix so the push reads with the room's voice.
    ///   - perMemberCadence: Map of member id → RSVP state. Declined
    ///     members are skipped for the T-48h and morning-of pushes;
    ///     every member receives the on-create push regardless of
    ///     their current state.
    func scheduleBriefingTrio(
        eventId: UUID,
        eventName: String,
        playedAt: Date,
        mascotName: String,
        perMemberCadence: [UUID: MemberRSVPState],
        memberNames: [String] = [],
        /// V0.54 — members whose per-room `notifications_enabled` is
        /// true. The fan-out reaches ONLY this set (plus the
        /// declined-state exception per the audit's item 2 hard
        /// requirement). Default `nil` lets pre-V0.54 callers opt in
        /// to the legacy behaviour (every member reaches on-create).
        optedInMemberIds: Set<UUID>? = nil,
        /// V0.54 — members who have tapped the per-event mute toggle.
        /// The fan-out skips every member in this set regardless of
        /// their room-level opt-in or RSVP state. Default `[]` = no
        /// mutes (a brand-new event has none).
        mutedMemberIds: Set<UUID> = [],
        hostNote: String? = nil,
        mascotApiKey: String? = nil,
        mascotPersonality: MascotPersonality = .friendly,
        mascotIdeology: MascotPoliticalIdeology = .centrist
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let center = UNUserNotificationCenter.current()
        let now = Date()

        // Compute the three trigger times. `onCreate` fires
        // immediately (effectively event.createdAt — the dispatcher
        // is invoked when the host creates the event). T-48h and
        // morning-of schedule against playedAt.

        // On-create: schedule for `now + 1s` so iOS doesn't dedupe
        // a zero-second trigger. This still lands in the same
        // notification cycle as the actual creation moment.
        let onCreateFireAt = now.addingTimeInterval(1)

        let t48FireAt = playedAt.addingTimeInterval(-48 * 3600)

        // Morning-of: 09:00 local time on the calendar day of
        // playedAt. If 09:00 already passed today, fall back to the
        // earlier of `now + 1s` or `playedAt − 30m` so we still fire
        // a same-day push instead of silently dropping the slot.
        let calendar = Calendar.current
        let morningFireAt: Date = {
            let dayStart = calendar.startOfDay(for: playedAt)
            guard
                let nineAM = calendar.date(
                    bySettingHour: 9, minute: 0, second: 0, of: dayStart
                )
            else {
                return playedAt.addingTimeInterval(-30 * 60)
            }
            if nineAM > now {
                return nineAM
            }
            // Past 09:00 on the event day — push the same-day fallback.
            let preStart = playedAt.addingTimeInterval(-30 * 60)
            return preStart > now ? preStart : now.addingTimeInterval(1)
        }()

        // Schedule per member. We don't bail early on a single
        // failure — each request is independent and `add` swallows
        // errors per-request.

        for (memberId, state) in perMemberCadence {

            // V0.54 — quiet-by-default fan-out gates. A member is
            // skipped entirely when:
            //   1. The service passed an explicit `optedInMemberIds`
            //      set and the member isn't in it (room-level
            //      per-member opt-in not flipped on).
            //   2. The member is in `mutedMemberIds` (tapped the
            //      per-event mute toggle; overrides the room-level
            //      opt-in for THIS event).
            //   3. Per the audit's hard item 2 + V0.54 D3: the
            //      on-create push reaches only opted-in, non-
            //      declined members. The `.declined` exception the
            //      pre-V0.54 brief carried is gone — declined
            //      members who haven't opted in receive nothing.
            if let optedIn = optedInMemberIds, !optedIn.contains(memberId) {
                continue
            }
            if mutedMemberIds.contains(memberId) {
                continue
            }
            if state == .declined {
                continue
            }

            // On-create push — fires for every opted-in,
            // non-muted, non-declined member. When the room has a
            // mascot API key, the body is LLM-generated; otherwise
            // falls back to the template.
            var onCreateBodyText = onCreateBody(
                mascotName: mascotName, eventName: eventName
            )
            let resolvedKey = MascotEngine.defaultLLMApiKey
            if !resolvedKey.isEmpty && !resolvedKey.hasPrefix("MISSING_") {
                let context = MascotEngine.RoomContext(
                    activeEventTitle: eventName,
                    lastEventDaysAgo: nil,
                    memberCount: perMemberCadence.count,
                    memberNames: memberNames
                )
                onCreateBodyText = await MascotEngine.generateVoiceLLM(
                    mascotName: mascotName,
                    roomName: "",
                    personality: mascotPersonality,
                    ideology: mascotIdeology,
                    kind: .briefingOnCreate,
                    context: context,
                    apiKey: resolvedKey,
                    eventDate: playedAt,
                    hostNote: hostNote
                )
            }
            await schedule(
                center: center,
                identifier: identifier(
                    eventId: eventId, kind: .onCreate, userId: memberId
                ),
                title: eventName,
                body: onCreateBodyText,
                kindRaw: NotificationKindRaw.onCreate,
                eventId: eventId,
                fireAt: onCreateFireAt
            )

            // Declined is terminal for T-48h and morning-of.
            if state == .declined { continue }

            // T-48h push — claim or reminder variant.
            if t48FireAt > now {
                let (title, body) = t48Body(
                    mascotName: mascotName,
                    eventName: eventName,
                    playedAt: playedAt,
                    state: state,
                    hostNote: hostNote
                )
                await schedule(
                    center: center,
                    identifier: identifier(
                        eventId: eventId, kind: .t48h, userId: memberId
                    ),
                    title: title,
                    body: body,
                    kindRaw: NotificationKindRaw.t48h,
                    eventId: eventId,
                    fireAt: t48FireAt
                )
            }

            // Morning-of push — claim or reminder variant.
            if morningFireAt > now {
                let (title, body) = morningBody(
                    mascotName: mascotName,
                    eventName: eventName,
                    playedAt: playedAt,
                    state: state
                )
                await schedule(
                    center: center,
                    identifier: identifier(
                        eventId: eventId, kind: .morningOf, userId: memberId
                    ),
                    title: title,
                    body: body,
                    kindRaw: NotificationKindRaw.morningOf,
                    eventId: eventId,
                    fireAt: morningFireAt
                )
            }
        }
    }

    /// Cancel every pending notification request associated with one
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
        eventName: String,
        playedAt: Date,
        mascotName: String,
        leaderboardSummary: String,
        rsvpState: MemberRSVPState
    ) async {
        guard await requestAuthorizationIfNeeded() else { return }
        let center = UNUserNotificationCenter.current()
        let body = CatchUpMessage.body(
            eventName: eventName,
            playedAt: playedAt,
            mascotName: mascotName,
            leaderboardSummary: leaderboardSummary,
            rsvpState: rsvpState
        )
        await schedule(
            center: center,
            identifier: "\(eventId.uuidString)-catchup",
            title: eventName,
            body: body,
            kindRaw: NotificationKindRaw.catchUp,
            eventId: eventId,
            fireAt: Date().addingTimeInterval(1)
        )
    }

    // MARK: - Body builders

    private func onCreateBody(mascotName: String, eventName: String) -> String {
        "\(mascotName): \(eventName) is on the books — open the room to claim your seat."
    }

    /// Title + body pair for the T-48h push. Logistics prefix for
    /// claimed members, "reminder —" prefix for unclaimed. When the
    /// host has written a pre-event note (≤280 chars), the claimed
    /// variant appends it per vision §3.6: "Host's note: [note]".
    private func t48Body(
        mascotName: String,
        eventName: String,
        playedAt: Date,
        state: MemberRSVPState,
        hostNote: String? = nil
    ) -> (title: String, body: String) {
        let when = humanWhen(playedAt)
        switch state {
        case .claimed:
            var body = "\(eventName) is in two days — \(when)."
            if let note = hostNote, !note.isEmpty {
                body += " Host's note: \(note)"
            }
            return (
                "\(eventName) — in two days",
                body
            )
        case .unclaimed:
            return (
                "reminder — \(eventName)",
                "reminder — \(eventName) is in two days. Open the room to claim your seat."
            )
        case .declined:
            return (
                "reminder — \(eventName)",
                "reminder — \(eventName) is in two days."
            )
        }
    }

    /// Title + body pair for the morning-of push. Logistics prefix
    /// for claimed members, "reminder —" prefix for unclaimed.
    private func morningBody(
        mascotName: String,
        eventName: String,
        playedAt: Date,
        state: MemberRSVPState
    ) -> (title: String, body: String) {
        let time = humanTime(playedAt)
        switch state {
        case .claimed:
            return (
                "\(eventName) today",
                "\(eventName) today — \(time)."
            )
        case .unclaimed:
            return (
                "reminder — \(eventName)",
                "reminder — \(eventName) is today. Open the room to confirm."
            )
        case .declined:
            return (
                "reminder — \(eventName)",
                "reminder — \(eventName) is today."
            )
        }
    }

    // MARK: - Identifier helpers

    private enum CadenceKind: String {
        case onCreate = "on_create"
        case t48h = "t48h"
        case morningOf = "morning_of"
    }

    /// The `kind` value stored in `userInfo` for downstream handlers
    /// to branch on (e.g. a tap that deep-links into the briefing).
    private enum NotificationKindRaw: String {
        case onCreate = "on_create"
        case t48h = "t48h"
        case morningOf = "morning_of"
        case catchUp = "catch_up"
    }

    private func identifier(
        eventId: UUID, kind: CadenceKind, userId: UUID
    ) -> String {
        "\(eventId.uuidString)-\(kind.rawValue)-\(userId.uuidString)"
    }

    // MARK: - Internal schedule primitive

    private func schedule(
        center: UNUserNotificationCenter,
        identifier: String,
        title: String,
        body: String,
        kindRaw: NotificationKindRaw,
        eventId: UUID,
        fireAt: Date
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [
            "kind": kindRaw.rawValue,
            "event_id": eventId.uuidString
        ]

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: components, repeats: false
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func humanTime(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func humanWhen(_ date: Date) -> String {
        let d = Self.dateFormatter.string(from: date)
        let t = Self.timeFormatter.string(from: date)
        return "\(d) at \(t)"
    }
}
