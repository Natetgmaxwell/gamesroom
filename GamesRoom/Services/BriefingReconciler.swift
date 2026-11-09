//
//  BriefingReconciler.swift
//  GamesRoom
//
//  The single decision point for this device's briefing-trio
//  notifications (notification-etiquette fix, 2026-11-04).
//
//  Locked rule (brain:
//  wiki/originals/ideas/2026-08-01-notification-etiquette-decline-terminal-9afd3b):
//    - on-create is the ONLY prompt, at most once per
//      (event, user) per install (fired-ledger).
//    - claimed  = logistics only, never a claim clause.
//    - unclaimed = reminder (matrix body + claim clause), not a
//      fresh prompt.
//    - declined = silence, terminal.
//
//  Notification bodies are frozen at schedule time (local
//  UNCalendarNotificationTrigger requests), so correctness lives
//  here: every path that wants briefing notifications on this
//  device goes through `reconcile`, which cancels the event's
//  pending requests and re-plans them from the caller's CANONICAL
//  RSVP state. A device schedules for its signed-in user only —
//  no roster fan-out.
//
//  Foundation-only by design so the test harness
//  (`build-and-run-tests.sh`) compiles and exercises it with a
//  fake sink + fake ledger.
//

import Foundation

// MARK: - Plan model

/// One notification the briefing cadence wants pending on this
/// device. Pure data — the dispatcher's sink turns it into a
/// `UNNotificationRequest`.
struct PlannedBriefingNotification: Equatable {
    let identifier: String
    let title: String
    let body: String
    let kindRaw: String
    let eventId: UUID
    let fireAt: Date
}

// MARK: - Sink (the edge the real dispatcher sits on)

/// The notification-center surface `BriefingReconciler` needs.
/// Production wraps `UNUserNotificationCenter`; tests install a
/// fake that records adds and removals.
///
/// `add` is `async throws` on purpose (2026-11-09, audit 04 D1).
/// It used to spawn a detached `Task` inside the adapter, so
/// `reconcile` returned before the request existed: a claim then
/// mute (or decline) within the same second read
/// `pendingNotificationRequests` before the add landed, cancelled
/// nothing, and the silenced member kept the morning-of push. An
/// awaited add makes the ordering a property of the type.
protocol BriefingNotificationSink: AnyObject, Sendable {
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func removePending(identifiers: [String])
    func add(
        identifier: String,
        title: String,
        body: String,
        kindRaw: String,
        eventId: UUID,
        fireAt: Date
    ) async throws
}

// MARK: - On-create fired ledger

/// Persists which (event, user) on-create prompts have already
/// fired on this install. The UN layer's delivered list is not
/// durable (dismissed banners vanish from it), so the ledger —
/// not the notification center — is the once-per-install gate.
protocol BriefingOnCreateLedger: AnyObject, Sendable {
    func hasFiredOnCreate(eventId: UUID, userId: UUID) -> Bool
    func markOnCreateFired(eventId: UUID, userId: UUID)
}

/// `UserDefaults`-backed ledger. One array key holds
/// "\(eventId)-on_create-\(userId)" entries; the set is pruned of
/// past events on write so it cannot grow unbounded.
final class UserDefaultsOnCreateLedger: BriefingOnCreateLedger, @unchecked Sendable {
    static let key = "briefingOnCreateFiredLedger"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func hasFiredOnCreate(eventId: UUID, userId: UUID) -> Bool {
        entrySet().contains(Self.entry(eventId: eventId, userId: userId))
    }

    func markOnCreateFired(eventId: UUID, userId: UUID) {
        var entries = entrySet()
        entries.insert(Self.entry(eventId: eventId, userId: userId))
        defaults.set(Array(entries).sorted(), forKey: Self.key)
    }

    private func entrySet() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    private static func entry(eventId: UUID, userId: UUID) -> String {
        "\(eventId.uuidString)-on_create-\(userId.uuidString)"
    }
}

// MARK: - Reconciler

