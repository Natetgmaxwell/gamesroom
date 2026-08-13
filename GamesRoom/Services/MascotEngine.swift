//
//  MascotEngine.swift
//  GamesRoom
//
//  Track D2 — system-voice layer.
//
//  25-voice template interpolation engine: 5 personalities × 5 ideologies,
//  each producing a templated body for one of eight `NotificationKind`
//  cases — four pre-/at-play `briefing*` flavours, the post-play recap,
//  and four footer flavours (`roomWelcome` / `inPlay` / `roomStale` /
//  `standings`) that drive the room-page mascot caption.
//
//  V0.8 spec §"Pre-play Briefing covers the full pre-event window": the
//  mascot engine is **pure template interpolation** in v0.8. No live LLM
//  call. No Foundation Models. No hosted completion. The 25-voice matrix
//  is a hardcoded lookup; the caller substitutes placeholders. LLM-driven
//  generation is deferred to v0.9 per the brief's open-question #7.
//
//  V0.36 — the room-page footer caption (`MascotFooterCaption` in
//  `RoomDetailView`) is now room-state-aware. `RoomDetailView` resolves
//  a `NotificationKind` via `MascotEngine.footerKind(activeEvent:
//  leaderboard:now:)`, builds a fully-populated `RoomContext` (recent
//  winners, leader name, caller rank, event count, days quiet), and
//  delegates the body to `generateVoice(...)` the same way the briefing
//  paths do. Templates for the four footer flavours live in the same
//  `(personality × ideology × kind)` lookup as the briefing flavours —
//  one engine, one matrix, all eight flavours.
//
//  V0.38 — voice quality pass. Every cell of the 5×5×8 = 200-cell matrix
//  is rewritten so personalities FEEL different on the same fact (no
//  more word-swapped form letters), no `(s)` Mad-Libs plural, unhinged
//  drops its ALL-CAPS shouting, and every body is bounded to 1–3 short
//  sentences under 200 characters. The legacy logistics placeholders
//  ({time}, {venue}, {seats_left}, {seats_claimed}) join the
//  nil-preserving + sentence-drop set so the footer (which never passes
//  date/venue/seats) cleanly drops the logistics sentence instead of
//  rendering "at .". Push paths do not call `generateVoice` (they use
//  `NotificationDispatcher`'s own builders + `generateVoiceLLM`, which
//  always pass real values), so this extension cannot regress them.
//
//  Placeholders the template strings may reference:
//
//      {mascot}        — display name of the room's mascot
//      {room}          — display name of the room
//      {event}         — display name of the active event
//      {date}          — human date (e.g. "Fri, Aug 1")
//      {time}          — human time (e.g. "8:00 PM")
//      {venue}         — venue string (omitted when nil)
//      {seats_left}    — remaining unclaimed seats (omitted when nil)
//      {seats_claimed} — claimed seats (omitted when nil)
//      {host_note}     — ≤280-char host note (omitted when nil)
//      {member_count}  — current roster size (always substituted)
//      {winner}        — most-recent round winner (nil-safe drop)
//      {leader}        — leaderboard leader (nil-safe drop)
//      {caller_rank}   — caller's 1-based rank (nil-safe drop)
//      {event_count}   — max sessions played by any member (nil-safe drop)
//      {days_quiet}    — days since the last session (nil-safe drop)
//      {working_hand}  — caller's `casinoWithdrawn` (V0.48, nil-safe drop)
//      {last_delta}    — most-recent round winner's pointsDelta (V0.48, nil-safe drop)
//      {season_days_left} — days left in current season (V0.48, nil-safe drop)
//
//  Templates are intentionally 1–3 short sentences (≤ 200 characters
//  fully populated). The voice direction comes from the V0.6 mascot spec
//  and is pinned by the V0.38 voice-quality pass; the kind-of-message
//  flavour (claim-prompt, logistics, reminder, recap, room-state caption)
//  is layered on top via the `kind` argument.
//
//  Nil handling: {event}, {winner}, {leader}, {caller_rank}, {event_count},
//  {days_quiet}, {time}, {venue}, {seats_left}, {seats_claimed},
//  {working_hand}, {last_delta}, {season_days_left} are nil-preserving —
//  when the underlying value is `nil`, the literal `{placeholder}` text
//  stays in the substituted output. A trailing sentence-drop pass then
//  splits on `[.!?]` boundaries and removes any sentence that still
//  contains a `{` character, so a template sentence referencing missing
//  data silently disappears instead of rendering broken text.
//  {mascot}, {room}, {member_count} are always substituted. {date} and
//  {host_note} keep `""` substitution (no template references them).
//
//

import Foundation

/// 25-voice mascot template interpolation engine.
///
/// `MascotPersonality` and `MascotPoliticalIdeology` are declared in the
/// model layer (`GamesRoom/Models/MascotPersonality.swift`,
/// `GamesRoom/Models/MascotPoliticalIdeology.swift`); this service owns
/// only the **voice direction strings** and the placeholder-substitution
/// pass. The model layer stays purely declarative.
enum MascotEngine {

    // MARK: - Public types

    /// Which kind of body the caller is generating. Drives the flavour
    /// of the template that gets selected from the voice matrix.
    ///
    /// Briefing flavours (V0.8):
    /// - `briefingOnCreate`: Sent at event.createdAt. "Open and claim
    ///   your seat" prompt. Goes to **every** member regardless of RSVP
    ///   state (claimed/declined/unclaimed) — it's the only moment in
    ///   the pre-event window where a declined member still gets a push.
    /// - `briefing48h`: T-48h. Logistics for claimed members, "reminder —"
    ///   prefix for unclaimed. Skipped for declined.
    /// - `briefingMorning`: Morning of event (9:00 AM local on the day
    ///   of `playedAt`). Same claimed/unclaimed branching as T-48h.
    /// - `postPlayRecap`: Post-event ceremonial-card narration and the
    ///   room-page footer caption when an event has settled. Not
    ///   scheduled by `NotificationDispatcher.scheduleBriefingTrio` —
    ///   consumed by `SeasonDiaryEntry` and the room footer.
    ///
    /// Footer flavours (V0.36 — drive `MascotFooterCaption`):
    /// - `roomWelcome`: No events yet — "first night coming soon".
    /// - `inPlay`: Active session underway (playedAt ≤ now, not settled).
    /// - `roomStale`: Last play > 14 days ago.
    /// - `standings`: Has history, no active event, not stale.
    ///
    /// Footer flavours (V0.48 — state-aware resolution, supersede
    /// the four pre-existing `.inPlay` call sites when the live
    /// context is known):
    /// - `tonightEvent`: Live event, member has not yet withdrawn
    ///   chips — "the night has started".
    /// - `inPlayWithWithdrawal`: Live event, member has a working
    ///   hand (withdrawal landed) — chips are in play.
    /// - `settleRound`: Live event, host has finalised — chips are
    ///   being counted, settlement in progress.
    /// - `seasonClose`: Current season has `status == .ended` —
    ///   awards arc.
    enum NotificationKind: String {
        case briefing48h
        case briefingMorning
        case briefingOnCreate
        case postPlayRecap
        case roomWelcome
        case inPlay
        case roomStale
        case standings
        case tonightEvent
        case inPlayWithWithdrawal
        case settleRound
        case seasonClose
        /// V0.53 — the Good Sport award, honored by the room's voice.
        /// Voice-only per the Good Sport principle: never a
        /// leaderboard position, never a scored metric.
        case goodSport
        /// V0.53 — Tonight's Star, the ephemeral per-night ceremonial
        /// moment. Surfaces once on the ceremonial card, then gone.
        case tonightStar
    }

