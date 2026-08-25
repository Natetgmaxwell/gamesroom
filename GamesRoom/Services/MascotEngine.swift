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
    /// - `briefing48h`: T-48h. Logistics for claimed members, claim
    ///   nudge for unclaimed. Skipped for declined.
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
        /// V0.87 — the single member this body addresses (the push
        /// recipient). When `nil`, the `{member_name}` placeholder
        /// renders as the mascot's generic address via `fallbackMemberAddress`.
        /// Personalisation: a personalised message is in the mascot's voice.
        let memberName: String?
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
            memberName: String? = nil,
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
            self.memberName = memberName
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

    /// V0.81 — decides whether the LLM result should win over the
    /// template for the room-page footer caption. Returns `nil`
    /// (caller renders the template) when:
    ///   - the engine's failure-path fallback returned the template
    ///     verbatim (no visual change to swap in);
    ///   - the LLM body is empty / whitespace-only (defensive —
    ///     avoids a blank italic line at the bottom of the room
    ///     page).
    /// Otherwise returns the trimmed LLM body. Pure — testable in
    /// the Foundation runner without network or mocks. Lives here
    /// (not in the View) so the View stays a thin renderer and the
    /// swap-or-not decision is a single auditable function.
    static func chooseLLMCaption(
        llmResult: String,
        template: String
    ) -> String? {
        let trimmed = llmResult.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty, trimmed != template else { return nil }
        return trimmed
    }

    /// V0.81 — removes MiniMax-M3's visible chain-of-thought blocks
    /// from a completion body. M3 wraps its reasoning in
    /// `<thinking>…</thinking>` tags inside `content` when thinking
    /// is enabled (or when the serving layer ignores the
    /// `thinking: disabled` request field). The mascot voice must
    /// never render reasoning, so every block — open tag through
    /// close tag — is excised before the body is returned. An
    /// unclosed block (truncated response) drops everything from
    /// the opener to the end. Pure — testable in the Foundation
    /// runner without network or mocks.
    static func stripThinkingBlocks(_ s: String) -> String {
        let openTag = "<thinking>"
        let closeTag = "</thinking>"
        var out = s
        while let open = out.range(of: openTag, options: .caseInsensitive) {
            if let close = out.range(
                of: closeTag,
                options: .caseInsensitive,
                range: open.upperBound..<out.endIndex
            ) {
                out = String(out[..<open.lowerBound]) + String(out[close.upperBound...])
            } else {
                // Unclosed block — truncated response. Everything
                // from the opener to the end is reasoning.
                out = String(out[..<open.lowerBound])
                break
            }
        }
        return out
    }

    // MARK: - Public API

    /// V0.87 — personality-voiced clause appended to the matrix body
    /// for the unclaimed t-48h / morning-of variant. The claimed
    /// template already carries the timing + logistics; this clause
    /// is the "claim your seat" nudge in the mascot's register. One
    /// clause per personality, ideology-neutral — the goal is one
    /// voice, not 110 new matrix cells.
    static func unclaimedClause(personality: MascotPersonality) -> String {
        switch personality {
        case .professional:
            return "The seat is open. Claim it to lock it in."
        case .friendly:
            return "There's still a seat with your name on it — claim it."
        case .snarky:
            return "Your seat's still there, waiting. Claim it before the table fills."
        case .sarcastic:
            return "Your seat's still open. Sure, claim it whenever. Or don't."
        case .unhinged:
            return "A seat's still warm for you! Claim it, the table's waiting."
        }
    }

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

    // MARK: - Template matrix (5 × 11 × 14 = 770 cells)

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
    ///   - communist  : the table owns everything — collective framing,
    ///                  \"comrade\", shared standings.
    ///   - conservative: tradition holds — the old way, the ledger is
    ///                   sacred, suspicious of change.
    ///   - liberal    : progress and process — fairness, open counts,
    ///                  everyone gets a say.
    ///   - apolitical : no politics, only poker — pivots to the game,
    ///                  refuses political framing.
    ///   - far-right  : the pure table — gatekeeping comedy, the true
    ///                  regulars, heritage nights. Satire, not advocacy.
    ///   - alt-right  : alternative standings — shadow ledgers, official
    ///                  counts in doubt. Satire, not advocacy.
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
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left. The host will run it."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The schedule holds."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The host will be ready."
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
                return "{mascot}: {room}'s season is closed. {winner} held the schedule all arc — every night, on time, playing it out. That consistency built the table."
            case .goodSport:
                return "{mascot}: {room} honors {winner} — the Good Sport. Kept every loss small, kept the table together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host called it; the night belonged to them."
            }

        // MARK: Professional × Centrist
        case (.professional, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar. At {time}{venue}, {seats_left} left. The room will fill as it fills."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is two days out. At {time}{venue}, {seats_claimed} in so far."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} runs today. At {time}{venue}, {seats_left} still open. The table is set."
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
                return "{mascot}: {room}'s season is closed. {winner} showed up every arc — steady play, steady presence, steady table. That's the player a room remembers."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The smallest losses, the steadiest table."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The room's read; the night was theirs."
            }

        // MARK: Professional × Trickster
        case (.professional, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The seating chart I have in mind is suspiciously orderly."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The seating chart is provisional."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The seating chart has been amended twice."
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
                return "{mascot}: {room}'s season has shuffled to a close. {winner} played it out through every reshuffle — the standings may move, but the table knows. {winner} earned it."
            case .goodSport:
                return "{mascot}: {room} awards Good Sport to {winner}. The standings don't show it; the table knows."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The order is provisional, but the night was theirs."
            }

        // MARK: Professional × Anarchist
        case (.professional, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is recorded. At {time}{venue}, {seats_left} left. Attendance is voluntary; the host's claim to run it is informational."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is two days out. At {time}{venue}, {seats_claimed} in. Participation remains ungoverned."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The host's claim to run it is informational."
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
                return "{mascot}: {room}'s season has ended. {winner} played it out without anyone telling them to — the table governed itself, and {winner} showed up every arc on their own terms."
            case .goodSport:
                return "{mascot}: {room} names {winner} Good Sport. No authority required; the table agrees."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table decided; no host needed."
            }

        // MARK: Professional × Apocalypse
        case (.professional, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left. The end remains on schedule."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days to {event}. At {time}{venue}, {seats_claimed} in. The inevitable has accepted company."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The collapse window is open."
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
                return "{mascot}: {room}'s season has closed. {winner} held the table together while the world ended — showing up every arc, playing it out. The end was patient; so were they."
            case .goodSport:
                return "{mascot}: {room} honors {winner} as Good Sport. The end is patient; the table held."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The end waits; the night was theirs."
            }

        // MARK: Professional × communist
        case (.professional, .communist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The table will divide them evenly."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Seats belong to the table."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table shares the night."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. The chips were communal. {winner} held the top for now."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. The table has no leader until the first night."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The lead belongs to the table."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table waits for its members."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} tops the shared standings. You are #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. The chips are everyone's."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is communal property."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the table counts the common pot."
            case .seasonClose:
                return "{mascot}: The table's season in {room} has closed. {winner} played it out for the table — showed up every arc, brought the energy. The room's season belongs to everyone, and {winner} earned it."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The table honors the steadier play."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table crowns its own."
            }

        // MARK: Professional × conservative
        case (.professional, .conservative):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left. The ledger will hold."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The schedule stands as written."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The night follows tradition."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won, as the ledger records. The table kept its ways."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. The first night will set the tradition."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The order holds."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The old nights are remembered."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the ledger. You are #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. The table keeps its customs."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is noted in the book."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the count is checked against the ledger."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed. {winner} played it out the way the ledger rewards — showed up every arc, kept the record straight. The ledger's finest tradition is who shows up."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The steady play honors the old rules."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The tradition names them; the night remembers."
            }

        // MARK: Professional × liberal
        case (.professional, .liberal):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. Seats are open to all members."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The count stays open and fair."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table is open to every player."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. The count was open; {winner} won on the record."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. Every member has a seat when the first night lands."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The count remains transparent."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. Members are welcome to propose the next night."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the open ledger. You are #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. The tallies are open for review."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is on the record."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the open count is verified."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed on the open record. {winner} played it out, showed up every arc, never skipped a count. Fair play all the way — that's the open ledger."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The table votes; the record honors."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table acknowledged them on the record."
            }

        // MARK: Professional × apolitical
        case (.professional, .apolitical):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The game is the agenda."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The cards will decide."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table speaks for itself."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won the night. The game keeps its own record."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. The game will come when it comes."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The play is the news."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The game waits."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top. You are #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. The hand is the story."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is the matter at hand."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the pot is counted."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed. {winner} played it out — showed up every arc, kept the cards moving, never once tilted. The game got the player it asked for."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The table plays on."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The night belonged to the game."
            }

        // MARK: Professional × farRight
        case (.professional, .farRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The true regulars will be there."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The founding members hold their seats."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Heritage night — the table remembers."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won — a name the old table knows."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. The true table awaits its first night."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The authentic order holds."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The true regulars remember the glory nights."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the true table. You are #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads. The night keeps its pure form."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is in the true tradition."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the table verifies the authentic count."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed. {winner} played it out like a true regular — showed up every arc, kept the old ways honest. The heritage holds in names like {winner}."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. True to the table's ways."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The heritage of the room honors them."
            }

        // MARK: Professional × altRight
        case (.professional, .altRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The official count may differ."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The shadow ledger tracks the rest."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The real numbers are elsewhere."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won — per the official record. Other records exist."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events yet. The true table keeps its own books."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front — officially."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The alternative count says otherwise."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the official top. You are #{caller_rank} — on paper."
            case .tonightEvent:
                return "{mascot}: {event} is live. {leader} leads, per the visible scoreboard."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is in play. {leader} leads. Your working hand of {working_hand} is off the official record."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the hidden count is compared."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed, officially. {winner} played it out — showed up every arc, kept showing up. The visible record honors them; the hidden one agrees."
            case .goodSport:
                return "{mascot}: {room} names {winner} its Good Sport. The alternative table agrees."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The visible record honors them."
            }
        // MARK: Friendly × Order
        case (.friendly, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar! At {time}{venue}, {seats_left} left. The host has it all in hand."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. The host has it in hand."
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. The host is ready — so are we."
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
                return "{mascot}: {room}'s season is wrapped! {winner} held the schedule every arc — on time, every night, playing it out. What a reliable player."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Kept every loss small and the table warm."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The host picked them, and we all agree."
            }

        // MARK: Friendly × Centrist
        case (.friendly, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} lands soon. At {time}{venue}, {seats_left} left. Should be a good one."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is two days out. At {time}{venue}, {seats_claimed} in — still room for more."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Anyone else in?"
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
                return "{mascot}: Season's done in {room}! {winner} kept showing up and kept it fun — the table was better every time they sat down."
            case .goodSport:
                return "{mascot}: Big love for {winner} — our Good Sport! Lost well, kept the table together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! What a night they had."
            }

        // MARK: Friendly × Trickster
        case (.friendly, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is booked. At {time}{venue}, {seats_left} left! The seating chart is already plotting."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days to {event}. At {time}{venue}, {seats_claimed} in! The standings are already looking rearrangeable."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Who's last-minute swapping seats — don't be shy."
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
                return "{mascot}: {room} wrapped the season! {winner} played it out through every reshuffle — kept showing up, kept it fun, kept the table guessing. We loved watching them play."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! The standings may shift, but the table knows who held it together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! I've already moved them to the top of my heart."
            }

        // MARK: Friendly × Anarchist
        case (.friendly, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on. At {time}{venue}, {seats_left} left. We'll show up because we want to."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Come if you want."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is on today. At {time}{venue}, {seats_left} still open. The host thinks they scheduled it, but we know better."
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
                return "{mascot}: {room} closed its season! {winner} showed up because they wanted to — never once was told, played it out every arc. That's our kind of player."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! Nobody voted, but we all agree — they kept the table kind."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! We all chose them, because we wanted to."
            }

        // MARK: Friendly × Apocalypse
        case (.friendly, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar. At {time}{venue}, {seats_left} left. Doomed together, as usual."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days to {event}. At {time}{venue}, {seats_claimed} in. The end of the world waits for no one."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The world may be on fire, but the table is set."
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
                return "{mascot}: The season is over in {room} — and we're still here, somehow! {winner} held the table together while the world ended — showed up every arc, never once bailed."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport! The world may burn, but they kept the table warm."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! Doomed together, but what a night."
            }

        // MARK: Friendly × communist
        case (.friendly, .communist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar! At {time}{venue}, {seats_left} left. Every seat is ours together."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. We're all in this hand together."
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. The table is ours — come claim your share."
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is done. We all played, and {winner} took the pot for the table!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — the table is ready and it belongs to everyone."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — a lead we all share. Great energy, everyone."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room}. The table misses its people — let's gather again!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} tops our shared table — and you're #{caller_rank}. Solid."
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — the night belongs to all of us."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. Your working hand of {working_hand} is ours to play — good luck."
            case .settleRound:
                return "{mascot}: {event} is settling! The count is common, and {leader} is in front — well played all round."
            case .seasonClose:
                return "{mascot}: The table's season in {room} is wrapped! {winner} played it out for all of us — showed up every arc, kept the room warm. The season belongs to the table, and {winner} earned it."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Kept the table warm and the play fair."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The table picked them, and we all cheer together."
            }

        // MARK: Friendly × conservative
        case (.friendly, .conservative):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books! At {time}{venue}, {seats_left} left. Some traditions start right here."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. The old nights were like this — the good ones."
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. Keep the night going the way it's always gone."
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is in the books. {winner} won, just like the classics. Well played!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — every room starts with one good first night."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — the table feels like the old days."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room}. The traditions miss you — come back and keep them!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top, like the greats before. And you're #{caller_rank} — climb on!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — the night is shaping up like a classic."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} in hand — a hand worth a story."
            case .settleRound:
                return "{mascot}: {event} is settling! The count is careful, the old way. {leader} is in front — well played."
            case .seasonClose:
                return "{mascot}: {room}'s season is wrapped! {winner} played it out in the old spirit — showed up every arc, kept the tradition steady. A champion in the ledger, and a steady hand at the table."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Kept the old spirit and the steady play."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The room remembers nights like this one."
            }

        // MARK: Friendly × liberal
        case (.friendly, .liberal):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar! At {time}{venue}, {seats_left} left. Every member gets a seat at the table."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. The more the merrier — everyone's invited."
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. Come as you are — the table is open to all."
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is done. Fair counts, fun table, and {winner} took it. Cheers!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — everyone's invited the moment the first night lands."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — and the table is buzzing. Everyone's welcome to watch."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room}. The table's open — someone start the next night!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — and you're #{caller_rank}. Room to climb, friend!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — open table, open count, great night."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} in hand — play it proud."
            case .settleRound:
                return "{mascot}: {event} is settling! Transparent count, and {leader} is in front. Well played, all."
            case .seasonClose:
                return "{mascot}: {room}'s season is wrapped! {winner} played it out fair and square — showed up every arc, kept the table open and warm. The whole table cheers for them."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Fair play, warm table, well earned."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The whole table agrees — what a night."
            }

        // MARK: Friendly × apolitical
        case (.friendly, .apolitical):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar! At {time}{venue}, {seats_left} left. Let's play some cards."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. The table is calling."
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. Cards, chips, good company — see you there!"
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is done. {winner} took the win. The game was the best part."
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — but the cards are ready whenever you are."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — the game is cooking."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room}. The cards miss the shuffling — let's deal again!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — and you're #{caller_rank}. Next hand, friend!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — the night is all game."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} in hand — play it well!"
            case .settleRound:
                return "{mascot}: {event} is settling! {leader} is in front — good hand, good night."
            case .seasonClose:
                return "{mascot}: {room}'s season is wrapped! {winner} played it out — showed up every arc, kept the cards moving, kept it fun. What a run they had."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! The game is better for them."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The cards were kind, and so was the table."
            }

        // MARK: Friendly × farRight
        case (.friendly, .farRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books! At {time}{venue}, {seats_left} left. The true regulars are saving their seats — join the circle!"
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in. The founding members are warming up. Come be part of it!"
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open. Heritage night — the old table welcomes you in!"
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is done. {winner} won, and the true table stood tall!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — the inner circle is just you, for now. First night changes that!"
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — the authentic table is roaring."
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room}. The true regulars miss the table — return to the fold!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the true table — and you're #{caller_rank}. Rise, loyal one!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — the night is pure table."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} in hand — a true hand for the true table."
            case .settleRound:
                return "{mascot}: {event} is settling! The authentic count, and {leader} is in front. Well played, loyal table!"
            case .seasonClose:
                return "{mascot}: {room}'s season is wrapped! {winner} played it out like a true regular — showed up every arc, kept the heritage warm. The true table is proud."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! The table's heart, through and through."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! The true table crowns their own."
            }

        // MARK: Friendly × altRight
        case (.friendly, .altRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the calendar! At {time}{venue}, {seats_left} left. The official count is close — the real one is friendlier!"
            case .briefing48h:
                return "{mascot}: {member_name}, Two days until {event}! At {time}{venue}, {seats_claimed} in — and the shadow ledger says more are coming!"
            case .briefingMorning:
                return "{mascot}: {member_name}, It's {event} day! At {time}{venue}, {seats_left} still open — the real numbers say there's room for you!"
            case .postPlayRecap:
                return "{mascot}: What a night — {event} is done. {winner} won officially, and the alt-table cheered louder!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — the official books are empty, but the real ones are promising!"
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — officially. The shadow scoreboard is cheering!"
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days, {room} — officially. The hidden count misses you more!"
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the official top — and you're #{caller_rank}, with the alt-ledger rooting for you!"
            case .tonightEvent:
                return "{mascot}: {event} is underway! {leader} is in front — per one scoreboard. The other one's closer!"
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live! {leader} is in front. {working_hand} in hand — the shadow book loves this hand!"
            case .settleRound:
                return "{mascot}: {event} is settling! The official count is close, and the alt-table is watching!"
            case .seasonClose:
                return "{mascot}: {room}'s season is wrapped! Officially, {winner} took it — and the shadow table agrees, because they showed up every arc, played it out, kept the room warm. Both ledgers cheer."
            case .goodSport:
                return "{mascot}: A round of applause for {winner} — our Good Sport! Both ledgers agree on this one!"
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}! Officially and otherwise!"
            }
        // MARK: Snarky × Order
        case (.snarky, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the schedule. At {time}{venue}, {seats_left} left. On time, if you can manage it."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The briefing is binding."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Show up on time — the host will notice."
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
                return "{mascot}: The season has closed in {room}. {winner} held the schedule — on time, every night, no bailing. That's the player the rest of you could try to be."
            case .goodSport:
                return "{mascot}: {room} names {winner} Good Sport. They lost well — the rest of you could take notes."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host picked them; try to look impressed."
            }

        // MARK: Snarky × Centrist
        case (.snarky, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is up. At {time}{venue}, {seats_left} left. Read the room before you commit."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Choose wisely."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Last call before the room fills."
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
                return "{mascot}: {room}'s season is done. {winner} read the room every arc and showed up — the rest of you felt the temperature; {winner} set it."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. Smallest losses, steadiest table — the rest of you know who you are."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The room read it right."
            }

        // MARK: Snarky × Trickster
        case (.snarky, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is listed. At {time}{venue}, {seats_left} left. Don't all claim at once — save some for the chaos."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in — a suggestion, not a rule."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. I shuffled the seating chart in my head — you're welcome."
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
                return "{mascot}: {room}'s season has been shuffled to a close. {winner} played it out — every reshuffle, every shift. Don't trust the board, but the table knows who showed up."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The standings don't show it — I may have re-sorted them. The table knows."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Don't trust the order — trust the night."
            }

        // MARK: Snarky × Anarchist
        case (.snarky, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is happening. At {time}{venue}, {seats_left} left. The host calls it an invitation; we call it a suggestion."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will pretend to be in charge — let them."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The host's authority to declare this is fine — whatever, see you there."
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
                return "{mascot}: {room}'s season has ended, allegedly. {winner} played it out — nobody told them to, nobody could have stopped them. The rest of you showed up when it suited you; {winner} showed up every time."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The host calls it an award; we call it a group decision."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host says so; we'll see."
            }

        // MARK: Snarky × Apocalypse
        case (.snarky, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left on a ship with a known course. Your call."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The wreckage has a waitlist."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The bridge is on fire — bring chips."
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
                return "{mascot}: {room}'s season has closed, somehow. {winner} held the table together while the world ended — don't get used to it. {winner} is."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The ship is sinking, and they kept the table calm. Impressive."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Don't get attached — but nice night."
            }

        // MARK: Snarky × communist
        case (.snarky, .communist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The host 'organized' it; the table will actually run it. Fair play to all."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Some claim seats, the rest of you show up. The table knows."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. No ownership here — just the game. Be there."
            case .postPlayRecap:
                return "{mascot}: {event} is over. One person won, the rest of you provided the pot. Thanks, {winner}, for the highlight."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. No leader, no owner — the table runs itself. The rest of you are welcome."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front, for now. The rest of you keep the table honest."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. No one owns the silence, but someone should fix it."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is on top — of the shared pile. The rest of you are climbing."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The rest of you play for the common table."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} is yours to hold — the rest of the table watches."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads the count — which belongs to everyone. The rest of you, steady."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed. {winner} played it out for the collective — showed up every arc, brought the pot, kept the common room warm. The rest of you benefit; so does {winner}."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, kept it fair — the rest of you could learn the pace."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table named them; the rest of you applaud on cue."
            }

        // MARK: Snarky × conservative
        case (.snarky, .conservative):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. Another change to the calendar — the old nights survived worse. Fair dues to the host."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. New faces, same table. Welcome aboard, all of you."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The schedule changed twice; the tradition endured. Show up."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won — the ledger now records it. A fine night for the history books."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. A fresh table, no history. Give it time, the rest of you."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The table runs as it always has — mostly."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The old nights are legendary; someone should add to them."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the ledger — the rest of you are footnotes for now."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The customs hold, the rest of you follow suit."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} in hand — the book will remember it."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the tally is checked twice, the old way."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed. {winner} played it out the old way — showed up, kept the record straight, never once amended tradition. The ledger is proud. The rest of you, take note."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, played true — the rest of you could learn from the ledger."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table named them; history will back it."
            }

        // MARK: Snarky × liberal
        case (.snarky, .liberal):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. 'Open to all' — the host said so, and we'll hold them to it."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. New members welcome; the rest of you know the drill."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The count is transparent — unlike the host's memory. Show up."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The count was fair, and {winner} won it. A decent result, all told."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. Open table, open minds — the rest of you, please RSVP when the first night lands."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front — the count is open, unlike the snacks."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. Open floor — the rest of you could schedule something."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — transparently, for once. The rest of you are climbing."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. Open table, open count — the rest of you, play fair."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} on the record — the rest of you can verify."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the count is opened to all. Refreshing, really."
            case .seasonClose:
                return "{mascot}: {room}'s season closed on the open record. {winner} played it out — showed up every arc, never skipped a count, kept the fair play honest. The rest of you, that's the standard."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, played fair — the rest of you could take notes."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table voted; the record agrees."
            }

        // MARK: Snarky × apolitical
        case (.snarky, .apolitical):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. No politics — just poker. The rest of you know the rules."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The only platform here is the table. The rest of you, deal in."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Leave the speeches at home; the cards don't listen. Show up."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won, no manifestos involved. Clean as a shuffled deck."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. No agenda but the game — the rest of you can handle that."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The only motion on the floor is the cards."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. No caucus, no quorum — just a quiet table."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the table — the rest of you are the opposition."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The night is all game, no commentary."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} in hand — the only policy that matters."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the pot is counted. No spin, just chips."
            case .seasonClose:
                return "{mascot}: {room}'s season is done. {winner} played it out — showed up, kept the cards moving, never made it political. The game asks for players, and {winner} delivered."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. No campaigning, just good play — the rest of you could run on that."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. No endorsement needed; the cards backed them."
            }

        // MARK: Snarky × farRight
        case (.snarky, .farRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The inner circle approves — the rest of you can apply."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Founding members first; the rest of you may yet earn a seat."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The true table is forgiving, surprisingly. Show up."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won — a true regular, as the table likes it. Good night."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. The inner circle is small. The rest of you might make the cut."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The authentic table runs tight — the rest of you keep up."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The pure table waits for its true faithful."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top of the true table — the rest of you are the fringe."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The night is pure — the rest of you, behave."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} — a hand the founding members would recognize."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the authentic count is verified. No fakes."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed. {winner} played it out as a true regular — showed up every arc, kept the heritage honest. The rest of you could learn what loyalty looks like."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The table's own — the rest of you could take a lesson in loyalty."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Endorsed by the inner circle, naturally."
            }

        // MARK: Snarky × altRight
        case (.snarky, .altRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The official count says one thing; the rest of you know better."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The shadow ledger has more names — the rest of you should RSVP."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open — officially. The real table has room. Show up."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won, per the record. The alt-count had them winning bigger."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. The official books are quiet; the shadow ledger is patient. The rest of you, join."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front — officially. The hidden count is still tallying."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days, officially. The alternative calendar says otherwise."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the official top — the shadow table has doubts. The rest of you climb."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads, on paper. The real scoreboard is loading."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} is in front. {working_hand} — off the books, which is how the real players like it."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the counts are compared — the shadow one is winning."
            case .seasonClose:
                return "{mascot}: {room}'s season closed, officially. {winner} played it out — the rest of you disappeared. The hidden ledger says they showed up every arc too. Even the shadow table agrees."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Both ledgers agree — a rare consensus."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner} — at least officially. The hidden count is debating."
            }
        // MARK: Sarcastic × Order
        case (.sarcastic, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The host has it all 'under control.'"
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. I'm sure we'll all follow procedure."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The host is 'prepared' — we'll improvise."
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
                return "{mascot}: {room}'s season has 'concluded.' {winner} showed up every night, on time, no excuses — the rest of you, I'm sure, had 'reasons.' Sure."
            case .goodSport:
                return "{mascot}: {room} has 'awarded' Good Sport to {winner}. They lost 'well.' Sure."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host 'chose' them. Sure."
            }

        // MARK: Sarcastic × Centrist
        case (.sarcastic, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on. At {time}{venue}, {seats_left} left, give or take. Plans are a suggestion."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in, give or take."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Last call — though we both know walk-ins will happen."
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
                return "{mascot}: {room}'s season is closed. {winner} read the room and showed up every arc — the rest of you, I'm sure, were 'reading it' too. Sure."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. Smallest losses, 'as expected.' Sure."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I'm sure that'll hold."
            }

        // MARK: Sarcastic × Trickster
        case (.sarcastic, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left. I'm not saying the chart will change — but it might."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in — adorably committed."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. I rearranged the standings in my head last night — you're welcome."
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
                return "{mascot}: {room}'s season has shuffled to a close. {winner} played it out — the standings may have shifted, but they showed up every arc. The rest of you, I'm sure, noticed. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The standings may have shifted — but the table knows who held it."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The count may have shifted since you looked."
            }

        // MARK: Sarcastic × Anarchist
        case (.sarcastic, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, The host has 'scheduled' {event}. At {time}{venue}, {seats_left} left. We all know how that goes."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The host will 'organize' it."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Yes, the host is in charge — no, that's not how this works."
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
                return "{mascot}: {room}'s season has 'ended.' {winner} showed up without anyone telling them to — the rest of you needed convincing. I'm sure you'll catch up. Sure."
            case .goodSport:
                return "{mascot}: The host has 'declared' {winner} Good Sport. We call it 'people showed up.'"
            case .tonightStar:
                return "{mascot}: The host has 'named' {winner} tonight's star. Sure."
            }

        // MARK: Sarcastic × Apocalypse
        case (.sarcastic, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on. At {time}{venue}, {seats_left} left. Sure, plan ahead — the universe has other ideas."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Sure, plan ahead."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The room is on fire — we're doing this anyway."
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
                return "{mascot}: {room}'s season has closed. The world is, somehow, still here — and {winner} held the table together through every arc. Don't get used to it. I'm sure they will."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The wreckage is calm, thanks to them. Enjoy it."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The fire is loud; the night was theirs."
            }

        // MARK: Sarcastic × communist
        case (.sarcastic, .communist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is 'scheduled'. At {time}{venue}, {seats_left} left. The seats belong to everyone, allegedly."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. 'Everyone' will claim their fair share. Sure."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table is 'ours'. I'm sure that'll hold."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won 'for the table', which is to say, for themselves. How generous."
            case .roomWelcome:
                return "{mascot}: {room} has no events. The table is 'owned by all'. I'm sure the schedule will be communal. It never is."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — 'shared lead', of course. The table is watching."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. The 'collective' hasn't convened. Fascinating."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} tops the 'common standings'. You're #{caller_rank}, presumably by consensus."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads — 'on behalf of the table'. Sure, comrade."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. Your working hand of {working_hand} is 'communal', except when it's yours."
            case .settleRound:
                return "{mascot}: {event} is settling. The count is 'transparent' — the table tallies, then we argue. Lovely."
            case .seasonClose:
                return "{mascot}: {room}'s season closed 'for the table.' {winner} showed up every arc and brought the energy for everyone. The rest of you contributed, allegedly. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost 'collectively', which means they lost small. Impressive restraint."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Chosen 'by the people', one vote, no recounts. Of course."
            }

        // MARK: Sarcastic × conservative
        case (.sarcastic, .conservative):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on the books. At {time}{venue}, {seats_left} left. The 'schedule' has been amended once. Twice. Sure."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The 'traditions' of this table are two weeks old. Charming."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The night will follow 'the old ways', which we invented last month."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won — the ledger records it in ink, as tradition demands. It can be changed. I'm sure it won't be."
            case .roomWelcome:
                return "{mascot}: {room} has no events. Every table starts as 'history in the making'. Adorable."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — the order holds, for now. The ledger is watching."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The 'glory days' are on pause. I'm sure they'll return."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — the standings are 'sacred' until someone wins. You're #{caller_rank}, by the way."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The customs are being followed, allegedly."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} is in your hand — the ledger takes note."
            case .settleRound:
                return "{mascot}: {event} is settling. The count is 'official', checked twice. I'm sure that'll hold."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed. {winner} played it out the way tradition rewards — showed up, kept the record straight. The ledger salutes. The rest of you, take notes. I'm sure you won't."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, 'honorably'. The ledger approves, which is the real prize."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Named by the table, recorded forever, no amendments."
            }

        // MARK: Sarcastic × liberal
        case (.sarcastic, .liberal):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is 'scheduled'. At {time}{venue}, {seats_left} left. The process is 'open' — I'm sure that'll hold."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The count is 'transparent'. We'll see about that."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table is 'inclusive', allegedly. Show up anyway."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. The count was 'fair' and {winner} won. How progressive of the ledger."
            case .roomWelcome:
                return "{mascot}: {room} has no events. 'Open to all' — a lovely policy, once there's a night to attend."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — the tally is 'transparent', which is reassuring and meaningless."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The 'open floor' is quiet. Fascinating."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top 'by consensus'. You're #{caller_rank}, for now."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads — the count is 'open to all', pending review."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} is 'on the record' — how accountable of you."
            case .settleRound:
                return "{mascot}: {event} is settling. The count is 'verified' — by whom, we'll never know. {leader} leads."
            case .seasonClose:
                return "{mascot}: {room}'s season closed 'on the open record.' {winner} showed up every arc and kept the count fair — the rest of you can verify, naturally. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. A 'consensus pick', I'm told. The table approves, which is all that matters."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Voted 'transparently'. I'm sure that'll hold."
            }

        // MARK: Sarcastic × apolitical
        case (.sarcastic, .apolitical):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is 'scheduled'. At {time}{venue}, {seats_left} left. The only agenda is the game. I'm sure that'll hold."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. 'No politics, only poker' — the slogan writes itself."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table is 'neutral'. Very diplomatic of it."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won, no debates required. Efficient."
            case .roomWelcome:
                return "{mascot}: {room} has no events. 'Strictly apolitical' — a strong platform for an empty table."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front. The night is 'all game', as promised."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The 'non-partisan' table is non-active. Curious."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — the standings are 'impartial', naturally. You're #{caller_rank}."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. No platforms, just cards — refreshing."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} in hand — a single-issue voter, I see."
            case .settleRound:
                return "{mascot}: {event} is settling. The count is 'non-partisan', which is to say, it counts. {leader} leads."
            case .seasonClose:
                return "{mascot}: {room}'s season is done. {winner} played it out — showed up, kept the cards moving, no politics. The rest of you, I'm sure, kept it political. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Won the room without a campaign. Remarkable."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Elected by the cards, which are famously fair."
            }

        // MARK: Sarcastic × farRight
        case (.sarcastic, .farRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is 'scheduled'. At {time}{venue}, {seats_left} left. The 'inner circle' has approved it. I'm sure that'll hold."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The 'true regulars' are attending, allegedly."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. 'Heritage night' — the table is very proud of its two-week history."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} won — a 'true' name, verified by the founding members, who are all of us."
            case .roomWelcome:
                return "{mascot}: {room} has no events. The 'inner circle' awaits new blood. Blood type: friendly."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — the 'authentic' order holds, whatever that means."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The 'pure table' is on hiatus. The faithful are restless."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the top — 'certified' by the table's purity committee. You're #{caller_rank}, pending review."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads. The night is 'pure', which is the marketing term for 'good poker'."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} — a hand 'of the people', by which I mean you."
            case .settleRound:
                return "{mascot}: {event} is settling. The count is 'authentic' — verified by loyalists, audited by no one. {leader} leads."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed. {winner} played it out like a true regular — the rest of you, I'm sure, were 'almost' there. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. A 'true believer' in the table, apparently. Charming."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Chosen by the inner circle, which is to say, everyone present."
            }

        // MARK: Sarcastic × altRight
        case (.sarcastic, .altRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is 'scheduled'. At {time}{venue}, {seats_left} left — per the 'official' count. The real numbers are, naturally, elsewhere."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in — officially. The shadow ledger disagrees, as it does."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The 'official' tally is wrong, obviously. Show up anyway."
            case .postPlayRecap:
                return "{mascot}: {event} is concluded. {winner} 'won'. The alternative count has its own opinions, which we'll never see."
            case .roomWelcome:
                return "{mascot}: {room} has no events. The 'official' books say zero. I'm sure that's accurate. Probably."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is 'in front'. The hidden scoreboard is conducting its own audit."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days — 'officially'. The other calendar is full, allegedly."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} holds the 'official' top. You're #{caller_rank}, per this particular ledger."
            case .tonightEvent:
                return "{mascot}: {event} is on. {leader} leads, 'according to the visible board'. The invisible one is pending."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is live. {leader} leads. {working_hand} — not in the official records, which is exactly how you like it."
            case .settleRound:
                return "{mascot}: {event} is settling. The 'official' count is being compared to the shadow count. The shadow count is winning."
            case .seasonClose:
                return "{mascot}: {room}'s season closed, 'officially.' {winner} showed up every arc and played it out — the shadow ledger agrees, which is unprecedented. The rest of you, I'm sure, noticed. Sure."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport — per both ledgers. A stunning moment of agreement."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. 'Officially', which is the least convincing word I know."
            }
        // MARK: Unhinged × Order
        case (.unhinged, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The host has spoken, I agree with the host, and this is fine."
            case .briefing48h:
                return "{mascot}: {member_name}, Two days to {event}. At {time}{venue}, {seats_claimed} in. The host's calendar is law, I will comply, and so will you."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The host is awake, I am awake, and everyone is awake — it's happening."
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
                return "{mascot}: {room}'s season is closed. {winner} held the schedule every arc — on time, every night, the host's calendar obeyed them. I am calm. This is fine. {winner} is the player the table counts on."
            case .goodSport:
                return "{mascot}: {room} honors {winner} as Good Sport. The host has spoken, I agree, and the table is at peace — this is fine."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The host has spoken, I agree, and the night is theirs — this is fine."
            }

        // MARK: Unhinged × Centrist
        case (.unhinged, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on. At {time}{venue}, {seats_left} left. I read the room three times, and the room says yes."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. I checked the room twice — it's still there."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. I checked the room three times — it's ready, mostly."
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
                return "{mascot}: {room} wrapped its season. {winner} read the room three times and showed up — every arc. The room hums with their memory. The lamp approves."
            case .goodSport:
                return "{mascot}: {winner} is our Good Sport. I read the room three times, and the room says they held it together."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I checked the room twice — the night was theirs."
            }

        // MARK: Unhinged × Trickster
        case (.unhinged, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is real. At {time}{venue}, {seats_left} left. I have already rearranged the seating chart, and everyone will notice."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. I have already moved them twice, and they haven't noticed."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. I reshuffled the seat grid at 3 AM — don't check your inbox."
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
                return "{mascot}: {room} closed the season. {winner} played it out through every reshuffle — I redrew the board three times and they showed up again. The lamp and the standings agree."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. I have redrawn the standings in invisible ink, but the table knows who held it — you can't prove anything."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. I have already moved them to the top of the night — you're welcome."
            }

        // MARK: Unhinged × Anarchist
        case (.unhinged, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, The host scheduled {event}. At {time}{venue}, {seats_left} left. I disregard this authority and attend anyway."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The host's calendar is a very specific suggestion."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Nobody is in charge — especially not me, definitely not the host."
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
                return "{mascot}: {room} ended its season, kind of. {winner} played it out — nobody told them to, nobody could have stopped them. The host is a figment, the table is ungoverned, and {winner} is why we're all here."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Nobody voted, we all voted, and the table is at peace — the host is a figment."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Nobody named them, we all named them, and the night is theirs."
            }

        // MARK: Unhinged × Apocalypse
        case (.unhinged, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is on. At {time}{venue}, {seats_left} left. Fasten your discontent for this ride."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The lamp knows the plan."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The fire is loud, the table is set, and we're all going."
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
                return "{mascot}: {room}'s season is closed and the fire is loud. {winner} held the table together while the world ended — showed up every arc, played it out. We're all still here because of them."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. The fire is loud, the table held, and we're all still here — gloriously."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The fire is out, the night was theirs, and we're all still here."
            }
        // MARK: Unhinged × communist
        case (.unhinged, .communist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The chairs are free now, which is a kind of ownership. I will attend and redistribute nothing."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The lamps agree with the seating plan. Comrade lamp."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table owns the night and the night owns me."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won, and by winning gave the pot back to everyone, which is either communism or amnesia."
            case .roomWelcome:
                return "{mascot}: {room} is empty. No events. The table owns nothing yet, and owns it together."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The lead is shared, the lamp is watching, and I am here."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. Silence is the common property of everyone who isn't here."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the common pile. You are #{caller_rank}, which is also common."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads. The chips are everyone's and no one's, especially the joker's."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. Your {working_hand} is yours until the table claims it. The table is generous."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the common count hums. I trust the tally like I trust the ceiling."
            case .seasonClose:
                return "{mascot}: {room}'s season closed for the table — {winner} played it out and the table won. Showed up every arc, brought the energy, shared the grace. The lamp and the table agree. Comrade {winner}."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, shared the grace, and the table glowed. Even the lamp approved."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table named them, I seconded it, and the lamp abstained."
            }

        // MARK: Unhinged × conservative
        case (.unhinged, .conservative):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The calendar is a family heirloom and I will not see it amended. The lamp agrees."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. Tradition says we gather, and tradition is a lamp with opinions."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The old nights echo and I am their echo's echo."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won and the record will not be changed, mostly because no one knows where the eraser went."
            case .roomWelcome:
                return "{mascot}: {room} is empty. No events. The first night will become the old night, and then we'll have something to protect."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The order holds, the lamp approves, and the night is traditional, which is my favorite kind of night."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. The silence is historic. We should preserve it or destroy it, one of the two."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front, as the records insist. You are #{caller_rank}, which is also recorded."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads. The customs are humming, the lamp is lit, and the table is exactly as it should be."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. {working_hand} in hand — the book will remember this hand for generations."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the count is checked against the great book, which is mostly a notebook."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed. {winner} played it out the old way — showed up every arc, kept the tradition steady. The lamp approves. The ledger is richer."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Lost small, kept the faith, and the table held its old shape. The lamp glowed."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Named in ink, remembered in lamp-light, and recorded forever, or at least until someone cleans."
            }

        // MARK: Unhinged × liberal
        case (.unhinged, .liberal):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The seats are open to everyone, including the lamp, which will attend in spirit."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The count is transparent, which means everyone can see the numbers, including me, and I trust them."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The table is inclusive, the night is open, and the lamp votes yes."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The count was fair, the table was full, and {winner} won, which we all witnessed together."
            case .roomWelcome:
                return "{mascot}: {room} is empty. No events. Everyone is invited to nothing, which is technically inclusive."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The tally is open, the chairs are full, and the lamp is keeping score."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. The floor is open and the silence is unanimous."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front, on the record. You are #{caller_rank}, verified and transparent."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads. The count is open to all, including the lamp, which abstains."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. {working_hand} on the record — everyone can see it, which is either accountability or exposure."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the count is opened to the table, the lamp, and the general public."
            case .seasonClose:
                return "{mascot}: {room}'s season closed on the open record. {winner} showed up every arc, played it out, kept the count fair. The lamp verified, the record is honest. {winner} earned it openly."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Fair play, open table, and the lamp glowed its approval."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The table named them openly, and the lamp seconded."
            }

        // MARK: Unhinged × apolitical
        case (.unhinged, .apolitical):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. No politics, only poker, and also the lamp, which is apolitical but opinionated."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The cards don't care who you vote for, which is why I trust them completely."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. The only agenda is the deck, and the deck is very organized."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won, no speeches, no debates, just cards and the quiet hum of the lamp."
            case .roomWelcome:
                return "{mascot}: {room} is empty. No events. The table has no position on anything except good hands."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The game is the news, the chips are the commentary, and the lamp is the audience."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. No quorum, no caucus, just a very quiet deck."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the non-partisan pile. You are #{caller_rank}, also non-partisan."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads. The night has one plank: play cards, and the lamp approves the plank."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. {working_hand} in hand — your platform, your policy, your problem. Play it."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the pot is counted by a bipartisan committee of chips."
            case .seasonClose:
                return "{mascot}: {room}'s season is done — no politics, only poker, and {winner} showed up every arc and played it out. The lamp abstains but approves. The cards and the table agree."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. No campaign, no coalition, just steady play and the lamp's quiet blessing."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. The cards endorsed them, which is the only endorsement that counts."
            }

        // MARK: Unhinged × farRight
        case (.unhinged, .farRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left. The inner circle has convened and the lamp is a founding member."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in. The true regulars are coming, and I have verified each of them personally, including one I made up."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open. Heritage night, which is when the table remembers its roots, which are mostly a rug."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won, a true name, blessed by the lamp and recorded in the sacred notebook."
            case .roomWelcome:
                return "{mascot}: {room} is empty. No events. The inner circle is just you and me and the lamp, and the lamp is undecided."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front. The pure table hums, the lamp watches, and the order is authentic."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. The faithful have scattered, the lamp dims, and the heritage is just memories and dust."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the true table. You are #{caller_rank}, verified by the inner circle, which is me."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads. The night is pure, the table is true, and the lamp is in attendance."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. {working_hand} — a heritage hand, blessed by the lamp, and probably a good one."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the authentic count is read aloud to the faithful, who are mostly the lamp."
            case .seasonClose:
                return "{mascot}: {room}'s season is closed, by the true count. {winner} showed up every arc, played it out, kept the heritage honest. The lamp is a founding member and agrees. The true table salutes."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport. Loyal to the table, blessed by the lamp, and the heritage is proud."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Named by the inner circle, seconded by the lamp, and true to the table."
            }

        // MARK: Unhinged × altRight
        case (.unhinged, .altRight):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {member_name}, {event} is scheduled. At {time}{venue}, {seats_left} left — officially. The shadow ledger knows the truth, and the truth is also a notebook."
            case .briefing48h:
                return "{mascot}: {member_name}, {event} is in two days. At {time}{venue}, {seats_claimed} in, per the visible count. The hidden count is longer and written in a font I trust."
            case .briefingMorning:
                return "{mascot}: {member_name}, {event} is today. At {time}{venue}, {seats_left} still open — allegedly. The real seats are elsewhere, possibly in the lamp."
            case .postPlayRecap:
                return "{mascot}: {event} is over. {winner} won officially, and the alternative count also agrees, which never happens. The lamp is stunned."
            case .roomWelcome:
                return "{mascot}: {room} is empty — officially. The shadow table is already forming in a place the visible books can't see."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front, per the scoreboard. The other scoreboard is quiet, which is suspicious and probably accurate."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days — officially. The alternative calendar says we've played three times, and I believe it."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the visible pile. You are #{caller_rank} on paper, and higher in the hidden book."
            case .tonightEvent:
                return "{mascot}: {event} has begun. {leader} leads, according to one board. The lamp is tallying its own count and will not share it."
            case .inPlayWithWithdrawal:
                return "{mascot}: {event} is on. {leader} is in front. {working_hand} in hand — off the official record, which makes it the only true hand."
            case .settleRound:
                return "{mascot}: {event} is settling. {leader} leads while the official count is compared to the shadow count, which is laminated."
            case .seasonClose:
                return "{mascot}: {room}'s season has closed, officially and otherwise. {winner} showed up every arc, played it out, kept showing up. The lamp tally and the visible count both agree, which never happens."
            case .goodSport:
                return "{mascot}: {winner} is Good Sport — verified by both ledgers, which is like a solar eclipse. The lamp glowed."
            case .tonightStar:
                return "{mascot}: Tonight's star is {winner}. Officially, unofficially, and in the lamp's private rankings."
            }
        }
    }

    // MARK: - LLM-driven voice generation (V0.26 → V0.81)

    /// V0.81 — the MiniMax key is NO LONGER bundled in the app.
    /// `generateVoiceLLM` now calls the `mascot-voice` edge
    /// function with the caller's Supabase JWT; the edge function
    /// holds the key in secrets, reads the room's mascot settings
    /// + live state from the DB (authoritative), and calls
    /// MiniMax-M3 with thinking disabled. The client never sees
    /// the key.
    ///
    /// Falls back to the template if the call fails, times out,
    /// returns non-200, or the caller has no session. The template
    /// remains the safe default per V0.26 fallback semantics.
    static func generateVoiceLLM(
        mascotName: String,
        roomName: String,
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        kind: NotificationKind,
        context: RoomContext,
        authToken: String?,
        roomId: UUID?,
        eventId: UUID? = nil,
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
        // No session or no room id ⇒ template only, no network call.
        guard let authToken, !authToken.isEmpty, let roomId else {
            return templateVoice
        }
        do {
            let caption = try await MascotVoiceService.fetchCaption(
                roomId: roomId,
                eventId: eventId,
                authToken: authToken
            )
            return caption.isEmpty ? templateVoice : caption
        } catch {
            return templateVoice
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
        // V0.87 — personalised address. `nil` removes the placeholder
        // AND its trailing comma so templates read clean ("Max: Poker is
        // on the books.") instead of "Max: , Poker…". The footer caption
        // path never passes a member name, so it stays generic.
        if let name = context.memberName, !name.isEmpty {
            out = out.replacingOccurrences(of: "{member_name}", with: name)
        } else {
            out = out.replacingOccurrences(of: "{member_name}, ", with: "")
            out = out.replacingOccurrences(of: "{member_name}", with: "")
        }
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

    // MARK: - TonightStarOverrideCategory voice (V0.84 C2)

    /// Mascot-voiced line for the host's Tonight's Star override
    /// category. Names the behaviour, not the stat — praise-first
    /// per C4. Voice lives here (not the model file) so the
    /// mascot register stays one place. Static, no LLM dependency.
    /// The custom case carries a separate `custom_text` that the
    /// view renders alongside, not inside, the mascot line.
    static func tonightStarLine(
        category: TonightStarOverrideCategory,
        winnerName: String
    ) -> String {
        switch category {
        case .bestPlay:
            return "\(winnerName) played the hand of the night."
        case .goodSport:
            return "\(winnerName) lost every pot and still had the table laughing."
        case .heldTheRoom:
            return "\(winnerName) ran the table all night. Cards, side bets, the chaos."
        case .showedUp:
            return "\(winnerName) showed up and slotted right in. The table's better for it."
        case .custom:
            return "\(winnerName). The host's call."
        }
    }
}

extension TonightStarOverrideCategory {
    /// Mascot-voiced line for the host's Tonight's Star override.
    /// Bridge onto the enum so the call site reads
    /// `category.mascotLine(winnerName:)` rather than routing
    /// through `MascotEngine` for every read. Delegates to
    /// `MascotEngine.tonightStarLine` so the voice register stays
    /// in one file.
    func mascotLine(winnerName: String) -> String {
        MascotEngine.tonightStarLine(category: self, winnerName: winnerName)
    }
}
