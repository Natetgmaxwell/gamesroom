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
//
//  Templates are intentionally 1–3 short sentences (≤ 200 characters
//  fully populated). The voice direction comes from the V0.6 mascot spec
//  and is pinned by the V0.38 voice-quality pass; the kind-of-message
//  flavour (claim-prompt, logistics, reminder, recap, room-state caption)
//  is layered on top via the `kind` argument.
//
//  Nil handling: {event}, {winner}, {leader}, {caller_rank}, {event_count},
//  {days_quiet}, {time}, {venue}, {seats_left}, {seats_claimed} are
//  nil-preserving — when the underlying value is `nil`, the literal
//  `{placeholder}` text stays in the substituted output. A trailing
//  sentence-drop pass then splits on `[.!?]` boundaries and removes any
//  sentence that still contains a `{` character, so a template sentence
//  referencing missing data silently disappears instead of rendering
//  broken text. {mascot}, {room}, {member_count} are always substituted.
//  {date} and {host_note} keep `""` substitution (no template references
//  them).
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
    enum NotificationKind: String {
        case briefing48h
        case briefingMorning
        case briefingOnCreate
        case postPlayRecap
        case roomWelcome
        case inPlay
        case roomStale
        case standings
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
            eventCount: Int? = nil
        ) {
            self.activeEventTitle = activeEventTitle
            self.lastEventDaysAgo = lastEventDaysAgo
            self.memberCount = memberCount
            self.memberNames = memberNames
            self.recentWinnerNames = recentWinnerNames
            self.leaderName = leaderName
            self.callerRank = callerRank
            self.eventCount = eventCount
        }
    }

    // MARK: - Footer state resolution (V0.36)

    /// Pure state-machine resolver for the room-page footer. Used
    /// exclusively by `MascotFooterCaption`; the briefing dispatch
    /// paths pick their kind directly. Resolution order (first
    /// match wins):
    ///
    /// 1. `activeEvent?.settledAt != nil`   → `.postPlayRecap`
    /// 2. `activeEvent != nil`, `playedAt <= now` → `.inPlay`
    /// 3. `activeEvent != nil` (upcoming)   → `.briefingOnCreate`
    /// 4. `leaderboard.isEmpty`             → `.roomWelcome`
    /// 5. Last play > 14 days ago           → `.roomStale`
    /// 6. Otherwise                         → `.standings`
    static func footerKind(
        activeEvent: Event?,
        leaderboard: [LeaderboardEntry],
        now: Date = Date()
    ) -> NotificationKind {
        if let event = activeEvent {
            if event.settledAt != nil { return .postPlayRecap }
            if event.playedAt <= now { return .inPlay }
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
            }
        }
    }

    // MARK: - LLM-driven voice generation (V0.26 extension)

    static let defaultLLMEndpoint = "https://api.minimax.io/v1"
    static let defaultLLMModel = "MiniMax-M3"

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
        apiKey: String,
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
        // is configured on the room.
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
    /// {time}, {venue}, {seats_left}, {seats_claimed}. {mascot}, {room},
    /// {member_count} are always substituted. {date} and {host_note} keep
    /// `""` substitution (no template references them). When the
    /// underlying value is nil the literal `{placeholder}` text is kept
    /// in place, and the trailing `dropSentencesWithPlaceholders` pass
    /// removes any sentence that still contains a `{` character — so a
    /// template sentence referencing missing data silently disappears
    /// instead of rendering broken text.
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