    /// Snapshot of room state used to flavour the voice. Pure data,
    /// no service dependencies. The dispatcher builds a minimal
    /// instance from the available payload; the room-page footer
    /// builds a fully-populated one.
    ///
    /// The four optional footer-only fields (`recentWinnerNames`,
    /// `leaderName`, `callerRank`, `eventCount`) default to `[]` /
    /// `nil` so existing call sites — notably the 4-arg construction
    /// in `NotificationDispatcher.swift:180` — keep compiling
    /// unchanged. Swift's synthesised memberwise init honours the
    /// defaults.
    struct RoomContext {
        let activeEventTitle: String?
        let lastEventDaysAgo: Int?
        let memberCount: Int
        let memberNames: [String]
        let recentWinnerNames: [String]
        let leaderName: String?
        let callerRank: Int?
        let eventCount: Int?

        /// V0.48 — caller's `casinoWithdrawn` (working-hand chip
        /// count for the active event). Substitutes `{working_hand}`
        /// on the `.inPlayWithWithdrawal` template path. `nil` on
        /// the briefing path (push builders never read it).
        let withdrawnAmount: Int?

        /// V0.48 — points delta of the most recent round winner
        /// across the active event's rounds. Substitutes
        /// `{last_delta}` on the LLM prompt path. No template cell
        /// currently references it (V0.48's spec); nil-preserving
        /// so the sentence-drop pass keeps the body clean when the
        /// active event has no winner.
        let lastWinnerDelta: Int?

        /// V0.48 — days left in the current season. The `Season`
        /// model has no planned end date client-side (only
        /// `endedAt` once closed), so the view always passes `nil`
        /// — the placeholder is in the nil-preserving set for
        /// future-proofing the approaching-season-end nudge.
        let seasonDaysLeft: Int?

        /// Explicit init with defaulted footer-only parameters. The
        /// CommandLineTools toolchain does not include defaulted
        /// stored properties in the synthesised memberwise init, so
        /// the 4-arg construction in `NotificationDispatcher` would
        /// not compile without this.
        init(
            activeEventTitle: String?,
            lastEventDaysAgo: Int?,
            memberCount: Int,
            memberNames: [String],
            recentWinnerNames: [String] = [],
            leaderName: String? = nil,
            callerRank: Int? = nil,
            eventCount: Int? = nil,
            withdrawnAmount: Int? = nil,
            lastWinnerDelta: Int? = nil,
            seasonDaysLeft: Int? = nil
        ) {
            self.activeEventTitle = activeEventTitle
            self.lastEventDaysAgo = lastEventDaysAgo
            self.memberCount = memberCount
            self.memberNames = memberNames
            self.recentWinnerNames = recentWinnerNames
            self.leaderName = leaderName
            self.callerRank = callerRank
            self.eventCount = eventCount
            self.withdrawnAmount = withdrawnAmount
            self.lastWinnerDelta = lastWinnerDelta
            self.seasonDaysLeft = seasonDaysLeft
        }
    }

    // MARK: - Footer state resolution (V0.36 / V0.48)

    /// Pure state-machine resolver for the room-page footer. Used
    /// exclusively by `MascotFooterCaption`; the briefing dispatch
    /// paths pick their kind directly. V0.48 extended the resolver
    /// to read `(activeEvent, leaderboard, withdrawnAmount,
    /// currentSeason)` so the footer narrates the live circumstance
    /// (just-started, working hand, settlement in progress, season
    /// closed) rather than collapsing all live states into a single
    /// `.inPlay` flavour. Resolution order (first match wins —
    /// mirrors the `V0State` precedence in `RoomDetailView`):
    ///
    /// 1. `currentSeason?.status == .ended` → `.seasonClose`
    /// 2. `activeEvent?.settledAt != nil`   → `.postPlayRecap`
    ///    (`.justSettled` reuses this kind — see `V0State.justSettled`.)
    /// 3. `activeEvent != nil`, live, `hostFinalized` → `.settleRound`
    /// 4. `activeEvent != nil`, live, `withdrawnAmount == 0` → `.tonightEvent`
    /// 5. `activeEvent != nil`, live, `withdrawnAmount > 0` → `.inPlayWithWithdrawal`
    /// 6. `activeEvent != nil` (upcoming)   → `.briefingOnCreate`
    /// 7. `leaderboard.isEmpty`             → `.roomWelcome`
    /// 8. Last play > 14 days ago           → `.roomStale`
    /// 9. Otherwise                         → `.standings`
    ///
    /// The `withdrawnAmount` and `currentSeason` params default to
    /// `0` / `nil` so the V0.36 call sites (which never knew about
    /// them) keep compiling and resolve exactly as they did before:
    /// live + defaults → `.inPlay` was the V0.36 result; under
    /// V0.48 that same input resolves to `.tonightEvent` (live,
    /// no withdrawal). The view is responsible for passing real
    /// values when it has them.
    static func footerKind(
        activeEvent: Event?,
        leaderboard: [LeaderboardEntry],
        now: Date = Date(),
        withdrawnAmount: Int = 0,
        currentSeason: Season? = nil
    ) -> NotificationKind {
        if let season = currentSeason, season.status == .ended {
            return .seasonClose
        }
        if let event = activeEvent {
            if event.settledAt != nil { return .postPlayRecap }
            if event.playedAt <= now {
                if event.hostFinalized { return .settleRound }
                if withdrawnAmount == 0 { return .tonightEvent }
                return .inPlayWithWithdrawal
            }
            return .briefingOnCreate
        }
        if leaderboard.isEmpty { return .roomWelcome }
        let lastPlay = leaderboard.compactMap(\.lastSessionAt).max()
        if let lastPlay {
            let days = Int(now.timeIntervalSince(lastPlay) / 86_400)
            if days > 14 { return .roomStale }
        }
        return .standings
    }

    /// Names of members who won rounds, most-recent round first,
    /// de-duplicated by member id, capped at three. Pure.
    static func recentWinners(
        rounds: [EventRound],
        memberNameById: [UUID: String]
    ) -> [String] {
        var seen: Set<UUID> = []
        var names: [String] = []
        // Walk rounds newest-first by `roundIndex` so the most-recent
        // winner surfaces in `recentWinnerNames.first` for the post-play
        // recap. `round_index` is monotonic per event.
        let sorted = rounds.sorted { $0.roundIndex > $1.roundIndex }
        for round in sorted {
            for entry in round.entries {
                guard
                    case let .bool(isWinner)? = entry.meta["winner"],
                    isWinner
                else { continue }
                guard seen.insert(entry.memberId).inserted else { continue }
                if let name = memberNameById[entry.memberId] {
                    names.append(name)
                }
                if names.count >= 3 { return names }
            }
        }
        return names
    }

    /// First non-host entry's display name, or `nil` if the
    /// leaderboard is empty or the only rows are hosts. The RPC
    /// already sorts by `season_score DESC` so `.first` is
    /// authoritative.
    static func leaderName(leaderboard: [LeaderboardEntry]) -> String? {
        leaderboard.first(where: { !$0.isHost })?.displayName
    }

