//
//  SeasonHistoryEntry.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One prior (ended) season for a room, paired with the calling
/// member's net total and rank in that season. Drives the
/// US-10 previous-seasons comparison surface — the "improving
/// over time" view that pairs this season's score against each
/// past arc.
///
/// The server side (`get_season_history` — migration 053) filters
/// to `status = 'ended'` seasons, applies a membership guard so
/// non-members get an empty array, and orders most recent first.
/// `callerTotal` is the caller's net across the season (reusing
/// the migration-031 casino_settlement session-delta shape);
/// `callerRank` is `row_number()` over the per-season totals
/// (1 = highest total, ties broken by user_id).
struct SeasonHistoryEntry: Identifiable, Codable, Hashable {
    let seasonId: UUID
    let ordinal: Int
    let subtitle: String
    let startedAt: Date
    let endedAt: Date?
    let callerTotal: Int64
    let callerRank: Int64

    /// `seasonId` is the stable identity — one row per ended
    /// season, never duplicated.
    var id: UUID { seasonId }

    /// Display label for the row header. Empty subtitle falls back
    /// to "Season {n}" so the row never reads blank.
    var displayName: String {
        subtitle.isEmpty ? "Season \(ordinal)" : "Season \(ordinal): \(subtitle)"
    }

    /// How far ahead of (or behind) the current season the caller
    /// was at the end of this prior arc. Positive means the caller
    /// has climbed; negative means they've slipped. Drives the
    /// "▲ +120" / "▼ -40" indicator on the row.
    func delta(against currentScore: Int64) -> Int64 {
        currentScore - callerTotal
    }

    enum CodingKeys: String, CodingKey {
        case seasonId = "season_id"
        case ordinal
        case subtitle
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case callerTotal = "caller_total"
        case callerRank = "caller_rank"
    }

    init(
        seasonId: UUID,
        ordinal: Int,
        subtitle: String,
        startedAt: Date,
        endedAt: Date?,
        callerTotal: Int64,
        callerRank: Int64
    ) {
        self.seasonId = seasonId
        self.ordinal = ordinal
        self.subtitle = subtitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.callerTotal = callerTotal
        self.callerRank = callerRank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasonId = try c.decode(UUID.self, forKey: .seasonId)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 1
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        callerTotal = try c.decodeIfPresent(Int64.self, forKey: .callerTotal) ?? 0
        callerRank = try c.decodeIfPresent(Int64.self, forKey: .callerRank) ?? 0
    }
}
