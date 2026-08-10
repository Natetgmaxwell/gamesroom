//
//  EventRound.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  One host-submitted round for an event. Mirrors
//  `public.round_submissions` (migration 035) as read through the
//  `get_event_rounds(p_event_id)` RPC (migration 049). Drives the
//  per-round breakdown under the leaderboard (F-MVP-05 V2-full).
//

import Foundation

/// One round submission row. `entries` is the raw JSONB array the
/// host submitted — the same shape `record_round_score` accepts
/// (`[{member_id, points_delta, meta}, …]`). The view decodes it
/// into `ScoreEntry` rows for display.
struct EventRound: Identifiable, Codable, Hashable {
    let id: UUID
    let eventId: UUID
    let roomId: UUID
    let packSlug: String
    let roundIndex: Int
    let entries: [ScoreEntry]
    let createdBy: UUID
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case roomId = "room_id"
        case packSlug = "pack_slug"
        case roundIndex = "round_index"
        case entries
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    init(
        id: UUID,
        eventId: UUID,
        roomId: UUID,
        packSlug: String,
        roundIndex: Int,
        entries: [ScoreEntry],
        createdBy: UUID,
        createdAt: Date
    ) {
        self.id = id
        self.eventId = eventId
        self.roomId = roomId
        self.packSlug = packSlug
        self.roundIndex = roundIndex
        self.entries = entries
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        eventId = try c.decode(UUID.self, forKey: .eventId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        packSlug = try c.decodeIfPresent(String.self, forKey: .packSlug) ?? ""
        roundIndex = try c.decodeIfPresent(Int.self, forKey: .roundIndex) ?? 0
        entries = try c.decodeIfPresent([ScoreEntry].self, forKey: .entries) ?? []
        createdBy = try c.decode(UUID.self, forKey: .createdBy)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
