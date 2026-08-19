//
//  HostOpenerSuggestion.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  V0.84 C1 — Host's pre-loaded opening line per member (loop contract).
//  The derivation is mascot-framed but the view applies the mascot
//  prefix; this type returns the body line only. Carnegie Ch 2.3 +
//  4.7 — name first, name + the win to live up to.
//

import Foundation

/// One pre-loaded opening line for one attending member, derived from
/// social preferences + leaderboard state. The host sees one row per
/// claimed RSVP pre-night; the suggestion is a SUGGESTION, not a
/// script — the host delivers it in their own voice at the table.
struct HostOpenerSuggestion: Identifiable, Hashable {
    /// Stable composite `eventId:memberId` exposed to the host-only
    /// list view. Synthesised in `init`; mirrors the EventRSVP id
    /// contract.
    let id: String

    let eventId: UUID
    let memberId: UUID
    let displayName: String

    /// The opener line, WITHOUT the "{mascot} suggests:" prefix.
    /// The view applies the prefix using the room's mascot name (room
    /// state, not model state). Always ≤ ~140 chars and ends in a
    /// period so the view's prefix concatenation reads cleanly.
    let line: String

    /// Which ladder branch produced the line. Surfaced for tests and
    /// so the view can spot-tint each row with the right tag if it
    /// ever wants to (today every row reads as plain text).
    let branch: Branch

    enum Branch: String, Hashable {
        /// (a) Member's own socialPreference.socialText mirrored back.
        case memberStatedPreference
        /// (b) Member's conversationPrompt topic, name-first.
        case conversationPrompt
        /// (c) First night — welcome-by-name, no history.
        case firstNight
        /// (d) Won the last session — Ch 4.7 reputation.
        case lastWinner
        /// (e) Long tenure — name + reliability.
        case longTenure
        /// (f) Plain name-forward greeting fallback.
        case nameForward
    }
}

/// Pure derivation for one member's opener line. Foundation-only so
/// the runner can unit-test it. The priority ladder resolves in
/// declared order; first match wins.
enum HostOpenerDerivation {
    /// Maximum length the view will tolerate. The ladder templates
    /// are designed to stay well under this; the cap is a safety net
    /// so a custom socialText longer than the contract still parses
    /// cleanly (we trim with an ellipsis).
    static let maxLineLength = 140

    /// Build a suggestion for one claimed RSVP. `now` is injected so
    /// the runner can pin "today" for determinism.
    static func suggestion(
        eventId: UUID,
        member: Member,
        rsvp: EventRSVP,
        leaderboardEntry: LeaderboardEntry?,
        now: Date
    ) -> HostOpenerSuggestion {
        let displayName = displayNameFor(member: member, rsvp: rsvp)
        let line = deriveLine(
            member: member,
            displayName: displayName,
            leaderboardEntry: leaderboardEntry,
            now: now
        )
        let branch = deriveBranch(
            member: member,
            leaderboardEntry: leaderboardEntry
        )
        return HostOpenerSuggestion(
            id: "\(eventId.uuidString):\(member.userId.uuidString)",
            eventId: eventId,
            memberId: member.userId,
            displayName: displayName,
            line: line,
            branch: branch
        )
    }

