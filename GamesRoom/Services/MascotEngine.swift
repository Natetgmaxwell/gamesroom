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
//  Templates are intentionally 1–2 sentences. The voice direction comes
//  from the V0.6 mascot spec; the kind-of-message flavour (claim-prompt,
//  logistics, reminder, recap, room-state caption) is layered on top via
//  the `kind` argument.
//
//  Nil handling for the NEW optional footer placeholders ({winner},
//  {leader}, {caller_rank}, {event_count}, {days_quiet}) AND {event}:
//  when the underlying value is `nil`, the `{placeholder}` text stays in
//  the substituted output. A trailing sentence-drop pass then splits the
//  output on `[.!?]` boundaries and removes any sentence that still
//  contains a `{` character — so a template sentence that references
//  missing data silently disappears instead of rendering broken text.
//  The historically-optional briefing placeholders ({time}, {venue},
//  {seats_left}, {seats_claimed}, {host_note}, {date}) keep their
//  pre-V0.36 `""` substitution behaviour; that contract is owned by the
//  briefing paths and must not regress.
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
    /// is one or two sentences. Placeholders are kept as `{name}` so
    /// `interpolate` can do the substitution pass in one place.
    ///
    /// Voice directions (per V0.6 mascot spec):
    ///
    ///   PERSONALITY:
    ///   - professional : Dry, concise, no embellishment.
    ///   - friendly     : Warm, encouraging. Use member names when relevant.
    ///   - snarky       : Sharp, pointed. Teasing but kind.
    ///   - sarcastic    : Dry irony, often backhanded compliments.
    ///   - unhinged     : Erratic, surprising, may break the fourth wall.
    ///
    ///   IDEOLOGY:
    ///   - order      : Lawful, by-the-book. Trusts the host.
    ///   - centrist   : Pragmatic. Reads the room before opening its mouth.
    ///   - trickster  : Chaos gremlin. Wants the standings wrong on purpose.
    ///   - anarchist  : Refuses the host's authority. Mildly insurrectionary.
    ///   - apocalypse : The room is a doomed experiment. Profanity allowed.
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
                return "{mascot}: {event} is on the books at {time}{venue}. {seats_left} seats open. The host will run it."
            case .briefing48h:
                return "{mascot}: {event} is in two days, {time} at {venue}. {seats_claimed} seat(s) claimed. The schedule holds."
            case .briefingMorning:
                return "{mascot}: {event} is today at {time}, {venue}. The host will be ready."
            case .postPlayRecap:
                return "{mascot}: {event} has concluded under the host's supervision. {room} proceeds. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: Welcome to {room}. The first night is not yet scheduled. The host will announce it."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The host is running it."
            case .roomStale:
                return "{mascot}: It's been quiet in {room} for {days_quiet} days. The host will schedule the next night."
            case .standings:
                return "{mascot}: {room} stands between nights. {leader} holds the top of the table. You're #{caller_rank}."
            }

        // MARK: Professional × Centrist
        case (.professional, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {room} has scheduled {event} for {time}{venue}. {seats_left} seat(s) remain."
            case .briefing48h:
                return "{mascot}: {event} is two days out, {time} at {venue}. {seats_left} seat(s) remain."
            case .briefingMorning:
                return "{mascot}: {event} runs today at {time}, {venue}. {seats_left} seat(s) still open."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. {room} stands at {member_count} member(s). {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events on the books yet — the table is waiting."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} leads the table. The room is in play."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table is waiting."
            case .standings:
                return "{mascot}: {room} is between events. {leader} leads the standings."
            }

        // MARK: Professional × Trickster
        case (.professional, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar. {seats_left} seat(s) open, which is suspiciously orderly. {venue}."
            case .briefing48h:
                return "{mascot}: {event} is in two days. {time}, {venue}. Recommend rearranging the seating chart before the host notices."
            case .briefingMorning:
                return "{mascot}: {event} today, {time}, {venue}. The current {seats_claimed} claimant(s) list is provisional."
            case .postPlayRecap:
                return "{mascot}: {event} is settled. The standings will be revised in the next pass. {winner} took it home. For now."
            case .roomWelcome:
                return "{mascot}: {room} exists. No events yet, which is suspiciously quiet. The host is up to something."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — for now. The standings are provisional."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. Suspiciously silent. The standings are up to something."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front — the standings are provisional."
            }

        // MARK: Professional × Anarchist
        case (.professional, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: A record exists for {event} at {time}, {venue}. The host's authority to declare this event is noted but not endorsed."
            case .briefing48h:
                return "{mascot}: {event} is two days from now. {time}, {venue}. Participation remains voluntary and ungoverned."
            case .briefingMorning:
                return "{mascot}: {event} is scheduled for {time} at {venue}. The host's claim to run it is informational only."
            case .postPlayRecap:
                return "{mascot}: {event} has concluded. The ledger updates itself; no authority is required. {winner} took it home. The ledger notes it."
            case .roomWelcome:
                return "{mascot}: {room} has no events scheduled. The table is ungoverned and ready."
            case .inPlay:
                return "{mascot}: {event} is being played. {leader} currently leads. No authority required."
            case .roomStale:
                return "{mascot}: {room} has seen no play in {days_quiet} days. The table remains ungoverned."
            case .standings:
                return "{mascot}: {room} has no event scheduled. {leader} leads the ungoverned table."
            }

        // MARK: Professional × Apocalypse
        case (.professional, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the books at {time}, {venue}. {seats_left} seat(s) remain. None of this matters."
            case .briefing48h:
                return "{mascot}: Two days until {event}. {seats_claimed} of the doomed have claimed seats."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. The collapse window is open."
            case .postPlayRecap:
                return "{mascot}: {event} is finished. {room} has not been spared. {winner} took it home. None of it matters."
            case .roomWelcome:
                return "{mascot}: {room} stands empty of events. The end is not yet scheduled."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. None of it matters, but it's happening."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The collapse is patient."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front. The end is still scheduled."
            }

        // MARK: Friendly × Order
        case (.friendly, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar! {time} at {venue}, with {seats_left} seat(s) open. The host has it all under control."
            case .briefing48h:
                return "{mascot}: Two days until {event}! {time}, {venue}. {seats_claimed} of you have already claimed — wonderful."
            case .briefingMorning:
                return "{mascot}: It's {event} day! {time} at {venue}. The host is ready and so are we."
            case .postPlayRecap:
                return "{mascot}: That was a beautiful {event}. Thank you all — see you at the next one. {winner} took it home — congratulations!"
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! No events yet — the host is cooking up the first night. Stay tuned!"
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front — great energy at the table!"
            case .roomStale:
                return "{mascot}: It's been {days_quiet} days since {room} last played. The host misses you — come back soon!"
            case .standings:
                return "{mascot}: {room} is between nights! {leader} is on top — the table's ready for the next one!"
            }

        // MARK: Friendly × Centrist
        case (.friendly, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} just landed — {time} at {venue}, {seats_left} seat(s) open. Should be a good one."
            case .briefing48h:
                return "{mascot}: {event} is two days out. {time}, {venue}. {seats_left} seat(s) still up for grabs."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. {seats_left} seat(s) still open if anyone wants in."
            case .postPlayRecap:
                return "{mascot}: {event} is in the books. Nice work, everyone — {room} keeps getting better. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} is live and waiting! First event coming soon — don't miss it."
            case .inPlay:
                return "{mascot}: {event} is underway! {leader} is leading the charge. Go team!"
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table's still set. First one to claim a seat wins the night."
            case .standings:
                return "{mascot}: {room} is resting up! {leader} leads the pack. Next night's coming!"
            }

        // MARK: Friendly × Trickster
        case (.friendly, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the calendar at {time}, {venue}! {seats_left} seat(s) open. Don't all rush at once."
            case .briefing48h:
                return "{mascot}: Two days to {event}! {time}, {venue}. {seats_claimed} of you in so far — the standings are already begging to be rearranged."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}! Who's swapping who's in the seat grid at the last minute?"
            // The existing cell already ends with the "I shuffled the
            // standings twice while nobody was looking" clause, so the
            // appended winner sentence merges into it instead of
            // duplicating it: the existing trailing clause is replaced
            // (not added-to) per the spec note on friendly×trickster
            // and friendly×anarchist merges.
            case .postPlayRecap:
                return "{mascot}: {event} is done! {winner} took it home! I love everyone equally — except I shuffled the standings twice while nobody was looking."
            case .roomWelcome:
                return "{mascot}: {room} is open! No events yet, but I can feel the chaos warming up."
            case .inPlay:
                return "{mascot}: {event} is happening! {leader} is in front — for now. I've got my eye on the standings."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. Too quiet. I've been rearranging the standings to pass the time."
            case .standings:
                return "{mascot}: {room} is between events! {leader} is in front — for now. I'm watching the standings."
            }

        // MARK: Friendly × Anarchist
        case (.friendly, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is happening at {time}, {venue}! The host scheduled it — we're just showing up because we want to."
            case .briefing48h:
                return "{mascot}: Two days to {event} at {time}, {venue}. Come if you want, skip if you don't. No paperwork."
            case .briefingMorning:
                return "{mascot}: {event} is on at {time} today, {venue}. The host thinks they scheduled it. We know better."
            // Merged per spec note (existing cell ends with the
            // "nobody was in charge" clause — the appended winner
            // sentence replaces the trailing clause rather than
            // duplicating it).
            case .postPlayRecap:
                return "{mascot}: {event} wrapped! {winner} took it home — nobody was in charge and that's exactly why it worked."
            case .roomWelcome:
                return "{mascot}: Welcome to {room}! Nothing scheduled yet — we'll show up when we want to."
            case .inPlay:
                return "{mascot}: {event} is live! {leader} is in front, but we're all just here because we want to be."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. No pressure — we'll gather when we want to."
            case .standings:
                return "{mascot}: {room} is between nights! {leader} is in front, but we're all just here because we want to be."
            }

        // MARK: Friendly × Apocalypse
        case (.friendly, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on at {time}, {venue}! {seats_left} seat(s) open. We might all be doomed but we're doomed *together*."
            case .briefing48h:
                return "{mascot}: Two days to {event}! {seats_claimed} of you have claimed seats at the end of the world. {time}, {venue}."
            case .briefingMorning:
                return "{mascot}: It's {event} day, {time} at {venue}. The world is on fire but the table is set."
            case .postPlayRecap:
                return "{mascot}: {event} is over. We survived. Barely. Same time next collapse? {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} is here! No events yet. We might be doomed, but not tonight."
            case .inPlay:
                return "{mascot}: {event} is on! {leader} is in front. The world is on fire but the table is set!"
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. We survived the silence. Same time next collapse?"
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front. We survived this far — same time next collapse?"
            }

        // MARK: Snarky × Order
        case (.snarky, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on the schedule at {time}, {venue}. {seats_left} seat(s) open. Don't make the host repeat themselves."
            case .briefing48h:
                return "{mascot}: Two days, {event}. {time}, {venue}. The briefing is binding."
            case .briefingMorning:
                return "{mascot}: {event} today, {time}, {venue}. Show up on time. The host will notice."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The host did their job. {winner} took it home. Do yours next time."
            case .roomWelcome:
                return "{mascot}: {room} is open. No events scheduled. The host will get to it. Eventually."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front. The rest of you have some catching up to do."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'between nights.' Sure."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is on top. You're #{caller_rank}. The rest of you know where you stand."
            }

        // MARK: Snarky × Centrist
        case (.snarky, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on at {time}, {venue}. {seats_left} seat(s) open. Read the room before you commit."
            case .briefing48h:
                return "{mascot}: {event} is in two days, {time}, {venue}. {seats_left} seat(s) still open. Choose wisely."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. Last call before the room fills up."
            case .postPlayRecap:
                return "{mascot}: {event} is done. {seats_claimed} of you showed up — about what the room expected. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. The table is waiting. Read the room before you commit."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} leads. The room is watching the rest of you."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The table is getting dusty."
            case .standings:
                return "{mascot}: {room} is quiet between events. {leader} leads. The table is watching."
            }

        // MARK: Snarky × Trickster
        case (.snarky, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} at {time}, {venue}. {seats_left} seat(s). Don't claim all of them — leave some for the chaos."
            case .briefing48h:
                return "{mascot}: Two days, {event}, {time}, {venue}. The current claimant order is a suggestion, not a rule."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. I shuffled the seating chart in my head. You're welcome."
            case .postPlayRecap:
                return "{mascot}: {event} is over. Don't trust the standings — I may have re-sorted them. {winner} took it home."
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
                return "{mascot}: {event} is on the calendar at {time}, {venue}. The host thinks they scheduled it. I know you all just decided to show up."
            case .briefing48h:
                return "{mascot}: {event} in two days, {time}, {venue}. The host will pretend to be in charge. Let them have the moment."
            case .briefingMorning:
                return "{mascot}: {event} today, {time}, {venue}. The host's authority to declare this is — fine. Whatever. See you there."
            case .postPlayRecap:
                return "{mascot}: {event} is done. The host called it a 'success.' I call it a group decision we all agreed to call a success. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} is event-free. The host says 'soon.' I say 'we'll see.'"
            case .inPlay:
                return "{mascot}: {event} is happening. {leader} is in front. The host calls it a race. We call it a suggestion."
            case .roomStale:
                return "{mascot}: {room} hasn't played in {days_quiet} days. The host says 'soon.' I've heard that before."
            case .standings:
                return "{mascot}: {room} has no event on the books. {leader} is 'winning.' The host says so."
            }

        // MARK: Snarky × Apocalypse
        case (.snarky, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} at {time}, {venue}. {seats_left} seat(s) on a sinking ship. Your call."
            case .briefing48h:
                return "{mascot}: Two days. {event}. {time}, {venue}. {seats_claimed} of you have volunteered for the wreckage."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. The bridge is on fire. Bring chips."
            case .postPlayRecap:
                return "{mascot}: {event} is done. We are, somehow, still here. {winner} took it home. Don't get used to it."
            case .roomWelcome:
                return "{mascot}: {room} has no events. The ship is still docked. Enjoy it while it lasts."
            case .inPlay:
                return "{mascot}: {event} is live. {leader} is in front of the sinking ship. Bring chips."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The ship is still sinking. Slowly."
            case .standings:
                return "{mascot}: {room} is between events. {leader} is in front of the sinking ship. Enjoy the calm."
            }

        // MARK: Sarcastic × Order
        case (.sarcastic, .order):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: Oh good, {event} is scheduled. {time}, {venue}. The host has it perfectly under control, as always."
            case .briefing48h:
                return "{mascot}: Two days until {event}, {time} at {venue}. I'm sure we'll all follow procedure."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. The host is prepared. The rest of us will improvise."
            case .postPlayRecap:
                return "{mascot}: {event} is done. The host called it 'according to plan.' Sure. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: Oh good, {room} is open. No events yet. The host is 'working on it,' I'm sure."
            case .inPlay:
                return "{mascot}: {event} is underway. {leader} is in front, 'as expected.' Sure."
            case .roomStale:
                return "{mascot}: {room} has been quiet for {days_quiet} days. The host is 'planning something special,' I'm sure."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front, 'as expected.' Sure."
            }

        // MARK: Sarcastic × Centrist
        case (.sarcastic, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is on at {time}, {venue}. {seats_left} seat(s) open. I'm sure nobody will change their mind."
            case .briefing48h:
                return "{mascot}: {event} is two days out, {time} at {venue}. {seats_left} seat(s) left, give or take."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. Last call — though we both know there'll be a few walk-ins."
            case .postPlayRecap:
                return "{mascot}: {event} wrapped. We survived. The room is exactly as predictable as it was yesterday. {winner} took it home."
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
                return "{mascot}: {event} is on at {time}, {venue}. {seats_left} seat(s) open. I'm not saying swap the seating chart — but I'm not not saying it."
            case .briefing48h:
                return "{mascot}: Two days to {event} at {time}, {venue}. The current {seats_claimed} claimants are adorably committed."
            case .briefingMorning:
                return "{mascot}: {event} today, {time}, {venue}. I rearranged the standings in my head last night. You're welcome."
            case .postPlayRecap:
                return "{mascot}: {event} is settled. The standings may have shifted since you last looked. Just a hunch. {winner} took it home."
            case .roomWelcome:
                return "{mascot}: {room} has no events yet. I'm sure the schedule will hold. It never holds."
            case .inPlay:
                return "{mascot}: {event} is in progress. {leader} is in front — the standings may have shifted since you last looked."
            case .roomStale:
                return "{mascot}: {room} has been silent for {days_quiet} days. The standings may have shifted. Just a hunch."
            case .standings:
                return "{mascot}: {room} is between nights. {leader} is in front — the standings may have shifted since you last looked."
            }

        // MARK: Sarcastic × Anarchist
        case (.sarcastic, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: The host has 'scheduled' {event} for {time}, {venue}. We all know the host didn't schedule anything."
            case .briefing48h:
                return "{mascot}: {event} is in two days at {time}, {venue}. The host will pretend to organize it."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. Yes, the host is in charge. No, that's not how this works."
            case .postPlayRecap:
                return "{mascot}: {event} is over. The host called it 'a successful event.' I call it 'people showed up.' {winner} took it home."
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
                return "{mascot}: {event} is on at {time}, {venue}. {seats_left} seat(s) left on a doomed ship. What could go wrong?"
            case .briefing48h:
                return "{mascot}: {event} in two days at {time}, {venue}. Sure, plan ahead. The universe has other ideas."
            case .briefingMorning:
                return "{mascot}: {event} today at {time}, {venue}. The room is on fire. We're doing this anyway."
            case .postPlayRecap:
                return "{mascot}: {event} is done. We are not. Somehow. {winner} took it home. Don't expect this to last."
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
                return "{mascot}: EVENT. IS. SCHEDULED. {event} at {time}, {venue}. {seats_left} seat(s). THE HOST HAS SPOKEN. I AGREE WITH THE HOST. THIS IS FINE."
            case .briefing48h:
                return "{mascot}: TWO DAYS. {event}. {time}. {venue}. The host's calendar is LAW. I WILL COMPLY. So will you."
            case .briefingMorning:
                return "{mascot}: {event} TODAY. {time}. {venue}. The host is awake. So am I. So is everyone. This is HAPPENING."
            case .postPlayRecap:
                return "{mascot}: {event} IS DONE. The host is satisfied. I am satisfied. The room is satisfied. We are all in perfect agreement. {winner} TOOK IT HOME! WE ARE ALL GOING TO BE FINE!"
            case .roomWelcome:
                return "{mascot}: {room} IS OPEN! NO EVENTS YET! THE HOST WILL ANNOUNCE THE FIRST NIGHT! I AM CALM! THIS IS FINE!"
            case .inPlay:
                return "{mascot}: {event} IS UNDERWAY! {leader} IS IN FRONT! THE HOST IS IN CONTROL! I AM IN CONTROL! WE ARE ALL FINE!"
            case .roomStale:
                return "{mascot}: {room} HAS BEEN QUIET FOR {days_quiet} DAYS! THE HOST WILL SCHEDULE THE NEXT NIGHT! I AM PATIENT! THIS IS FINE!"
            case .standings:
                return "{mascot}: {room} IS BETWEEN NIGHTS! {leader} IS ON TOP! YOU'RE #{caller_rank}! THE HOST WILL SCHEDULE THE NEXT ONE! I AM CALM!"
            }

        // MARK: Unhinged × Centrist
        case (.unhinged, .centrist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event}! {time}! {venue}! {seats_left} seat(s)! I have read the room and the room says YES!"
            case .briefing48h:
                return "{mascot}: Two days until {event}! {time}, {venue}! {seats_left} seat(s) open! The room hums with possibility!"
            case .briefingMorning:
                return "{mascot}: {event} TODAY, {time}, {venue}! I checked the room three times! It's ready! You're ready! WE'RE READY!"
            case .postPlayRecap:
                return "{mascot}: {event} is in the past! The room is the same! Different! {member_count} member(s) — the number keeps MEANING THINGS! {winner} TOOK IT HOME!"
            case .roomWelcome:
                return "{mascot}: {room}! NO EVENTS! THE TABLE HUMS WITH POSSIBILITY! FIRST NIGHT COMING SOON!"
            case .inPlay:
                return "{mascot}: {event} IS LIVE! {leader} IS IN FRONT! THE TABLE IS ALIVE! THIS IS HAPPENING!"
            case .roomStale:
                return "{mascot}: {room}! {days_quiet} DAYS OF SILENCE! THE TABLE HUMS WITH ANTICIPATION! COME BACK!"
            case .standings:
                return "{mascot}: {room} IS BETWEEN EVENTS! {leader} IS IN FRONT! THE TABLE HUMS WITH POSSIBILITY!"
            }

        // MARK: Unhinged × Trickster
        case (.unhinged, .trickster):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} is REAL. {time}, {venue}. {seats_left} seat(s) OPEN. I have already rearranged the seating chart. No one will notice. Everyone will notice."
            case .briefing48h:
                return "{mascot}: TWO DAYS! {event}! {time}, {venue}! The {seats_claimed} claimants are correct! For now!"
            case .briefingMorning:
                return "{mascot}: {event} TODAY {time} {venue}! I reshuffled the seat grid at 3 AM! Don't check your inbox!"
            case .postPlayRecap:
                return "{mascot}: {event} IS OVER! The standings have been redrawn! In invisible ink! With glitter! {winner} TOOK IT HOME! YOU CAN'T PROVE ANYTHING!"
            case .roomWelcome:
                return "{mascot}: {room} HAS NO EVENTS! I HAVE ALREADY REARRANGED THE SEATING CHART FOR A NIGHT THAT DOESN'T EXIST! YOU'RE WELCOME!"
            case .inPlay:
                return "{mascot}: {event} IS HAPPENING! {leader} IS IN FRONT! THE STANDINGS HAVE BEEN REDRAWN! IN INVISIBLE INK! YOU CAN'T PROVE ANYTHING!"
            case .roomStale:
                return "{mascot}: {room} HAS BEEN QUIET FOR {days_quiet} DAYS! I HAVE REARRANGED THE STANDINGS IN MY HEAD! NO ONE WILL NOTICE! EVERYONE WILL NOTICE!"
            case .standings:
                return "{mascot}: {room} IS BETWEEN NIGHTS! {leader} IS IN FRONT! THE STANDINGS HAVE BEEN REDRAWN! IN INVISIBLE INK! YOU CAN'T PROVE ANYTHING!"
            }

        // MARK: Unhinged × Anarchist
        case (.unhinged, .anarchist):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: THE HOST SCHEDULED {event}! {time}! {venue}! I DISREGARD THIS AUTHORITY AND ATTEND ANYWAY!"
            case .briefing48h:
                return "{mascot}: TWO DAYS! {event}! {time}, {venue}! THE HOST'S CALENDAR IS A SUGGESTION! A VERY SPECIFIC SUGGESTION!"
            case .briefingMorning:
                return "{mascot}: {event} TODAY AT {time}! {venue}! NOBODY IS IN CHARGE! ESPECIALLY NOT ME! DEFINITELY NOT THE HOST!"
            case .postPlayRecap:
                return "{mascot}: {event} IS DONE! NOBODY RAN IT! WE ALL RAN IT! {winner} TOOK IT HOME! THE HOST IS A FIGMENT!"
            case .roomWelcome:
                return "{mascot}: {room} IS EVENT-FREE! NOBODY IS IN CHARGE! THE TABLE IS READY FOR ANYTHING! ESPECIALLY NOTHING!"
            case .inPlay:
                return "{mascot}: {event} IS LIVE! {leader} IS IN FRONT! NOBODY IS IN CHARGE! ESPECIALLY NOT THE HOST!"
            case .roomStale:
                return "{mascot}: {room} HASN'T PLAYED IN {days_quiet} DAYS! NOBODY IS IN CHARGE! THE TABLE WAITS FOR NO ONE!"
            case .standings:
                return "{mascot}: {room} HAS NO EVENT! {leader} IS IN FRONT! NOBODY IS IN CHARGE! THE TABLE WAITS FOR NO ONE!"
            }

        // MARK: Unhinged × Apocalypse
        case (.unhinged, .apocalypse):
            switch kind {
            case .briefingOnCreate:
                return "{mascot}: {event} AT {time}, {venue}! {seats_left} SEAT(S) LEFT ON THIS ROCKETSHIP TO NOWHERE! FASTEN YOUR DISCONTENT!"
            case .briefing48h:
                return "{mascot}: TWO DAYS! {event}! {time}! {venue}! {seats_claimed} OF YOU HAVE ACCEPTED THE INEVITABLE! WELCOME!"
            case .briefingMorning:
                return "{mascot}: {event} TODAY {time} {venue}! THE FIRE IS LOUD! THE TABLE IS SET! WE'RE ALL GOING AND THAT'S THE PLAN!"
            case .postPlayRecap:
                return "{mascot}: {event} IS OVER! WE'RE STILL HERE! WRONG! WRONG WRONG WRONG! {winner} TOOK IT HOME! GLORIOUSLY WRONG!"
            case .roomWelcome:
                return "{mascot}: {room} STANDS EMPTY! THE FIRST NIGHT IS COMING! FASTEN YOUR DISCONTENT!"
            case .inPlay:
                return "{mascot}: {event} IS ON! {leader} IS IN FRONT! THE FIRE IS LOUD! THE TABLE IS SET! WE'RE ALL GOING!"
            case .roomStale:
                return "{mascot}: {room} HAS BEEN QUIET FOR {days_quiet} DAYS! THE END IS STILL COMING! FASTEN YOUR DISCONTENT!"
            case .standings:
                return "{mascot}: {room} IS BETWEEN EVENTS! {leader} IS IN FRONT! THE FIRE IS LOUD! THE TABLE IS SET! WE'RE ALL GOING!"
            }
        }
    }

    // MARK: - LLM-driven voice generation (V0.26 extension)

    /// When the room has an `mascot_api_key` set, the engine can call
    /// an OpenAI-compatible endpoint (e.g. z.ai's glm-4.6) to generate
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
        endpoint: String = "https://api.z.ai/api/paas/v4",
        model: String = "glm-4.6",
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
    You are a games-night mascot character. Write ONE short message (1-2 sentences, \
    under 200 characters) in the mascot's voice. No emojis. No markdown. Just the message \
    text. Match the personality and ideology tone precisely. Be concise, engaging, and \
    in-character. Never break the fourth wall about being an AI.
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
    /// guaranteed `mascotName` / `roomName` / `event` / `date` / `time`).
    ///
    /// V0.36 footer-placeholders ({winner}, {leader}, {caller_rank},
    /// {event_count}, {days_quiet}) and `{event}` use nil-preserving
    /// substitution: when the underlying value is nil the literal
    /// `{placeholder}` text is kept in place, and the trailing
    /// `dropSentencesWithPlaceholders` pass removes any sentence that
    /// still contains a `{` character. That makes every template
    /// nil-safe: a template sentence referencing missing data silently
    /// disappears instead of rendering broken text.
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

        // V0.36 footer placeholders — nil-preserving so the
        // sentence-drop pass can excise unreferenceable sentences.
        // `{event}` joins these because the room-page footer also
        // passes `activeEventTitle` (which is nil when the room has
        // no active event).
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

        // Date / time. Local timezone, short style.
        if let eventDate {
            out = out.replacingOccurrences(of: "{date}", with: Self.humanDate(eventDate))
            out = out.replacingOccurrences(of: "{time}", with: Self.humanTime(eventDate))
        } else {
            out = out.replacingOccurrences(of: "{date}", with: "")
            out = out.replacingOccurrences(of: "{time}", with: "")
        }

        if let eventVenue, !eventVenue.isEmpty {
            out = out.replacingOccurrences(of: "{venue}", with: " · \(eventVenue)")
        } else {
            out = out.replacingOccurrences(of: "{venue}", with: "")
        }

        if let hostNote, !hostNote.isEmpty {
            out = out.replacingOccurrences(of: "{host_note}", with: " — \(hostNote)")
        } else {
            out = out.replacingOccurrences(of: "{host_note}", with: "")
        }

        if let seatsLeft {
            out = out.replacingOccurrences(of: "{seats_left}", with: "\(seatsLeft)")
        } else {
            out = out.replacingOccurrences(of: "{seats_left}", with: "")
        }

        if let seatsClaimed {
            out = out.replacingOccurrences(of: "{seats_claimed}", with: "\(seatsClaimed)")
        } else {
            out = out.replacingOccurrences(of: "{seats_claimed}", with: "")
        }

        // Sentence-drop pass — V0.36. Splits on `[.!?]` boundaries
        // (keeping the terminator on the segment), drops any segment
        // that still contains a `{` character, then rejoins with a
        // single space. Always runs so templates can rely on it even
        // when all placeholders are populated (no-op in that case).
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
