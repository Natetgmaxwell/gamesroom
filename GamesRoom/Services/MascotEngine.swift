//
//  MascotEngine.swift
//  GamesRoom
//
//  Track D2 — system-voice layer.
//
//  25-voice template interpolation engine: 5 personalities × 5 ideologies,
//  each producing a templated body for one of four `NotificationKind` cases
//  (on-create / T-48h / morning-of / post-play recap).
//
//  V0.8 spec §"Pre-play Briefing covers the full pre-event window": the
//  mascot engine is **pure template interpolation** in v0.8. No live LLM
//  call. No Foundation Models. No hosted completion. The 25-voice matrix
//  is a hardcoded lookup; the caller substitutes placeholders. LLM-driven
//  generation is deferred to v0.9 per the brief's open-question #7.
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
//
//  Templates are intentionally 1–2 sentences. The voice direction comes
//  from the V0.6 mascot spec; the kind-of-message flavour (claim-prompt,
//  logistics, reminder, recap) is layered on top via the `kind` argument.
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
    /// - `briefingOnCreate`: Sent at event.createdAt. "Open and claim
    ///   your seat" prompt. Goes to **every** member regardless of RSVP
    ///   state (claimed/declined/unclaimed) — it's the only moment in
    ///   the pre-event window where a declined member still gets a push.
    /// - `briefing48h`: T-48h. Logistics for claimed members, "reminder —"
    ///   prefix for unclaimed. Skipped for declined.
    /// - `briefingMorning`: Morning of event (9:00 AM local on the day
    ///   of `playedAt`). Same claimed/unclaimed branching as T-48h.
    /// - `postPlayRecap`: Post-event ceremonial-card narration. Not
    ///   scheduled by `NotificationDispatcher.scheduleBriefingTrio` —
    ///   consumed by `SeasonDiaryEntry` when the host finalizes.
    enum NotificationKind: String {
        case briefing48h
        case briefingMorning
        case briefingOnCreate
        case postPlayRecap
    }

    /// Snapshot of room state used to flavour the voice. Pure data,
    /// no service dependencies. The dispatcher builds a minimal
    /// instance from the available payload.
    struct RoomContext {
        let activeEventTitle: String?
        let lastEventDaysAgo: Int?
        let memberCount: Int
        let memberNames: [String]
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

    // MARK: - Template matrix (5 × 5 × 4 = 100 cells)

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
    ///
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
                return "{mascot}: {event} has concluded under the host's supervision. {room} proceeds."
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
                return "{mascot}: {event} wrapped. {room} stands at {member_count} member(s)."
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
                return "{mascot}: {event} is settled. The standings will be revised in the next pass."
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
                return "{mascot}: {event} has concluded. The ledger updates itself; no authority is required."
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
                return "{mascot}: {event} is finished. {room} has not been spared."
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
                return "{mascot}: That was a beautiful {event}. Thank you all — see you at the next one."
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
                return "{mascot}: {event} is in the books. Nice work, everyone — {room} keeps getting better."
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
            case .postPlayRecap:
                return "{mascot}: {event} is done! I love everyone equally — except I shuffled the standings twice while nobody was looking."
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
            case .postPlayRecap:
                return "{mascot}: {event} wrapped! Nobody was in charge and that's exactly why it worked."
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
                return "{mascot}: {event} is over. We survived. Barely. Same time next collapse?"
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
                return "{mascot}: {event} is over. The host did their job. Do yours next time."
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
                return "{mascot}: {event} is done. {seats_claimed} of you showed up — about what the room expected."
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
                return "{mascot}: {event} is over. Don't trust the standings — I may have re-sorted them."
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
                return "{mascot}: {event} is done. The host called it a 'success.' I call it a group decision we all agreed to call a success."
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
                return "{mascot}: {event} is done. We are, somehow, still here. Don't get used to it."
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
                return "{mascot}: {event} is done. The host called it 'according to plan.' Sure."
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
                return "{mascot}: {event} wrapped. We survived. The room is exactly as predictable as it was yesterday."
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
                return "{mascot}: {event} is settled. The standings may have shifted since you last looked. Just a hunch."
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
                return "{mascot}: {event} is over. The host called it 'a successful event.' I call it 'people showed up.'"
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
                return "{mascot}: {event} is done. We are not. Somehow. Don't expect this to last."
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
                return "{mascot}: {event} IS DONE. The host is satisfied. I am satisfied. The room is satisfied. We are all in perfect agreement. WE ARE ALL GOING TO BE FINE."
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
                return "{mascot}: {event} is in the past! The room is the same! Different! {member_count} member(s) — the number keeps MEANING THINGS!"
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
                return "{mascot}: {event} IS OVER! The standings have been redrawn! In invisible ink! With glitter! YOU CAN'T PROVE ANYTHING!"
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
                return "{mascot}: {event} IS DONE! NOBODY RAN IT! WE ALL RAN IT! THE HOST IS A FIGMENT!"
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
                return "{mascot}: {event} IS OVER! WE'RE STILL HERE! WRONG! WRONG WRONG WRONG! GLORIOUSLY WRONG!"
            }
        }
    }

    // MARK: - Placeholder substitution

    /// Substitutes `{name}` placeholders with caller-supplied values.
    /// Nil values for the optional fields are simply not substituted —
    /// the template is responsible for omitting the placeholder when
    /// the data is unavailable (most templates reference only the
    /// guaranteed `mascotName` / `roomName` / `event` / `date` / `time`).
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
            of: "{event}",
            with: context.activeEventTitle ?? ""
        )

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

        // Tidy runs of whitespace from the dropped optional placeholders.
        return Self.collapseWhitespace(out)
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