    /// Derive one opener line for each claimed RSVP, in the input
    /// order. Declined and unclaimed RSVPs are excluded — claimed
    /// only.
    static func suggestions(
        eventId: UUID,
        members: [Member],
        rsvps: [EventRSVP],
        leaderboard: [LeaderboardEntry],
        now: Date
    ) -> [HostOpenerSuggestion] {
        let claimedRsvps = rsvps.filter { $0.state == .claimed }
        let membersById = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0) })
        let leaderboardById = Dictionary(uniqueKeysWithValues: leaderboard.map { ($0.userId, $0) })
        return claimedRsvps.map { rsvp in
            let member = membersById[rsvp.memberId] ?? fallbackMember(for: rsvp)
            let entry = leaderboardById[rsvp.memberId]
            return suggestion(
                eventId: eventId,
                member: member,
                rsvp: rsvp,
                leaderboardEntry: entry,
                now: now
            )
        }
    }

    // MARK: - Line + branch derivation

    /// Pure derivation of the opener body line. The six branches
    /// resolve in the order Carnegie Ch 2.3 (name = sweetest sound)
    /// + 4.7 (reputation to live up to) prescribe: stated preference
    /// first (so the mirror reads as deliberate), then conversation
    /// topic, then first-night welcome, then last-winner reputation,
    /// then long-tenure reliability, then plain name fallback.
    static func deriveLine(
        member: Member,
        displayName: String,
        leaderboardEntry: LeaderboardEntry?,
        now: Date
    ) -> String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = name.isEmpty ? "Member" : name
        let social = member.socialPreference

        // (a) Stated social preference — mirror it back, name-first,
        // and quote the member's own words so first-person reads as
        // quotation (not the host speaking for them).
        if isUsable(social.socialText) {
            let text = stripSentenceTerminators(trim(social.socialText, to: 90))
            return "\(safeName) — “\(text).”"
        }
        // (b) Conversation prompt — open on their stated topic,
        // quoted so the topic reads as the member's own framing.
        if isUsable(social.conversationPrompt) {
            let text = stripSentenceTerminators(trim(social.conversationPrompt, to: 90))
            return "\(safeName) — open with “\(text).”"
        }
        // (c) First night — welcome by name, no history.
        if let entry = leaderboardEntry, entry.sessionsPlayed == 0 {
            return "First night — welcome \(safeName) by name."
        }
        // (d) Won the last session — reputation to live up to.
        if let entry = leaderboardEntry, entry.lastSessionDelta > 0 {
            return "\(safeName) — last time you took the table. Tonight's yours to defend."
        }
        // (e) Long tenure — name + reliability.
        if let entry = leaderboardEntry, entry.sessionsPlayed >= 5 {
            return "\(safeName) — five-plus nights in. You set the room's tempo."
        }
        // (f) Plain name-forward greeting.
        return "\(safeName) — good to see you at the table."
    }

    /// Mirror of `deriveLine` that returns only the matched branch.
    /// Used by tests and so the view can spot-tag rows later if
    /// desired. Kept separate so the line derivation stays a single
    /// switch-free cascade matching the spec wording.
    static func deriveBranch(
        member: Member,
        leaderboardEntry: LeaderboardEntry?
    ) -> HostOpenerSuggestion.Branch {
        let social = member.socialPreference
        if isUsable(social.socialText) {
            return .memberStatedPreference
        }
        if isUsable(social.conversationPrompt) {
            return .conversationPrompt
        }
        if let entry = leaderboardEntry, entry.sessionsPlayed == 0 {
            return .firstNight
        }
        if let entry = leaderboardEntry, entry.lastSessionDelta > 0 {
            return .lastWinner
        }
        if let entry = leaderboardEntry, entry.sessionsPlayed >= 5 {
            return .longTenure
        }
        return .nameForward
    }

    // MARK: - Helpers

    /// "Usable" social text is non-empty AND not the canonical
    /// default we seed new members with. Mirroring the seeded default
    /// back would read as "the system says you're shy" — not the
    /// host's first-night move. The seed string lives on
    /// `SocialPreference.defaultSocialText` and is matched verbatim.
    static func isUsable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != SocialPreference.defaultSocialText
    }

    /// Hard-cap a body string to `max` chars, appending an ellipsis
    /// if the original ran longer. Used so the priority-ladder
    /// branches (a)/(b) stay inside the ≤140-char envelope when the
    /// member wrote a long custom string.
    static func trim(_ value: String, to max: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= max { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: max - 1)
        return "\(trimmed[..<cutoff])…"
    }

    /// Strip a trailing `.`, `!`, or `?` from a member-written string
    /// after whitespace trim, so the template-supplied terminal period
    /// doesn't double-punctuate against member punctuation. Used by
    /// branches (a)/(b) before the curly-quote template wraps the
    /// member's words.
    private static func stripSentenceTerminators(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.trimmingCharacters(
            in: CharacterSet(charactersIn: ".!?")
        )
    }

    /// Prefer the member's displayName (cached at the leaderboard
    /// level), fall back to the RSVP displayName (cached at the
    /// seat-grid level), then "Member". Both come from the same
    /// `get_room_members` source — preferring member over rsvp is
    /// defensive belt-and-braces in case one of the two caches is
    /// staler than the other.
    static func displayNameFor(member: Member, rsvp: EventRSVP) -> String {
        let memberName = member.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memberName.isEmpty && memberName != "Member" {
            return memberName
        }
        let rsvpName = rsvp.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rsvpName.isEmpty {
            return rsvpName
        }
        return "Member"
    }

    /// The `get_room_members` cache always carries the member row,
    /// but a stale call (member joined after the leaderboard
    /// refreshed) can drop the user from the cache. Synthesise a
    /// minimal row from the RSVP so every claimed seat still gets
    /// exactly one opener. `id` falls back to `userId.uuidString`
    /// because the synthesised `Member.init` falls back to that
    /// shape when `roomId` is nil.
    static func fallbackMember(for rsvp: EventRSVP) -> Member {
        Member(
            id: rsvp.memberId.uuidString,
            userId: rsvp.memberId,
            role: .member,
            joinedAt: .distantPast,
            displayName: rsvp.displayName
        )
    }
}