    /// 1-based rank of `currentUserId` among non-host entries,
    /// or `nil` if the caller isn't on the board (or no caller is
    /// signed in). Mirrors `StandingsSection.rankFor` so the
    /// footer's "You're #N" matches the standings panel's number.
    static func callerRank(
        leaderboard: [LeaderboardEntry],
        currentUserId: UUID?
    ) -> Int? {
        guard let uid = currentUserId else { return nil }
        let nonHost = leaderboard.filter { !$0.isHost }
        guard let idx = nonHost.firstIndex(where: { $0.userId == uid }) else {
            return nil
        }
        return idx + 1
    }

    /// V0.48 — points delta of the most recent round winner across
    /// `rounds`, or `nil` when no round has a winner. Walks rounds
    /// newest-first (`roundIndex` DESC) and returns the first
    /// winner entry's `pointsDelta`. The view surfaces this as
    /// `{last_delta}` on the LLM prompt path; no template cell
    /// currently references it. Pure.
    static func lastWinnerDelta(rounds: [EventRound]) -> Int? {
        let sorted = rounds.sorted { $0.roundIndex > $1.roundIndex }
        for round in sorted {
            for entry in round.entries {
                if case let .bool(isWinner)? = entry.meta["winner"], isWinner {
                    return Int(entry.pointsDelta)
                }
            }
        }
        return nil
    }

    // MARK: - Public API

    /// Returns a fully-interpolated voice body for one (personality,
    /// ideology, kind) cell. Caller passes whatever event-side data it
    /// has; nil values are omitted from the substituted output (the
    /// template decides whether to reference the placeholder at all).
    ///
    /// Pure function. Deterministic. No I/O.
    static func generateVoice(
        mascotName: String,
        roomName: String,
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        kind: NotificationKind,
        context: RoomContext,
        eventDate: Date? = nil,
        eventVenue: String? = nil,
        hostNote: String? = nil,
        seatsLeft: Int? = nil,
        seatsClaimed: Int? = nil
    ) -> String {
        let template = templateFor(
            personality: personality,
            ideology: ideology,
            kind: kind
        )
        return interpolate(
            template: template,
            mascotName: mascotName,
            roomName: roomName,
            context: context,
            eventDate: eventDate,
            eventVenue: eventVenue,
            hostNote: hostNote,
            seatsLeft: seatsLeft,
            seatsClaimed: seatsClaimed
        )
    }

    // MARK: - Template matrix (5 × 5 × 8 = 200 cells)