enum BriefingReconciler {

    /// Stable identifier components — must match the historical
    /// `\(eventId)-\(kind)-\(userId)` format so `cancelBriefingTrio`
    /// sweeps (event-id prefix) keep working across the fix.
    static let onCreateKindRaw = "on_create"
    static let t168hKindRaw = "t168h"
    static let t84hKindRaw = "t48h"
    static let morningOfKindRaw = "morning_of"
    /// The joined-late catch-up kind. The dispatcher keeps the same
    /// raw value in its private `NotificationKindRaw`.
    static let catchUpKindRaw = "catch_up"
    /// The kind the server's anchor nudge push carries (`type`).
    static let anchorKindRaw = "anchor_nudge"

    /// Every kind this device schedules locally. A briefing of one
    /// of these kinds is listed in Notification Center even when the
    /// app is in the foreground, and a tap on one opens its room.
    static let briefingKindRaws: [String] = [
        onCreateKindRaw,
        t168hKindRaw,
        t84hKindRaw,
        morningOfKindRaw,
        catchUpKindRaw
    ]

    static func identifier(
        eventId: UUID, kindRaw: String, userId: UUID
    ) -> String {
        "\(eventId.uuidString)-\(kindRaw)-\(userId.uuidString)"
    }

    /// The joined-late catch-up request id. Stable per event (a
    /// re-join overwrites instead of stacking a duplicate push) and
    /// DISTINCT per event: two nights must never share one request
    /// id, or the second catch-up silently replaces the first.
    ///
    /// The id starts with the event id so `cancelBriefingTrio`'s
    /// prefix sweep cancels the catch-up with the rest of the event's
    /// cadence.
    static func catchUpIdentifier(eventId: UUID) -> String {
        "\(eventId.uuidString)-catchup"
    }

    // MARK: - Fire mode

    /// How a planned briefing fires.
    ///
    /// The on-create prompt and the joined-late catch-up are "now"
    /// prompts: they must land one second AFTER their body is ready.
    /// A calendar trigger computed before the body was built never
    /// fires, because the mascot-voice LLM round trip can push the
    /// planned second into the past (audit 01 #2). The timed
    /// reminders keep their fixed local date-time.
    enum BriefingFireMode: Equatable {
        /// Fire one second after the body is ready.
        case shortly
        /// Fire at a fixed local date-time.
        case at(Date)
    }

    static func fireMode(kindRaw: String, fireAt: Date) -> BriefingFireMode {
        switch kindRaw {
        case onCreateKindRaw, catchUpKindRaw:
            return .shortly
        default:
            return .at(fireAt)
        }
    }

    // MARK: - Tap routing

    /// The kind carried by a notification payload. Local briefings
    /// use `kind`; remote pushes (the anchor nudge, the Question Box
    /// turn) use `type`.
    static func kindRaw(_ userInfo: [AnyHashable: Any]) -> String? {
        (userInfo["kind"] as? String) ?? (userInfo["type"] as? String)
    }

    /// True when the payload carries one of the local briefing kinds.
    static func isBriefingKind(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let kind = kindRaw(userInfo) else { return false }
        return briefingKindRaws.contains(kind)
    }

    /// What a tapped notification asks the app to do.
    enum BriefingTapRoute: Equatable {
        /// Open the room this notification belongs to. The room id
        /// can be missing on a request scheduled before the payload
        /// carried it; the event id still identifies the night.
        case openRoom(roomId: UUID?, eventId: UUID)
        case none
    }

    /// Routes a tapped notification payload. Briefing kinds and the
    /// anchor nudge open their room; everything else (the Question
    /// Box turn) is not this file's to route.
    static func tapRoute(_ userInfo: [AnyHashable: Any]) -> BriefingTapRoute {
        guard let kind = kindRaw(userInfo) else { return .none }
        guard briefingKindRaws.contains(kind) || kind == anchorKindRaw else {
            return .none
        }
        guard
            let rawEventId = userInfo["event_id"] as? String,
            let eventId = UUID(uuidString: rawEventId)
        else { return .none }
        let roomId = (userInfo["room_id"] as? String).flatMap { UUID(uuidString: $0) }
        return .openRoom(roomId: roomId, eventId: eventId)
    }

