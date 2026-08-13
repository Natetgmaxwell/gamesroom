//
//  RoomGraphSummary.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  The cross-room overlap signal for one room row, computed by
//  `get_my_rooms` (migration 068). Substrate 1.2's overlap-density
//  signal: how many co-members of this room the caller also sits
//  with in at least one other room, plus up to 5 of their display
//  names. Computed fresh at read time — never stored, never drifts
//  from the membership rows.
//

import Foundation

/// One room's overlap summary. A value object, not a row — the
/// `Identifiable` id is a stable empty `UUID()` because the summary
/// has no identity of its own; it rides along on the `Room` row.
struct RoomGraphSummary: Identifiable, Codable, Hashable {
    /// How many co-members of this room the caller also sits with
    /// in at least one other room.
    let overlapCount: Int

    /// Up to 5 display names of those overlapping co-members.
    let overlapNames: [String]

    var id: UUID { UUID() }

    enum CodingKeys: String, CodingKey {
        case overlapCount = "overlap_count"
        case overlapNames = "overlap_names"
    }

    init(overlapCount: Int, overlapNames: [String]) {
        self.overlapCount = overlapCount
        self.overlapNames = overlapNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        overlapCount = try c.decodeIfPresent(Int.self, forKey: .overlapCount) ?? 0
        overlapNames = try c.decodeIfPresent([String].self, forKey: .overlapNames) ?? []
    }
}
