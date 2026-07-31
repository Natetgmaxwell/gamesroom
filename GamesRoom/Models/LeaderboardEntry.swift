//
//  LeaderboardEntry.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One row on the season leaderboard. V0.8 full-board surface — every
/// member rendered, current row highlighted, trailing sparkline
/// behind a tap (no separate API call needed for the sparkline —
/// `trajectory` carries the last N `SessionDelta` points inline).
struct LeaderboardEntry: Identifiable, Codable, Hashable {
    let userId: UUID
    let displayName: String

    /// Free-form role string from the backend. Kept as `String`
    /// (not `RoomRole`) so historical rows with hand-written or
    /// retired role labels still decode.
    let role: String

    /// Member's live points balance (across all rooms' pools).
    /// Display currency in the UI; not the season score.
    let pointsBalance: Int64

    /// Scoped score for the current season. Primary sort key on the
    /// leaderboard.
    let seasonScore: Int64

    /// Number of sessions the member has played this season.
    let sessionsPlayed: Int64

    /// Timestamp of the member's last session. `nil` for members
    /// who have claimed a seat but never played.
    let lastSessionAt: Date?

    /// Net P&L of the last session the member played. Powers the
    /// "▲ +120" indicator on the row.
    let lastSessionDelta: Int64

    /// Trajectory sparkline data — the last N (≤20) season deltas
    /// in chronological order. Carried inline so the row-tap
    /// sparkline renders without a second fetch.
    let trajectory: [SessionDelta]

    /// `userId` is the stable identity on the leaderboard.
    var id: UUID { userId }

    /// Convenience: whether this row is the host. The UI uses this
    /// to render the host's row at the top in `.role`-order
    /// regardless of `seasonScore`.
    var isHost: Bool { role == "host" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case role
        case pointsBalance = "points_balance"
        case seasonScore = "season_score"
        case sessionsPlayed = "sessions_played"
        case lastSessionAt = "last_session_at"
        case lastSessionDelta = "last_session_delta"
        case trajectory
    }

    init(
        userId: UUID,
        displayName: String,
        role: String,
        pointsBalance: Int64,
        seasonScore: Int64,
        sessionsPlayed: Int64,
        lastSessionAt: Date?,
        lastSessionDelta: Int64,
        trajectory: [SessionDelta]
    ) {
        self.userId = userId
        self.displayName = displayName
        self.role = role
        self.pointsBalance = pointsBalance
        self.seasonScore = seasonScore
        self.sessionsPlayed = sessionsPlayed
        self.lastSessionAt = lastSessionAt
        self.lastSessionDelta = lastSessionDelta
        self.trajectory = trajectory
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "member"
        pointsBalance = try c.decodeIfPresent(Int64.self, forKey: .pointsBalance) ?? 0
        seasonScore = try c.decodeIfPresent(Int64.self, forKey: .seasonScore) ?? 0
        sessionsPlayed = try c.decodeIfPresent(Int64.self, forKey: .sessionsPlayed) ?? 0
        lastSessionAt = try c.decodeIfPresent(Date.self, forKey: .lastSessionAt)
        lastSessionDelta = try c.decodeIfPresent(Int64.self, forKey: .lastSessionDelta) ?? 0
        trajectory = try c.decodeIfPresent([SessionDelta].self, forKey: .trajectory) ?? []
    }
}
