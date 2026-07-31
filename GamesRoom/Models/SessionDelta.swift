//
//  SessionDelta.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One point on a `LeaderboardEntry.trajectory` sparkline. The net
/// P&L of a single session for one member.
struct SessionDelta: Codable, Hashable {
    let sessionId: UUID
    let delta: Int64

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case delta
    }

    init(sessionId: UUID, delta: Int64) {
        self.sessionId = sessionId
        self.delta = delta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        delta = try c.decode(Int64.self, forKey: .delta)
    }
}