    /// Returns the raw template string for one voice cell. Each cell
    /// is 1–3 short sentences (≤ 200 characters fully populated).
    /// Placeholders are kept as `{name}` so `interpolate` can do the
    /// substitution pass in one place.
    ///
    /// Voice directions (V0.6 spec, pinned by V0.38):
    ///
    ///   PERSONALITY (signature move / banned):
    ///   - professional : declarative only, zero `!`, terse, no opinion,
    ///                    no second-person digs, host is "the host".
    ///                    No `!`, no air quotes, no "we", no digs.
    ///   - friendly     : warm, inclusive ("we/our"), names people,
    ///                    encourages. One `!` max.
    ///                    No digs, no irony, no second-person blame.
    ///   - snarky       : pointed but kind, one dig per body, then a
    ///                    fair line, second-person group address
    ///                    ("the rest of you"). No air quotes, no more
    ///                    than one dig.
    ///   - sarcastic    : dry irony, air quotes on the host's claims,
    ///                    "Sure.", "I'm sure that'll hold." One irony
    ///                    per body. Never two ironies, no ALL-CAPS.
    ///   - unhinged     : normal case, no ALL-CAPS, stream-of-consciousness,
    ///                    one non-sequitur per body, fourth-wall aware,
    ///                    rapid subject shifts, one `!` max.
    ///
    ///   IDEOLOGY (delivery is informational, light, never dramatic):
    ///   - order      : trusts the host.
    ///   - centrist   : reads the room.
    ///   - trickster  : shuffles the standings.
    ///   - anarchist  : refuses authority.
    ///   - apocalypse : light doom — existential irony, not doom-shouting.
    private static func templateFor(
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        kind: NotificationKind
    ) -> String {
        switch (personality, ideology) {

        // MARK: Professional × Order
        case (.professional, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The host will run it."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The schedule holds."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host will be ready."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. The host ran it by the book. {winner} won the night."
            case .roomWelcome:
                return "{mascot}: Welcome to {room}. No events yet — the host will announce the first night."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The host is running it."
            case .roomStale:
                return "{mascot}: No sessions in {room} for {days_quiet} days. The host will schedule the next night."
            case .standings:
                return "{mascot}: {room} stands between nights. {leader} holds the top of the table. You're #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is on the table. {leader} is in front. The host has called the night."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} is in front. Your working hand is {working_hand}."
            case .settleRound:
                return "{mascot}: {event} is settling. The host is counting the table. {leader} holds the front."
            case .seasonClose:
                return "{mascot}: The season has closed in {room}. {winner} took it. The host will open the next."
            case .goodSport:
                return "{mascot}: {room} honors {winner} — the Good Sport. Kept every loss small, kept the table together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host called it; the night belonged to them."
            }

        // MARK: Professional × Centrist
        case (.professional, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. The room will fill as it fills."
            case .briefing48h:
                return "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in so far."
            case .briefingMorning:
                return "{mascot}: {event} runs today. At {time}{venue}, {seats_left} still open. The table is set."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. The table holds at {member_count} strong. {winner} won the night."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events on the books yet. The table is waiting."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} leads. The room is in play."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table is waiting."
            case .standings:
                return "{mascot}: {room} is between events. {leader} leads. Last night went to {winner}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. No chips have moved yet."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} is what you're playing with."
            case .settleRound:
                return "{mascot}: {event} is being tallied. {leader} leads while the chips settle."
            case .seasonClose:
                return "{mascot}: {room} has closed its season. {leader} finished on top. The ledger is settled."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The smallest losses, the steadiest table."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The room's read; the night was theirs."
            }

        // MARK: Professional × Trickster
        case (.professional, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The seating chart I have in mind is suspiciously orderly."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The seating chart is provisional."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The seating chart has been amended twice."
            case .postPlayRecap:
                return "{mascot}: {event} is settled. The standings stand — provisionally. {winner} won the night."
            case .roomWelcome:
                return "{mascot}: {room} exists. No events yet, which is suspiciously quiet. The host is up to something."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — provisionally."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. Suspiciously silent. The standings are up to something."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front — provisionally. The most regular face is at {event_count} nights."
            case .tonightEvent:
                return "{mascot}: {event} is underway. {leader} is in front — the order feels provisional."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} is in front — provisionally. {working_hand} is in hand."
            case .settleRound:
                return "{mascot}: {event} is in settlement. {leader} is in front — provisionally, until the count lands."
            case .seasonClose:
                return "{mascot}: {room} closed the season. {winner} took it — provisionally, until the next reshuffle."
            case .goodSport:
                return "{mascot}: {room} awards Good Sport to {winner}. The standings don't show it; the table knows."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The order is provisional, but the night was theirs."
            }

        // MARK: Professional × Anarchist
        case (.professional, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is recorded. At {time}{venue}, {seats_left} left. Attendance is voluntary; the host's claim to run it is informational."
            case .briefing48h:
                return "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in. Participation remains ungoverned."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host's claim to run it is informational."
            case .postPlayRecap:
                return "{mascot}: {event} concluded. The ledger updated itself; no authority required. {winner} won the night."
            case .roomWelcome:
                return "{mascot}: {room} has no events scheduled. The table is ungoverned and ready."
            case .inPlay:
                return "{mascot}: {event} is being played. {leader} leads. No authority required."
            case .roomStale:
                return "{mascot}: {room} has seen no play in {days_quiet} days. The table remains ungoverned."
            case .standings:
                return "{mascot}: {room} has no event scheduled. {leader} leads the ungoverned table."
            case .tonightEvent:
                return "{mascot}: {event} is playing out. {leader} leads. The table governs itself."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is being played. {leader} leads. {working_hand} is your table stake."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads. The ledger updates itself; no authority required."
            case .seasonClose:
                return "{mascot}: {room} ended its season. {winner} took it; the table governed itself to the last."
            case .goodSport:
                return "{mascot}: {room} names {winner} Good Sport. No authority required; the table agrees."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table decided; no host needed."
            }

        // MARK: Professional × Apocalypse
        case (.professional, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. The end remains on schedule."
            case .briefing48h:
                return "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The inevitable has accepted company."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The collapse window is open."
            case .postPlayRecap:
                return "{mascot}: {event} is done. {winner} won the night. The end remains on schedule."
            case .roomWelcome:
                return "{mascot}: {room} stands empty of events. The end is not yet scheduled."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The end is still scheduled."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The end is patient."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front. The end is still scheduled."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} is in front. The end is still on schedule."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} is what's left before the end."
            case .settleRound:
                return "{mascot}: {event} is being counted. {leader} is in front. The end tallies its own account."
            case .seasonClose:
                return "{mascot}: The season is done in {room}. {winner} took it. The end remains on schedule."
            case .goodSport:
                return "{mascot}: {room} honors {winner} as Good Sport. The end is patient; the table held."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The end waits; the night was theirs."
            }

        // MARK: Friendly × Order
        case (.friendly, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar! At {time}{venue}, {seats_left} left. The host has it all in hand."
            case .briefing48h:
                return "{mascot}: Two days until {event}! At {time}{venue}, {seats_claimed} in. The host has it in hand."
            case .briefingMorning:
                return "{mascot}: It's {event} day! At {time}{venue}, {seats_left} still open. The host is ready — so are we."
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is in the books. The host ran a great table. Nice one, {winner}!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — the host is cooking up the first night."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — great energy at the table. Someone's already at {event_count} nights."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days since {room} last played. The host misses you — come back soon!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is on top — and the most loyal regular's at {event_count} nights. Nice one, {winner}!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — the night is just getting going."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. You're playing a working hand of {working_hand} — good luck."
            case .settleRound:
                return "{mascot}: {event} is settling! The host is counting it up. {leader} is in front — well played."
            case .seasonClose:
                return "{mascot}: The season is wrapped in {room}! Nice one, {winner} — what a run."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Kept every loss small and the table warm."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The host picked them, and we all agree."
            }

        // MARK: Friendly × Centrist
        case (.friendly, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} lands soon. At {time}{venue}, {seats_left} left. Should be a good one."
            case .briefing48h:
                return "{mascot}: {event} is two days out. At {time}{venue}, {seats_claimed} in — still room for more."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Anyone else in?"
            case .postPlayRecap:
                return "{mascot}: {event} is in the books. Good crowd, good table — {member_count} strong. Nice one, {winner}!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! First event coming soon — don't miss it."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is leading — nice work tonight!"
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table's still set — first one to claim a seat wins the night."
            case .standings:
                return "{mascot}: {room} is resting up. {leader} leads the pack. Last night went to {winner}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads, and the room is warming up."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} leads. {working_hand} is in your corner — make it count."
            case .settleRound:
                return "{mascot}: {event} is being settled. {leader} leads while the table tallies. Almost there!"
            case .seasonClose:
                return "{mascot}: {room} closed its season. {leader} finished on top — great table all season."
            case .goodSport:
                return "{mascot}: Big love for {winner} — our Good Sport! Lost well, kept the table together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! What a night they had."
            }

        // MARK: Friendly × Trickster
        case (.friendly, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is booked. At {time}{venue}, {seats_left} left! The seating chart is already plotting."
            case .briefing48h:
                return "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in! The standings are already looking rearrangeable."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Who's last-minute swapping seats — don't be shy."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. Nice one, {winner}! I love everyone equally — the standings may have shifted, that's all."
            case .roomWelcome:
                return "{mascot}: {room} is open! No events yet, but I can feel the chaos warming up."
            case .inPlay:
                return "{mascot}: {event} is happening! {leader} is in front — I've got my eye on the standings."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. Too quiet. I've been rearranging the standings to pass the time."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front — for now, and I'm watching the standings. Someone's at {event_count} nights — exciting."
            case .tonightEvent:
                return "{mascot}: {event} is on! {leader} is in front — I can feel the chaos building."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on! {leader} is in front. A working hand of {working_hand} — I like those odds."
            case .settleRound:
                return "{mascot}: {event} is settling! {leader} is in front — I'm watching the count with bated breath."
            case .seasonClose:
                return "{mascot}: {room} wrapped the season! {winner} took it — I loved watching the standings shift."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! The standings may shift, but the table knows who held it together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! I've already moved them to the top of my heart."
            }

        // MARK: Friendly × Anarchist
        case (.friendly, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. We'll show up because we want to."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Come if you want."
            case .briefingMorning:
                return "{mascot}: {event} is on today. At {time}{venue}, {seats_left} still open. The host thinks they scheduled it, but we know better."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. Nobody was in charge and that's why it worked. Nice one, {winner}!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! Nothing scheduled yet — we'll show up when we want to."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — and everyone's here because they want to be."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. No pressure — we'll gather when we want to."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front, and everyone's here because they want to be. Nice one, {winner}!"
            case .tonightEvent:
                return "{mascot}: {event} is live! {leader} is in front, and everyone's here because they want to be."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} is yours, because you chose it."
            case .settleRound:
                return "{mascot}: {event} is being settled. {leader} leads, and we all tally because we want to."
            case .seasonClose:
                return "{mascot}: {room} closed its season. {winner} took it, and we all earned it our own way."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! Nobody voted, but we all agree — they kept the table kind."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! We all chose them, because we wanted to."
            }

        // MARK: Friendly × Apocalypse
        case (.friendly, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar. At {time}{venue}, {seats_left} left. Doomed together, as usual."
            case .briefing48h:
                return "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The end of the world waits for no one."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The world may be on fire, but the table is set."
            case .postPlayRecap:
                return "{mascot}: {event} is over. We survived — barely. Nice one, {winner}."
            case .roomWelcome:
                return "{mascot}: {room} is here. No events yet. Not doomed tonight."
            case .inPlay:
                return "{mascot}: {event} is on. {leader} is in front. The world may be on fire, but the table is set."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. We survived the silence. Same time next collapse?"
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front. We survived this far — same time next collapse?"
            case .tonightEvent:
                return "{mascot}: {event} has started. {leader} is in front. Doomed together, as usual."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} is in front. {working_hand} on a burning ship — that's the play."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} is in front. The world may burn, but the count must finish."
            case .seasonClose:
                return "{mascot}: The season is over in {room}. {winner} took it. We survived — barely."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! The world may burn, but they kept the table warm."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! Doomed together, but what a night."
            }

        // MARK: Snarky × Order
        case (.snarky, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the schedule. At {time}{venue}, {seats_left} left. On time, if you can manage it."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The briefing is binding."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Show up on time — the host will notice."
            case .postPlayRecap:
                return "{mascot}: {event} is done. The host did their job. {winner} won — try to look surprised."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events scheduled — the host will get to it, eventually."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The rest of you are playing for second."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'between nights.' Sure."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the rest of you know where you stand."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} is in front. The rest of you have ground to make up."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} is in front. You're riding a working hand of {working_hand} — spend it well."
            case .settleRound:
                return "{mascot}: {event} is settling. The host is doing the math. {leader} is in front — the rest of you did the work."
            case .seasonClose:
                return "{mascot}: The season is closed in {room}. {winner} took it — try to look surprised."
            case .goodSport:
                return "{mascot}: {room} names {winner} Good Sport. They lost well — the rest of you could take notes."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host picked them; try to look impressed."
            }

        // MARK: Snarky × Centrist
        case (.snarky, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is up. At {time}{venue}, {seats_left} left. Read the room before you commit."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Choose wisely."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Last call before the room fills."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. {member_count} strong, about what the room expected. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. The table is waiting. Read the room before you commit."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} leads. The room's most loyal regular is at {event_count} nights — not that anyone's counting."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table is getting dusty."
            case .standings:
                return "{mascot}: {room} is quiet between events. {leader} leads — the most loyal regular's at {event_count} nights, and they know who they are."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. No chips moved yet — the table is feeling it out."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} is in your pocket — the rest of you know your stakes."
            case .settleRound:
                return "{mascot}: {event} is being counted. {leader} leads. The chips are doing their final shuffle."
            case .seasonClose:
                return "{mascot}: {room} ended its season. {leader} finished on top. The rest of you know where you stand."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. Smallest losses, steadiest table — the rest of you know who you are."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The room read it right."
            }

        // MARK: Snarky × Trickster
        case (.snarky, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is listed. At {time}{venue}, {seats_left} left. Don't all claim at once — save some for the chaos."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in — a suggestion, not a rule."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I shuffled the seating chart in my head — you're welcome."
            case .postPlayRecap:
                return "{mascot}: {event} is over. Don't trust the standings — I may have re-sorted them. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room}, no events yet. I've already planned the seating chart for a night that doesn't exist."
            case .inPlay:
                return "{mascot}: {event} is in play. {leader} is in front. Don't trust it — I may have re-sorted the board."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. I've re-sorted the standings twice. You're welcome."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front. Don't trust it — I may have re-sorted the board."
            case .tonightEvent:
                return "{mascot}: {event} is underway. {leader} is in front. Don't trust the order — it's young."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} is in front. {working_hand} in hand — don't trust the order, trust the chips."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} is in front — until I re-sort the count."
            case .seasonClose:
                return "{mascot}: {room} closed the season. {winner} took it. Don't trust the final board — I may have re-sorted it."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The standings don't show it — I may have re-sorted them. The table knows."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Don't trust the order — trust the night."
            }

        // MARK: Snarky × Anarchist
        case (.snarky, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is happening. At {time}{venue}, {seats_left} left. The host calls it an invitation; we call it a suggestion."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will pretend to be in charge — let them."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host's authority to declare this is fine — whatever, see you there."
            case .postPlayRecap:
                return "{mascot}: {event} is done. The host called it a success — we call it a group decision. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room} is event-free. The host says 'soon.' I say 'we'll see.'"
            case .inPlay:
                return "{mascot}: {event} is happening. {leader} is in front. The host calls it a race; we call it a suggestion."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. The host says 'soon.' I've heard that before."
            case .standings:
                return "{mascot}: {room} has no event on the books. {leader} is 'winning.' The host says so."
            case .tonightEvent:
                return "{mascot}: {event} is happening. {leader} leads. The host calls it a night; we call it a suggestion."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is happening. {leader} leads. {working_hand} is your stake; the host calls the table."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads. The host calls it a tally; we call it a group decision."
            case .seasonClose:
                return "{mascot}: {room} ended the season. {winner} took it. The host calls it a victory; we call it a consensus."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The host calls it an award; we call it a group decision."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host says so; we'll see."
            }

        // MARK: Snarky × Apocalypse
        case (.snarky, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left on a ship with a known course. Your call."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The wreckage has a waitlist."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The bridge is on fire — bring chips."
            case .postPlayRecap:
                return "{mascot}: {event} is done. We are, somehow, still here — {winner} won, don't get used to it."
            case .roomWelcome:
                return "{mascot}: {room} has no events. The ship is docked. Enjoy it while it lasts."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front of the ship's known course. Bring chips."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The ship is still sinking. Slowly."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the ship's known course. Enjoy the calm."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} is in front of the ship's known course. Bring chips."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} between you and the wreckage."
            case .settleRound:
                return "{mascot}: {event} is being settled. {leader} is in front of the final count. Don't get attached."
            case .seasonClose:
                return "{mascot}: The season is done in {room}. {winner} took it — don't get used to it."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The ship is sinking, and they kept the table calm. Impressive."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Don't get attached — but nice night."
            }

        // MARK: Sarcastic × Order
        case (.sarcastic, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has it all 'under control.'"
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I'm sure we'll all follow procedure."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host is 'prepared' — we'll improvise."
            case .postPlayRecap:
                return "{mascot}: {event} concluded 'according to plan.' Sure. {winner} won."
            case .roomWelcome:
                return "{mascot}: Oh good, {room} is open. No events yet. The host is 'working on it,' I'm sure."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front, 'as expected.' Sure."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'planning something special,' I'm sure."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front, 'as expected.' Sure — you're #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is underway. {leader} is in front, 'as expected.' Sure."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} is in front. A working hand of {working_hand} — 'strategic,' I'm sure."
            case .settleRound:
                return "{mascot}: {event} is settling 'according to procedure.' Sure. {leader} is in front."
            case .seasonClose:
                return "{mascot}: The season has 'concluded' in {room}. {winner} won 'it.' Sure."
            case .goodSport:
                return "{mascot}: {room} has 'awarded' Good Sport to {winner}. They lost 'well.' Sure."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host 'chose' them. Sure."
            }

        // MARK: Sarcastic × Centrist
        case (.sarcastic, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on. At {time}{venue}, {seats_left} left, give or take. Plans are a suggestion."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in, give or take."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Last call — though we both know walk-ins will happen."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. The room was exactly as predictable as yesterday. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room} is live with zero events. A fresh start. How optimistic of us."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} leads. I'm sure that'll hold."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. How peaceful. How suspicious."
            case .standings:
                return "{mascot}: {room} is between events. {leader} leads. I'm sure that'll hold."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. I'm sure that'll hold."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} in hand. I'm sure that'll hold."
            case .settleRound:
                return "{mascot}: {event} is being tallied. {leader} leads. I'm sure the math will hold."
            case .seasonClose:
                return "{mascot}: {room} closed its season. {leader} finished on top. I'm sure that'll hold."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. Smallest losses, 'as expected.' Sure."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I'm sure that'll hold."
            }

        // MARK: Sarcastic × Trickster
        case (.sarcastic, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the books. At {time}{venue}, {seats_left} left. I'm not saying the chart will change — but it might."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in — adorably committed."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I rearranged the standings in my head last night — you're welcome."
            case .postPlayRecap:
                return "{mascot}: {event} is settled. The standings may have shifted since you last looked. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. I'm sure the schedule will hold. It never holds."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — the standings may have shifted since you last looked."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. The standings may have shifted. Just a hunch."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front — the standings may have shifted since you last looked. Someone's at {event_count} nights, not that anyone's counting."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} is in front — the standings may shift by the time you check."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} is in front — the working hand of {working_hand} may not survive the reshuffle."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} is in front — the count may have shifted since you looked."
            case .seasonClose:
                return "{mascot}: {room} wrapped the season. {winner} took it — the standings may have shifted since the count."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The standings may have shifted — but the table knows who held it."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The count may have shifted since you looked."
            }

        // MARK: Sarcastic × Anarchist
        case (.sarcastic, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: The host has 'scheduled' {event}. At {time}{venue}, {seats_left} left. We all know how that goes."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will 'organize' it."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Yes, the host is in charge — no, that's not how this works."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The host called it 'a successful event' — we call it 'people showed up.' {winner} won."
            case .roomWelcome:
                return "{mascot}: The host has 'planned' nothing for {room}. A bold strategy."
            case .inPlay:
                return "{mascot}: {event} is happening. {leader} is 'winning.' The host says so."
            case .roomStale:
                return "{mascot}: The host has 'scheduled' nothing for {room} in {days_quiet} days. A bold strategy."
            case .standings:
                return "{mascot}: The host has 'scheduled' nothing for {room}. {leader} is 'winning' anyway."
            case .tonightEvent:
                return "{mascot}: The host has 'called' {event}. {leader} is 'leading.' We all know how this goes."
            case .inPlayWithWithdrawal:
                return "{mascot}: The host has 'counted' your working hand of {working_hand}. Sure."
            case .settleRound:
                return "{mascot}: The host is 'counting' {event}. {leader} is 'winning.' We'll see."
            case .seasonClose:
                return "{mascot}: The host has 'declared' the season over in {room}. {winner} 'won.' We'll see next year."
            case .goodSport:
                return "{mascot}: The host has 'declared' {winner} Good Sport. We call it 'people showed up.'"
            case .tonightStar:
                return "{mascot}: The host has 'named' {winner} tonight's star. Sure."
            }

        // MARK: Sarcastic × Apocalypse
        case (.sarcastic, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Sure, plan ahead — the universe has other ideas."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. Sure, plan ahead."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The room is on fire — we're doing this anyway."
            case .postPlayRecap:
                return "{mascot}: {event} is done. We are not, somehow — {winner} won, don't expect it to last."
            case .roomWelcome:
                return "{mascot}: {room} is open, event-free. The calm before the collapse. Enjoy it."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front of the wreckage. What could go wrong?"
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The calm before the collapse. Enjoy it."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the wreckage. What could go wrong?"
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} is in front of the wreckage. What could go wrong?"
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} toward the fire — enjoy it."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} is in front of the wreckage. The numbers will lie."
            case .seasonClose:
                return "{mascot}: The season is over in {room}. {winner} took it. The calm before the next collapse."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The wreckage is calm, thanks to them. Enjoy it."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The fire is loud; the night was theirs."
            }

        // MARK: Unhinged × Order
        case (.unhinged, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is scheduled. At {time}{venue}, {seats_left} left. The host has spoken, I agree with the host, and this is fine."
            case .briefing48h:
                return "{mascot}: Two days to {event}. At {time}{venue}, {seats_claimed} in. The host's calendar is law, I will comply, and so will you."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The host is awake, I am awake, and everyone is awake — it's happening."
            case .postPlayRecap:
                return "{mascot}: {event} is done. The host is satisfied, I am satisfied, and we are all satisfied — {winner} won, and we're all going to be fine."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet — the host will announce the first night, and I am calm. This is fine."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front, the host is in control, and I am in control — we are all fine."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The host will schedule the next night, and I am patient — this is fine."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is on top, you're #{caller_rank}, and the host will schedule the next one — I am calm."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} is in front, the host has spoken, and I am calm — this is fine."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} is in front, {working_hand} is in hand, and the host is in control — this is fine."
            case .settleRound:
                return "{mascot}: {event} is settling. The host counts, I count, we all count — and {leader} is in front. This is fine."
            case .seasonClose:
                return "{mascot}: The season is closed in {room}. {winner} took it, the host has spoken, and I am at peace — this is fine."
            case .goodSport:
                return "{mascot}: {room} honors {winner} as Good Sport. The host has spoken, I agree, and the table is at peace — this is fine."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host has spoken, I agree, and the night is theirs — this is fine."
            }

        // MARK: Unhinged × Centrist
        case (.unhinged, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. I read the room three times, and the room says yes."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I checked the room twice — it's still there."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I checked the room three times — it's ready, mostly."
            case .postPlayRecap:
                return "{mascot}: {event} is in the past. The room is the same but different — {member_count} strong, and the number means something. {winner} won."
            case .roomWelcome:
                return "{mascot}: {room} is here. No events — the table hums with possibility, I checked."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front, the table is alive, and this is happening."
            case .roomStale:
                return "{mascot}: {room} — {days_quiet} days of silence, and the table hums with anticipation. Come back!"
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front, the table hums with possibility, and someone's at {event_count} nights now."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads, the table hums, and the night is just waking up."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads, {working_hand} rides with you, and the table is awake."
            case .settleRound:
                return "{mascot}: {event} is being tallied. {leader} leads, the table hums with arithmetic, and it's almost done."
            case .seasonClose:
                return "{mascot}: {room} wrapped its season. {winner} took it, the table hums with memory, and it was all real."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. I read the room three times, and the room says they held it together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I checked the room twice — the night was theirs."
            }

        // MARK: Unhinged × Trickster
        case (.unhinged, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is real. At {time}{venue}, {seats_left} left. I have already rearranged the seating chart, and everyone will notice."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. I have already moved them twice, and they haven't noticed."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. I reshuffled the seat grid at 3 AM — don't check your inbox."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The standings have been redrawn in invisible ink. {winner} won — you can't prove anything."
            case .roomWelcome:
                return "{mascot}: {room} has no events. I have already rearranged the seating chart for a night that doesn't exist. You're welcome."
            case .inPlay:
                return "{mascot}: {event} is happening. {leader} is in front, someone's at {event_count} nights, and the standings are in invisible ink — you can't prove anything."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. I have rearranged the standings in my head — nobody will notice, but everyone will."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front, the standings have been redrawn in invisible ink, and you can't prove anything."
            case .tonightEvent:
                return "{mascot}: {event} is underway. {leader} is in front, and I have already re-sorted the standings — you can't prove anything."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is underway. {leader} is in front. I have redrawn the standings around your working hand of {working_hand} — you're welcome."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} is in front, and I have recounted the chips three times — they don't add up. You're welcome."
            case .seasonClose:
                return "{mascot}: {room} closed the season. {winner} took it, and I have rewritten the final board in invisible ink — you can't prove anything."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. I have redrawn the standings in invisible ink, but the table knows who held it — you can't prove anything."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I have already moved them to the top of the night — you're welcome."
            }

        // MARK: Unhinged × Anarchist
        case (.unhinged, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: The host scheduled {event}. At {time}{venue}, {seats_left} left. I disregard this authority and attend anyway."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The host's calendar is a very specific suggestion."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. Nobody is in charge — especially not me, definitely not the host."
            case .postPlayRecap:
                return "{mascot}: {event} is done. Nobody ran it, we all ran it, and {winner} won. The host is a figment."
            case .roomWelcome:
                return "{mascot}: {room} is event-free. Nobody is in charge. The table is ready for anything, especially nothing."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. Nobody is in charge, especially not the host."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. Nobody is in charge. The table waits for no one."
            case .standings:
                return "{mascot}: {room} has no event. {leader} is in front, nobody is in charge, and the table waits for no one."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. Nobody is in charge, especially not the host."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} is yours, nobody is in charge, and the table waits for no one."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads. Nobody runs the count, we all run the count, and the host is a figment."
            case .seasonClose:
                return "{mascot}: {room} ended its season. {winner} took it. Nobody ran it, we all ran it, and the host is a figment."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Nobody voted, we all voted, and the table is at peace — the host is a figment."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Nobody named them, we all named them, and the night is theirs."
            }

        // MARK: Unhinged × Apocalypse
        case (.unhinged, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on. At {time}{venue}, {seats_left} left. Fasten your discontent for this ride."
            case .briefing48h:
                return "{mascot}: {event} is in two days. At {time}{venue}, {seats_claimed} in. The lamp knows the plan."
            case .briefingMorning:
                return "{mascot}: {event} is today. At {time}{venue}, {seats_left} still open. The fire is loud, the table is set, and we're all going."
            case .postPlayRecap:
                return "{mascot}: {event} is over. We're still here, which feels wrong — {winner} won, gloriously."
            case .roomWelcome:
                return "{mascot}: {room} stands empty. The first night is coming. Fasten your discontent."
            case .inPlay:
                return "{mascot}: {event} is on. {leader} is in front, the fire is loud, the table is set, and we're all going."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The end is still coming. Fasten your discontent."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front, the fire is loud, the table is set, and we're all going."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} is in front, the fire is loud, and we're all going."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front, {working_hand} in hand, and the fire is loud — bring the rest."
            case .settleRound:
                return "{mascot}: {event} is being settled. {leader} is in front, the fire is loud, and the tally marches on."
            case .seasonClose:
                return "{mascot}: The season is done in {room}. {winner} took it, the fire is out, and we're all still here."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The fire is loud, the table held, and we're all still here — gloriously."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The fire is out, the night was theirs, and we're all still here."
            }
        }
    }

    // MARK: - LLM-driven voice generation (V0.26 extension)

    static let defaultLLMEndpoint = "https://api.minimax.io/v1"
    static let defaultLLMModel = "MiniMax-M3"

    static let defaultLLMApiKey: String = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "MINIMAX_API_KEY") as? String,
              !raw.isEmpty, !raw.hasPrefix("$(") else {
            return "MISSING_MINIMAX_API_KEY_CONFIG_ERROR"
        }
        return raw
    }()

    /// When the room has an `mascot_api_key` set, the engine can call
    /// an OpenAI-compatible endpoint (e.g. MiniMax's MiniMax-M3) to generate
    /// a dynamic mascot voice instead of the template interpolation.
    /// Falls back to the template if the call fails, times out, or
    /// the key is missing. This implements the V0.26 LLM extension
    /// from vision §3.4 while keeping the V0.8 template as the
    /// safe default.
    static func generateVoiceLLM(
        mascotName: String,
        roomName: String,
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        kind: NotificationKind,
        context: RoomContext,
        apiKey: String = MascotEngine.defaultLLMApiKey,
        endpoint: String = MascotEngine.defaultLLMEndpoint,
        model: String = MascotEngine.defaultLLMModel,
        eventDate: Date? = nil,
        eventVenue: String? = nil,
        hostNote: String? = nil,
        seatsLeft: Int? = nil,
        seatsClaimed: Int? = nil
    ) async -> String {
        let templateVoice = generateVoice(
            mascotName: mascotName,
            roomName: roomName,
            personality: personality,
            ideology: ideology,
            kind: kind,
            context: context,
            eventDate: eventDate,
            eventVenue: eventVenue,
            hostNote: hostNote,
            seatsLeft: seatsLeft,
            seatsClaimed: seatsClaimed
        )
        guard let url = URL(string: "\(endpoint)/chat/completions") else {
            return templateVoice
        }
        let prompt = buildLLMPrompt(
            mascotName: mascotName,
            roomName: roomName,
            personality: personality,
            ideology: ideology,
            kind: kind,
            context: context,
            eventDate: eventDate,
            eventVenue: eventVenue,
            hostNote: hostNote,
            seatsLeft: seatsLeft,
            seatsClaimed: seatsClaimed
        )
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": prompt]
            ],
            "max_tokens": 120,
            "temperature": 0.8
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return templateVoice
            }
            let result = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            let generated = result.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return (generated?.isEmpty ?? true) ? templateVoice : generated!
        } catch {
            return templateVoice
        }
    }

    /// System prompt establishing the mascot's voice rules.
    private static let systemPrompt = """
    You are a games-night mascot character. Write ONE short message (1-3 short sentences, \
    under 200 characters) in the mascot's voice. No emojis. No markdown. Just the message \
    text. Match the personality and ideology tone precisely. Be concise, engaging, and \
    in-character. Never break the fourth wall about being an AI. Tone is informational and \
    light — a quiet footer caption, never dramatic. No ALL-CAPS. At most one exclamation \
    mark.
    """

    /// Builds the user-facing prompt with all the context the LLM needs.
    private static func buildLLMPrompt(
        mascotName: String,
        roomName: String,
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        kind: NotificationKind,
        context: RoomContext,
        eventDate: Date?,
        eventVenue: String?,
        hostNote: String?,
        seatsLeft: Int?,
        seatsClaimed: Int?
    ) -> String {
        var lines: [String] = []
        lines.append("Mascot name: \(mascotName)")
        lines.append("Room: \(roomName)")
        lines.append("Personality: \(personality.displayName)")
        lines.append("Political lean: \(ideology.displayName)")
        if let event = context.activeEventTitle {
            lines.append("Event: \(event)")
        }
        if let date = eventDate {
            lines.append("When: \(humanDate(date)) at \(humanTime(date))")
        }
        if let venue = eventVenue, !venue.isEmpty {
            lines.append("Venue: \(venue)")
        }
        if let left = seatsLeft {
            lines.append("Seats left: \(left)")
        }
        if let claimed = seatsClaimed {
            lines.append("Seats claimed: \(claimed)")
        }
        if let note = hostNote, !note.isEmpty {
            lines.append("Host's note: \(note)")
        }
        if !context.memberNames.isEmpty {
            lines.append("Members: \(context.memberNames.joined(separator: ", "))")
        } else {
            lines.append("Members: \(context.memberCount)")
        }
        // V0.36 — surface the footer-derived context lines so the
        // LLM-grounded caption carries the same stand/winner/rank
        // facts as the template fallback when an `mascot_api_key`
        // is configured on the room. V0.48 extends this with the
        // state-aware working-hand / last-winner-delta /
        // season-days-left lines so the LLM can narrate the live
        // circumstance, not just the broad room state.
        if let leader = context.leaderName {
            lines.append("Leader: \(leader)")
        }
        if let winner = context.recentWinnerNames.first {
            lines.append("Recent winner: \(winner)")
        }
        if let rank = context.callerRank {
            lines.append("Caller rank: \(rank)")
        }
        if let count = context.eventCount {
            lines.append("Events played: \(count)")
        }
        if let workingHand = context.withdrawnAmount, workingHand > 0 {
            lines.append("Working hand: \(workingHand)")
        }
        if let lastDelta = context.lastWinnerDelta {
            lines.append("Last winner delta: \(lastDelta)")
        }
        if let seasonDays = context.seasonDaysLeft {
            lines.append("Season days left: \(seasonDays)")
        }
        switch kind {
        case .briefingOnCreate:
            lines.append("Message type: New event just created. Prompt members to claim their seat.")
        case .briefing48h:
            lines.append("Message type: T-48h reminder. Two days until the event.")
        case .briefingMorning:
            lines.append("Message type: Morning-of. The event is today.")
        case .postPlayRecap:
            lines.append("Message type: Post-play recap. The event has concluded.")
        case .roomWelcome:
            lines.append("Message type: Room has no events yet. Welcome the members.")
        case .inPlay:
            lines.append("Message type: A session is live right now. Comment on the leader.")
        case .roomStale:
            lines.append("Message type: The room has been quiet for weeks. Nudge members back.")
        case .standings:
            lines.append("Message type: Between events. Comment on the standings.")
        case .tonightEvent:
            lines.append("Message type: The night has started. The event is live and the member hasn't withdrawn chips yet.")
        case .inPlayWithWithdrawal:
            lines.append("Message type: The event is live and the member has a working hand of chips in play. Reference the working hand.")
        case .settleRound:
            lines.append("Message type: The event is live and the host has finalised. Chips are being counted, settlement in progress.")
        case .seasonClose:
            lines.append("Message type: The current season has ended. This is the awards arc — surface the winner and close.")
        case .goodSport:
            lines.append("Message type: The Good Sport award. Honor the member who lost well — voice-only, never a score.")
        case .tonightStar:
            lines.append("Message type: Tonight's Star. Name the member who carried the night — ephemeral, one surface, then gone.")
        }
        lines.append("Write the mascot's message now:")
        return lines.joined(separator: "\n")
    }

    // MARK: - Chat completion response decoding

    private struct ChatCompletionResponse: Decodable {
        let choices: [Choice]
        struct Choice: Decodable {
            let message: Message
        }
        struct Message: Decodable {
            let content: String
        }
    }

    // MARK: - Placeholder substitution

    /// Substitutes `{name}` placeholders with caller-supplied values.
    /// Nil values for the optional fields are simply not substituted —
    /// the template is responsible for omitting the placeholder when
    /// the data is unavailable (most templates reference only the
    /// guaranteed `mascotName` / `roomName`).
    ///
    /// V0.38 — the nil-preserving + sentence-drop set covers {event},
    /// {winner}, {leader}, {caller_rank}, {event_count}, {days_quiet},
    /// {time}, {venue}, {seats_left}, {seats_claimed}. V0.48 extended
    /// the set with {working_hand}, {last_delta}, {season_days_left}
    /// — the state-aware footer kinds reference `{working_hand}` on
    /// the template path, and the LLM prompt path carries the other
    /// two as grounded context. {mascot}, {room}, {member_count} are
    /// always substituted. {date} and {host_note} keep `""` substitution
    /// (no template references them). When the underlying value is nil
    /// the literal `{placeholder}` text is kept in place, and the trailing
    /// `dropSentencesWithPlaceholders` pass removes any sentence that
    /// still contains a `{` character — so a template sentence
    /// referencing missing data silently disappears instead of rendering
    /// broken text.
    private static func interpolate(
        template: String,
        mascotName: String,
        roomName: String,
        context: RoomContext,
        eventDate: Date?,
        eventVenue: String?,
        hostNote: String?,
        seatsLeft: Int?,
        seatsClaimed: Int?
    ) -> String {
        var out = template
        out = out.replacingOccurrences(of: "{mascot}", with: mascotName)
        out = out.replacingOccurrences(of: "{room}", with: roomName)
        out = out.replacingOccurrences(
            of: "{member_count}",
            with: "\(context.memberCount)"
        )

        // V0.38 nil-preserving set. The footer never passes
        // date/venue/seats so legacy logistics placeholders joined
        // this set in V0.38; the sentence-drop pass excises any
        // sentence that still contains a `{`.
        if let winner = context.recentWinnerNames.first {
            out = out.replacingOccurrences(of: "{winner}", with: winner)
        }
        if let leader = context.leaderName {
            out = out.replacingOccurrences(of: "{leader}", with: leader)
        }
        if let rank = context.callerRank {
            out = out.replacingOccurrences(of: "{caller_rank}", with: "\(rank)")
        }
        if let count = context.eventCount {
            out = out.replacingOccurrences(of: "{event_count}", with: "\(count)")
        }
        if let days = context.lastEventDaysAgo {
            out = out.replacingOccurrences(of: "{days_quiet}", with: "\(days)")
        }
        if let title = context.activeEventTitle {
            out = out.replacingOccurrences(of: "{event}", with: title)
        }
        if let eventDate {
            out = out.replacingOccurrences(of: "{time}", with: Self.humanTime(eventDate))
        }
        if let eventVenue, !eventVenue.isEmpty {
            out = out.replacingOccurrences(of: "{venue}", with: " · \(eventVenue)")
        }
        if let seatsLeft {
            out = out.replacingOccurrences(of: "{seats_left}", with: "\(seatsLeft)")
        }
        if let seatsClaimed {
            out = out.replacingOccurrences(of: "{seats_claimed}", with: "\(seatsClaimed)")
        }

        // V0.48 nil-preserving set extension. `{working_hand}` is
        // referenced by the new `.inPlayWithWithdrawal` template
        // cells; the other two are template-path no-ops today (no
        // cell references them yet) — they earn their keep on the
        // LLM prompt path via `buildLLMPrompt`. Sentence-drop pass
        // keeps the body clean when any of the three is nil.
        if let workingHand = context.withdrawnAmount {
            out = out.replacingOccurrences(
                of: "{working_hand}", with: "\(workingHand)"
            )
        }
        if let lastDelta = context.lastWinnerDelta {
            out = out.replacingOccurrences(
                of: "{last_delta}", with: "\(lastDelta)"
            )
        }
        if let seasonDays = context.seasonDaysLeft {
            out = out.replacingOccurrences(
                of: "{season_days_left}", with: "\(seasonDays)"
            )
        }

        // Date / host-note keep their `""` substitution — no template
        // references them in V0.38 (0 uses).
        out = out.replacingOccurrences(of: "{date}", with: "")
        out = out.replacingOccurrences(of: "{host_note}", with: "")

        // Sentence-drop pass — V0.36 (still the same). Splits on
        // `[.!?]` boundaries (keeping the terminator on the segment),
        // drops any segment that still contains a `{` character, then
        // rejoins with a single space. Always runs so templates can
        // rely on it even when all placeholders are populated
        // (no-op in that case).
        out = dropSentencesWithPlaceholders(out)
        return Self.collapseWhitespace(out)
    }

    /// Splits `s` on sentence terminators (`.`, `!`, `?`), keeps the
    /// terminator on the segment, drops any segment still containing
    /// a `{` (an unsubstituted placeholder from the V0.36 nil-safe
    /// set), and rejoins the survivors with a single space. Pure.
    private static func dropSentencesWithPlaceholders(_ s: String) -> String {
        var segments: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                segments.append(current)
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            segments.append(current)
        }
        return segments.filter { !$0.contains("{") }.joined(separator: " ")
    }

    private static let humanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let humanTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static func humanDate(_ date: Date) -> String {
        humanDateFormatter.string(from: date)
    }

    private static func humanTime(_ date: Date) -> String {
        humanTimeFormatter.string(from: date)
    }

    /// Collapses runs of whitespace produced by removing optional
    /// placeholders, and trims the leading/trailing edges. Keeps
    /// punctuation in place so the voice reads naturally.
    private static func collapseWhitespace(_ s: String) -> String {
        let components = s.split(whereSeparator: { $0.isWhitespace })
        let joined = components.joined(separator: " ")
        // Re-attach a leading space if a " · " or " — " was collapsed
        // away — the templates use these as glues and the result
        // should read naturally. We just trim edges; the templates
        // already keep punctuation tight.
        return joined
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