    /// True when the on-create prompt may still fire for this
    /// (event, user): the member hasn't responded (a claimed or
    /// declined member must never be asked to claim) and the
    /// ledger has no fired entry for this install.
    static func shouldFireOnCreate(
        state: MemberRSVPState,
        eventId: UUID,
        userId: UUID,
        ledger: BriefingOnCreateLedger
    ) -> Bool {
        state == .unclaimed && !ledger.hasFiredOnCreate(
            eventId: eventId, userId: userId
        )
    }

    /// Pure planning pass — the testable core. Returns every
    /// notification that should be pending on this device for
    /// `(eventId, userId)` given the caller's CURRENT canonical
    /// RSVP state. Declined → empty. On-create included only when
    /// `shouldFireOnCreate` says yes (callers that already hold a
    /// fired-ledger answer pass `includeOnCreate` directly).
    static func plan(
        eventId: UUID,
        eventName: String,
        playedAt: Date,
        mascotName: String,
        userId: UUID,
        memberName: String?,
        state: MemberRSVPState,
        includeOnCreate: Bool,
        hostNote: String? = nil,
        personality: MascotPersonality = .friendly,
        ideology: MascotPoliticalIdeology = .centrist,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [PlannedBriefingNotification] {
        // Declined is terminal — silence, not a reschedule.
        if state == .declined { return [] }

        var planned: [PlannedBriefingNotification] = []

        if includeOnCreate {
            let address = memberName ?? "friend"
            planned.append(
                PlannedBriefingNotification(
                    identifier: identifier(
                        eventId: eventId, kindRaw: onCreateKindRaw, userId: userId
                    ),
                    title: "\(mascotName): \(eventName)",
                    body: "\(mascotName): \(address), \(eventName) is on the books. Open the room to claim your seat.",
                    kindRaw: onCreateKindRaw,
                    eventId: eventId,
                    fireAt: now.addingTimeInterval(1)
                )
            )
        }

        // Calendar-anchored reminder slots (audit 01 #4, #5, #6).
        //
        // The on-create prompt is the head of the cadence: it fires
        // one second after this pass runs, so `now` IS the on-create
        // time and every other slot is measured from it.
        let slots = Self.reminderSlots(playedAt: playedAt, calendar: calendar)
        let onCreateTime = now

        var weekBefore: Date? = slots.weekBefore
        var fewDays: Date? = slots.fewDays
        var morningOf: Date? = slots.morningOf

        // A slot whose time has passed never fires.
        if let w = weekBefore, w <= onCreateTime { weekBefore = nil }
        if let f = fewDays, f <= onCreateTime { fewDays = nil }
        if let m = morningOf, m <= onCreateTime { morningOf = nil }

        // Two pings an hour apart read as spam: the long-lead
        // reminders stay out of the on-create prompt's 24-hour
        // window and the morning-of stays out of its 2-hour window.
        if let w = weekBefore,
            w < onCreateTime.addingTimeInterval(24 * 3600) { weekBefore = nil }
        if let f = fewDays,
            f < onCreateTime.addingTimeInterval(24 * 3600) { fewDays = nil }
        if let m = morningOf,
            m < onCreateTime.addingTimeInterval(2 * 3600) { morningOf = nil }

        // The two long-lead reminders stay a day apart.
        if let f = fewDays,
            abs(f.timeIntervalSince(slots.weekBefore)) < 24 * 3600 {
            fewDays = nil
        }

        for (kindRaw, fireAt) in [
            (t168hKindRaw, weekBefore),
            (t84hKindRaw, fewDays),
            (morningOfKindRaw, morningOf)
        ] {
            guard let fireAt else { continue }
            let isMorning = kindRaw == morningOfKindRaw
            let body = reminderBody(
                eventName: eventName,
                playedAt: playedAt,
                state: state,
                memberName: memberName,
                morning: isMorning,
                hostNote: isMorning ? nil : hostNote,
                personality: personality,
                ideology: ideology,
                mascotName: mascotName
            )
            planned.append(
                PlannedBriefingNotification(
                    identifier: identifier(
                        eventId: eventId, kindRaw: kindRaw, userId: userId
                    ),
                    title: "\(mascotName): \(eventName) \(isMorning ? "today" : "in a few days")",
                    body: body,
                    kindRaw: kindRaw,
                    eventId: eventId,
                    fireAt: fireAt
                )
            )
        }

        return planned
    }

    /// The three reminder slots for `playedAt`, anchored to the
    /// calendar in the device's current time zone (audit 01 #4, #5).
    ///
    /// - week-before: 18:00 on the calendar day 7 days before the
    ///   event's own day.
    /// - few-days (identifier `t48h`): 18:00 on the calendar day
    ///   3 days before the event's own day.
    /// - morning-of: the earlier of 09:00 on the event's day and
    ///   `playedAt - 3h`, never before 07:00 on the event's day.
    ///
    /// Hour offsets land a "in a few days" ping at 2am for an
    /// afternoon event; the calendar anchor puts every long-lead
    /// reminder in the evening and the morning-of in waking hours.
    static func reminderSlots(
        playedAt: Date,
        calendar: Calendar = .current
    ) -> (weekBefore: Date, fewDays: Date, morningOf: Date) {
        let eventDay = calendar.startOfDay(for: playedAt)

        func evening(offsetDays: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: offsetDays, to: eventDay)
                ?? eventDay
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day)
                ?? day
        }

