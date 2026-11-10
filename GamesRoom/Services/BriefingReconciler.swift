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

// MARK: - Context (the one input to every scheduling decision)

/// What one briefing decision is FOR. The cadence is a night's whole
/// local reminder arc; the catch-up is a single prompt for a member
/// who joined after the night was created.
enum BriefingPlanKind: Equatable, Sendable {
    case cadence
    case catchUp
}

/// Where the timed reminder slots come from. The `109_briefing_push.sql`
/// header promised a client switch for the day server push shipped:
/// while `BRIEFING_PUSH_ENABLED` is on, the server's slot ledger owns
/// `t168h` / `t48h` / `morning_of` and the client must not schedule a
/// second copy of each slot under a different identifier (audit 04
/// D12). This enum is that switch, in ONE place.
enum BriefingCadence: String, Equatable, Sendable {
    /// The client schedules every slot itself.
    case local
    /// The server pushes the timed slots; the client schedules none.
    case server

    /// The single source of the switch. It defaults to `.local`
    /// because server push ships disabled (`BRIEFING_PUSH_ENABLED`
    /// lives in the edge function and is not on). Flip this — and
    /// nothing else — on the day it is.
    static let current: BriefingCadence = .local
}

/// Why a context produced no notification at all. Each case names a
/// gate that used to be scattered across `RoomService` early
/// returns; now the planner says which one fired.
enum SilenceReason: String, Equatable, CaseIterable, Sendable {
    /// The night is hidden from this member (`hiddenFromUserIds`).
    case hidden
    /// The member opted out of this room's notifications.
    case roomOptOut
    /// The member muted this event.
    case muted
    /// The canonical RSVP read failed — unknown, so the device says
    /// nothing rather than guessing a nagging `.unclaimed`.
    case unknownSeat
    /// The member declined. Terminal for the event.
    case declined
}

/// What the planner decided: silence with a reason, or the exact
/// requests that should be pending on this device.
enum BriefingOutcome: Equatable {
    case silenced(SilenceReason)
    case scheduled([PlannedBriefingNotification])

    /// The planned requests, empty when silenced.
    var planned: [PlannedBriefingNotification] {
        if case .scheduled(let items) = self { return items }
        return []
    }
}

/// Every input one briefing decision needs, built once by the
/// caller. The 2026-11-09 refactor (audit 04 §3.2) exists because the
/// old 10-argument `reconcile` let a call site forget an input — the
/// joined-late catch-up forgot the canonical seat, the room opt-out
/// and the per-event mute all at once (D4). A context cannot be
/// partially filled.
struct BriefingContext: Sendable {
    var eventId: UUID
    /// The room the request's payload routes a tap to. Not read by
    /// the plan; the sink stamps it on the request.
    var roomId: UUID?
    var eventName: String
    var playedAt: Date
    var userId: UUID
    var memberName: String?
    var mascotName: String

    /// The caller's CANONICAL RSVP state, read fresh from the store.
    /// `nil` means the read failed: unknown, not `.unclaimed`.
    var seat: MemberRSVPState?

    /// `room.notificationsEnabled` — the member's per-room opt-in.
    var roomOptIn: Bool = true
    /// The member's per-event mute (`events_rsvps.notifications_muted`).
    var eventMuted: Bool = false
    /// The night is hidden from this member.
    var hidden: Bool = false

    var hostNote: String? = nil
    /// Standings line for the joined-late catch-up body. Empty for
    /// the cadence.
    var leaderboardSummary: String = ""
    var kind: BriefingPlanKind = .cadence
    /// Where the timed slots come from. See `BriefingCadence.current`.
    var cadence: BriefingCadence = .local

