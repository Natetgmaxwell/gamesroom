//
//  Season.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// A season arc for one room. Each room gets exactly one `active`
/// season at a time; closing the active season opens a new one.
///
/// Per V0.8 brief, the season subtitle (e.g. "Season 3: The Long
/// River") is host-curated for v0.8; v0.9 introduces mascot
/// judgment over arc-grade closes. The status drives the
/// `.seasonClose` `DominantAction` case on the quiet slot.
struct Season: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID

    /// Display ordinal. Drives `Season 3:` formatting on the Quiet
    /// hero subtitle. Monotonic per room.
    let ordinal: Int

    /// ≤140-char subtitle. Host-curated for v0.8.
    let subtitle: String

    /// Current lifecycle state.
    let status: SeasonStatus

    /// When the season opened (first event of the arc).
    let startedAt: Date

    /// When the host pressed `Declare` to close the season. `nil`
    /// while `status == .active`.
    let endedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case ordinal
        case subtitle
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    init(
        id: UUID,
        roomId: UUID,
        ordinal: Int,
        subtitle: String,
        status: SeasonStatus,
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.ordinal = ordinal
        self.subtitle = subtitle
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal) ?? 1
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? ""
        status = try c.decodeIfPresent(SeasonStatus.self, forKey: .status) ?? .active
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
    }
}
