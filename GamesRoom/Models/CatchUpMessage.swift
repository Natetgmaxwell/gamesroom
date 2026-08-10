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

import Foundation

/// Pure body builder for the joined-late catch-up push.
struct CatchUpMessage {

    /// Builds the push body for a late joiner.
    ///
    /// - Upcoming event: names the date/time, shows the current
    ///   standings, and nudges the RSVP state (claim if unclaimed).
    /// - Live event: names the state of play and the standings.
    static func body(
        eventName: String,
        playedAt: Date,
        mascotName: String,
        leaderboardSummary: String,
        rsvpState: MemberRSVPState
    ) -> String {
        if playedAt > Date() {
            let when = Self.whenFormatter.string(from: playedAt)
            let claim = rsvpState == .claimed ? "You're in." : "Claim your seat."
            if leaderboardSummary.isEmpty {
                return "\(mascotName): \(eventName) is on — \(when). \(claim)"
            }
            return "\(mascotName): \(eventName) is on — \(when). Standings: \(leaderboardSummary). \(claim)"
        }
        if leaderboardSummary.isEmpty {
            return "\(mascotName): \(eventName) is live. Phone down, chips up."
        }
        return "\(mascotName): \(eventName) is live. Standings: \(leaderboardSummary)."
    }

    private static let whenFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