        let nineAM = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: eventDay)
            ?? eventDay
        let sevenAM = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: eventDay)
            ?? eventDay
        let threeHoursBefore = playedAt.addingTimeInterval(-3 * 3600)

        return (
            weekBefore: evening(offsetDays: -7),
            fewDays: evening(offsetDays: -3),
            morningOf: max(min(nineAM, threeHoursBefore), sevenAM)
        )
    }

    /// Matrix-voiced reminder body. Claimed members get pure
    /// logistics (never a claim clause); unclaimed members get the
    /// personality claim clause appended — a reminder of the same
    /// ask, not a fresh prompt.
    static func reminderBody(
        eventName: String,
        playedAt: Date,
        state: MemberRSVPState,
        memberName: String?,
        morning: Bool,
        hostNote: String?,
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        mascotName: String = ""
    ) -> String {
        var body = MascotEngine.generateVoice(
            mascotName: mascotName,
            roomName: "",
            personality: personality,
            ideology: ideology,
            kind: morning ? .briefingMorning : .briefing48h,
            context: .init(
                activeEventTitle: eventName,
                lastEventDaysAgo: nil,
                memberCount: 0,
                memberNames: [],
                memberName: memberName
            ),
            eventDate: playedAt
        )
        if state == .unclaimed {
            body += " " + MascotEngine.unclaimedClause(personality: personality)
        }
        if let note = hostNote, !note.isEmpty {
            body += " Host's note: \(note)"
        }
        return body
    }

    /// The one reconcile entry point. Cancels every pending
    /// request for `eventId` on the sink, then re-plans from the
    /// caller's CURRENT canonical state and submits the result.
    ///
    /// `onCreateBodyProvider` (optional, async) is consulted only
    /// when the on-create prompt will actually fire — the
    /// dispatcher passes the mascot-voice LLM generator there.
    static func reconcile(
        sink: BriefingNotificationSink,
        ledger: BriefingOnCreateLedger,
        eventId: UUID,
        eventName: String,
        playedAt: Date,
        mascotName: String,
        userId: UUID,
        memberName: String?,
        state: MemberRSVPState,
        hostNote: String? = nil,
        personality: MascotPersonality = .friendly,
        ideology: MascotPoliticalIdeology = .centrist,
        now: Date = Date(),
        onCreateBodyProvider: (() async -> String)? = nil
    ) async {
        let prefix = eventId.uuidString
        let pending = await sink.pendingIdentifiers()
        let delivered = await sink.deliveredIdentifiers()
        let onCreateId = identifier(
            eventId: eventId, kindRaw: onCreateKindRaw, userId: userId
        )
        let onCreatePending = pending.contains(onCreateId)

        // An on-create prompt that is STILL pending (scheduled but
        // not yet fired) must survive the sweep — the ledger is
        // marked at schedule time, so treating a fired ledger as
        // "done" would cancel a prompt that never delivered.
        // Keep it untouched: original body, original fire date.
        let keepOnCreate = state == .unclaimed
            && onCreatePending
            && !delivered.contains(onCreateId)

        let stale = pending.filter {
            $0.hasPrefix(prefix) && !(keepOnCreate && $0 == onCreateId)
        }
        if !stale.isEmpty {
            sink.removePending(identifiers: stale)
        }
        if keepOnCreate {
            ledger.markOnCreateFired(eventId: eventId, userId: userId)
        }

        let includeOnCreate = shouldFireOnCreate(
            state: state, eventId: eventId, userId: userId, ledger: ledger
        )
        guard state != .declined else { return }

        let planned = plan(
            eventId: eventId,
            eventName: eventName,
            playedAt: playedAt,
            mascotName: mascotName,
            userId: userId,
            memberName: memberName,
            state: state,
            includeOnCreate: includeOnCreate,
            hostNote: hostNote,
            personality: personality,
            ideology: ideology,
            now: now
        )

        // Belt-and-braces on top of the fired ledger: a delivered
        // on-create banner must never be re-added even if the
        // ledger was somehow reset.
        //
        // Every add is AWAITED (audit 04 D1): a caller's later
        // `cancelBriefingTrio` must observe the request it is meant
        // to cancel. A per-request failure stays non-fatal — the
        // next reconcile overwrites via the same stable identifier.
        for item in planned {
            if item.kindRaw == onCreateKindRaw {
                if delivered.contains(item.identifier) { continue }
                var body = item.body
                if let provider = onCreateBodyProvider {
                    body = await provider()
                }
                ledger.markOnCreateFired(eventId: eventId, userId: userId)
                try? await sink.add(
                    identifier: item.identifier,
                    title: item.title,
                    body: body,
                    kindRaw: item.kindRaw,
                    eventId: item.eventId,
                    fireAt: item.fireAt
                )
            } else {
                try? await sink.add(
                    identifier: item.identifier,
                    title: item.title,
                    body: item.body,
                    kindRaw: item.kindRaw,
                    eventId: item.eventId,
                    fireAt: item.fireAt
                )
            }
        }
    }
}

// MARK: - Foreground purge (lane S2 step 5)

extension BriefingReconciler {

    /// The rooms in `old` that are missing from `new`, in `old`'s
    /// order: the rooms the user left or was removed from since the
    /// last read.
    static func removedRoomIds(old: [UUID], new: [UUID]) -> [UUID] {
        let current = Set(new)
        var seen = Set<UUID>()
        return old.filter { !current.contains($0) && seen.insert($0).inserted }
    }

    /// True when a notification request belongs to the room: its
    /// payload names the room, or names one of the room's events
    /// (requests scheduled before the payload carried a room id).
    static func requestBelongsToRoom(
        userInfo: [AnyHashable: Any],
        roomId: UUID,
        eventIds: Set<UUID>
    ) -> Bool {
        if let raw = userInfo["room_id"] as? String,
           UUID(uuidString: raw) == roomId {
            return true
        }
        if let raw = userInfo["event_id"] as? String,
           let eventId = UUID(uuidString: raw),
           eventIds.contains(eventId) {
            return true
        }
        return false
    }
}