    var personality: MascotPersonality = .friendly
    var ideology: MascotPoliticalIdeology = .centrist
    var now: Date = Date()
    var calendar: Calendar = .current
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
    /// The kind the server's "glad you came" push carries (`type`,
    /// glad-push, 1.2.5 Task 4). A tap opens the room, where the recap
    /// shows the same line.
    static let gladKindRaw = "glad_you_came"

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
        guard briefingKindRaws.contains(kind) || kind == anchorKindRaw || kind == gladKindRaw else {
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

    /// Pure planning pass — the testable core. Every scheduling
    /// decision on this device is one of these: a silence with a
    /// named reason, or the exact list of requests that should be
    /// pending. Nothing here touches a sink, a clock beyond `now`,
    /// or the ledger.
    static func plan(
        _ ctx: BriefingContext,
        includeOnCreate: Bool = false
    ) -> BriefingOutcome {
        // The gate order: something the event hides outranks
        // something the member turned off, which outranks a seat
        // that says "no".
        if let gate = gateSilence(ctx) { return .silenced(gate) }
        guard let seat = ctx.seat else { return .silenced(.unknownSeat) }
        if seat == .declined { return .silenced(.declined) }

        switch ctx.kind {
        case .catchUp:
            return .scheduled([catchUpRequest(ctx, seat: seat)])
        case .cadence:
            return .scheduled(
                cadencePlan(ctx, seat: seat, includeOnCreate: includeOnCreate)
            )
        }
    }

    /// The gates that silence a context regardless of seat: the night
    /// is hidden from this member, the member opted the room out, or
    /// the member muted the event.
    static func gateSilence(_ ctx: BriefingContext) -> SilenceReason? {
        if ctx.hidden { return .hidden }
        if !ctx.roomOptIn { return .roomOptOut }
        if ctx.eventMuted { return .muted }
        return nil
    }

    /// The joined-late catch-up request. Its body is built from the
    /// CANONICAL seat, so a member who already claimed (or declined,
    /// though that is silenced earlier) is never told to claim a seat
    /// they hold (audit 04 D4).
    private static func catchUpRequest(
        _ ctx: BriefingContext,
        seat: MemberRSVPState
    ) -> PlannedBriefingNotification {
        let body = CatchUpMessage.body(
            eventName: ctx.eventName,
            playedAt: ctx.playedAt,
            mascotName: ctx.mascotName,
            leaderboardSummary: ctx.leaderboardSummary,
            rsvpState: seat,
            memberName: ctx.memberName,
            personality: ctx.personality,
            ideology: ctx.ideology
        )
        return PlannedBriefingNotification(
            identifier: catchUpIdentifier(eventId: ctx.eventId),
            title: "\(ctx.mascotName): \(ctx.eventName)",
            body: body,
            kindRaw: catchUpKindRaw,
            eventId: ctx.eventId,
            fireAt: ctx.now.addingTimeInterval(1)
        )
    }

    /// The pre-2026-11-09 pure signature, kept as a thin adapter so
    /// untouched call sites and the existing harness keep compiling.
    /// An input it cannot express (room opt-out, per-event mute,
    /// hidden) defaults to "allowed" — a caller that knows better
    /// builds a `BriefingContext` instead.
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
        plan(
            BriefingContext(
                eventId: eventId,
                roomId: nil,
                eventName: eventName,
                playedAt: playedAt,
                userId: userId,
                memberName: memberName,
                mascotName: mascotName,
                seat: state,
                hostNote: hostNote,
                personality: personality,
                ideology: ideology,
                now: now,
                calendar: calendar
            ),
            includeOnCreate: includeOnCreate
        ).planned
    }

