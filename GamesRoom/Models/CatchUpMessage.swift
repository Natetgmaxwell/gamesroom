//
//  CatchUpMessage.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  W2.7 — joined-late catch-up push body. The builder is pure so
//  the Foundation test runner can cover the dispatch logic without
//  importing UserNotifications (which the test binary can't
//  compile). The dispatcher calls this; the body branches on
//  whether the event is still upcoming or already live.
//
//  V0.81 — the body is voiced through the 25-voice matrix
//  (personality × ideology), so the catch-up push reads in the
//  room mascot's voice like every other notification. The
//  leaderboard summary (when present) is appended as a plain
//  standings line after the voiced body.
//

import Foundation

/// Pure body builder for the joined-late catch-up push.
struct CatchUpMessage {

    /// Builds the push body for a late joiner.
    ///
    /// - Upcoming event: voiced claim-prompt (`.briefingOnCreate`
    ///   flavour), then the standings line when present.
    /// - Live event: voiced in-play line (`.inPlay` flavour), then
    ///   the standings line when present.
    static func body(
        eventName: String,
        playedAt: Date,
        mascotName: String,
        leaderboardSummary: String,
        rsvpState: MemberRSVPState,
        personality: MascotPersonality = .friendly,
        ideology: MascotPoliticalIdeology = .centrist
    ) -> String {
        let context = MascotEngine.RoomContext(
            activeEventTitle: eventName,
            lastEventDaysAgo: nil,
            memberCount: 0,
            memberNames: []
        )
        if playedAt > Date() {
            let voiced = MascotEngine.generateVoice(
                mascotName: mascotName,
                roomName: "",
                personality: personality,
                ideology: ideology,
                kind: .briefingOnCreate,
                context: context,
                eventDate: playedAt
            )
            if leaderboardSummary.isEmpty {
                return voiced
            }
            return "\(voiced) Standings: \(leaderboardSummary)."
        }
        let voiced = MascotEngine.generateVoice(
            mascotName: mascotName,
            roomName: "",
            personality: personality,
            ideology: ideology,
            kind: .inPlay,
            context: context,
            eventDate: playedAt
        )
        if leaderboardSummary.isEmpty {
            return voiced
        }
        return "\(voiced) Standings: \(leaderboardSummary)."
    }
}