    /// The cadence arc: the once-per-install on-create prompt (when
    /// the caller says so) plus whatever of the three reminder slots
    /// have not passed.
    private static func cadencePlan(
        _ ctx: BriefingContext,
        seat: MemberRSVPState,
        includeOnCreate: Bool
    ) -> [PlannedBriefingNotification] {
        var planned: [PlannedBriefingNotification] = []

        if includeOnCreate {
            let address = ctx.memberName ?? "friend"
            planned.append(
                PlannedBriefingNotification(
                    identifier: identifier(
                        eventId: ctx.eventId, kindRaw: onCreateKindRaw, userId: ctx.userId
                    ),
                    title: "\(ctx.mascotName): \(ctx.eventName)",
                    body: "\(ctx.mascotName): \(address), \(ctx.eventName) is on the books. Open the room to claim your seat.",
                    kindRaw: onCreateKindRaw,
                    eventId: ctx.eventId,
                    fireAt: ctx.now.addingTimeInterval(1)
                )
            )
        }

        // Calendar-anchored reminder slots (audit 01 #4, #5, #6).
        //
        // The on-create prompt is the head of the cadence: it fires
        // one second after this pass runs, so `now` IS the on-create
        // time and every other slot is measured from it.
        let slots = Self.reminderSlots(playedAt: ctx.playedAt, calendar: ctx.calendar)
        let onCreateTime = ctx.now

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

        // D12 — the cadence source. With server push on, the slot
        // ledger owns the three timed reminders and the client must
        // not schedule a duplicate of each under its own identifier.
        // The on-create prompt is local-only either way.
        guard ctx.cadence == .local else { return planned }

        for (kindRaw, fireAt) in [
            (t168hKindRaw, weekBefore),
            (t84hKindRaw, fewDays),
            (morningOfKindRaw, morningOf)
        ] {
            guard let fireAt else { continue }
            let isMorning = kindRaw == morningOfKindRaw
            let body = reminderBody(
                eventName: ctx.eventName,
                playedAt: ctx.playedAt,
                state: seat,
                memberName: ctx.memberName,
                morning: isMorning,
                hostNote: isMorning ? nil : ctx.hostNote,
                personality: ctx.personality,
                ideology: ctx.ideology,
                mascotName: ctx.mascotName
            )
            planned.append(
                PlannedBriefingNotification(
                    identifier: identifier(
                        eventId: ctx.eventId, kindRaw: kindRaw, userId: ctx.userId
                    ),
                    title: "\(ctx.mascotName): \(ctx.eventName) \(isMorning ? "today" : "in a few days")",
                    body: body,
                    kindRaw: kindRaw,
                    eventId: ctx.eventId,
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

    /// The pending identifiers a reconcile of this kind OWNS, and may
    /// therefore cancel. A cadence pass owns the event's whole cadence
    /// family; a catch-up pass owns only the catch-up request.
    ///
    /// Scoping the sweep by kind is what stops a room-open cadence
    /// pass from silently deleting a catch-up scheduled a moment
    /// earlier — both ids hang off the event prefix, and the old
    /// prefix sweep could not tell them apart (audit 04 D5).
    static func ownedPendingIdentifiers(
        _ pending: [String],
        eventId: UUID,
        kind: BriefingPlanKind
    ) -> [String] {
        let prefix = eventId.uuidString
        let catchUp = catchUpIdentifier(eventId: eventId)
        switch kind {
        case .cadence:
            return pending.filter { $0.hasPrefix(prefix) && $0 != catchUp }
        case .catchUp:
            return pending.filter { $0 == catchUp }
        }
    }

    /// The one reconcile entry point. Cancels this device's pending
    /// requests for the context's event, then re-plans from the
    /// context's CANONICAL state and submits the result, awaiting
    /// every add.
    ///
    /// `onCreateBodyProvider` (optional, async) is consulted only
    /// when the on-create prompt will actually fire — the
    /// dispatcher passes the mascot-voice LLM generator there.
    static func reconcile(
        context ctx: BriefingContext,
        sink: BriefingNotificationSink,
        ledger: BriefingOnCreateLedger,
        onCreateBodyProvider: (() async -> String)? = nil
    ) async {
        let pending = await sink.pendingIdentifiers()
        let delivered = await sink.deliveredIdentifiers()
        let onCreateId = identifier(
            eventId: ctx.eventId, kindRaw: onCreateKindRaw, userId: ctx.userId
        )
        let onCreatePending = pending.contains(onCreateId)

        // An on-create prompt that is STILL pending (scheduled but
        // not yet fired) must survive the sweep — the ledger is
        // marked at schedule time, so treating a fired ledger as
        // "done" would cancel a prompt that never delivered.
        // Keep it untouched: original body, original fire date.
        // A gated context (opt-out, mute, hidden) keeps nothing: the
        // member asked to stop hearing from this room or night.
        let keepOnCreate = ctx.seat == .unclaimed
            && onCreatePending
            && !delivered.contains(onCreateId)
            && gateSilence(ctx) == nil

        let stale = ownedPendingIdentifiers(
            pending, eventId: ctx.eventId, kind: ctx.kind
        ).filter {
            !(keepOnCreate && $0 == onCreateId)
        }
        if !stale.isEmpty {
            sink.removePending(identifiers: stale)
        }
        if keepOnCreate {
            ledger.markOnCreateFired(eventId: ctx.eventId, userId: ctx.userId)
        }

        let includeOnCreate = ctx.seat == .unclaimed
            && !ledger.hasFiredOnCreate(eventId: ctx.eventId, userId: ctx.userId)

        let outcome = plan(ctx, includeOnCreate: includeOnCreate)
        guard case .scheduled(let planned) = outcome else { return }

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
                ledger.markOnCreateFired(eventId: ctx.eventId, userId: ctx.userId)
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

    /// The pre-2026-11-09 signature, kept as a thin adapter. It
    /// builds a context that cannot express the room opt-out, the
    /// per-event mute or a hidden night — all three default to
    /// "allowed", exactly as they did before. Callers that can answer
    /// those questions should build a `BriefingContext` instead.
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
        let ctx = BriefingContext(
            eventId: eventId,
            roomId: nil,
            eventName: eventName,
            playedAt: playedAt,
            userId: userId,
            memberName: memberName,
            mascotName: mascotName,
            seat: state,
            hostNote: hostNote,
            personality: personality,
            ideology: ideology,
            now: now
        )
        await reconcile(
            context: ctx,
            sink: sink,
            ledger: ledger,
            onCreateBodyProvider: onCreateBodyProvider
        )
    }
}

// MARK: - Foreground purge (lane S2 step 5)

extension BriefingReconciler {

    /// One room the foreground pass must visit, plus the cached night
    /// the fresh read is about to supersede. `staleEventId` is `nil`
    /// for a room this device has never cached a night for.
    struct ForegroundRoomStep: Equatable {
        let roomId: UUID
        let staleEventId: UUID?
    }

    /// The rooms a foreground pass visits: EVERY room the user is a
    /// member of, in the rooms-list order — not only the ones that
    /// already have a cached night.
    ///
    /// Deriving the visit list from the cache was the bug: a member
    /// who never opened room X had no cached night for it, so a host
    /// scheduling a night while they were away produced no reminder of
    /// any kind on their phone, and the pass that exists to repair
    /// exactly that could not see the room (audit 04 D3).
    static func foregroundRoomPlan(
        memberRoomIds: [UUID],
        cachedEventIdByRoom: [UUID: UUID]
    ) -> [ForegroundRoomStep] {
        memberRoomIds.map {
            ForegroundRoomStep(roomId: $0, staleEventId: cachedEventIdByRoom[$0])
        }
    }

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
