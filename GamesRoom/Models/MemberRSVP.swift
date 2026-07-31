//
//  MemberRSVP.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One member's response to one event.
///
/// Mirrors `public.event_rsvps`. The V0.8 brief treats RSVP as
/// terminal-only for `declined` (no re-entry surface on the room
/// page). To change a response a member must use the member-side
/// event edit surface (v0.9 candidate).
struct MemberRSVP: Identifiable, Codable, Hashable {
    let id: UUID
    let eventId: UUID
    let roomId: UUID
    let memberId: UUID

    /// Current response state. Persisted as `state` in the database;
    /// the canonical "no row yet" interpretation is `.unclaimed`.
    let state: MemberRSVPState

    /// When the member tapped either CTA. `nil` while `state` is
    /// `.unclaimed`. Used to gate the T-48h / morning-of schedule.
    let respondedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case roomId = "room_id"
        case memberId = "member_id"
        case state
        case respondedAt = "responded_at"
    }

    init(
        id: UUID,
        eventId: UUID,
        roomId: UUID,
        memberId: UUID,
        state: MemberRSVPState,
        respondedAt: Date? = nil
    ) {
        self.id = id
        self.eventId = eventId
        self.roomId = roomId
        self.memberId = memberId
        self.state = state
        self.respondedAt = respondedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        eventId = try c.decode(UUID.self, forKey: .eventId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        state = try c.decodeIfPresent(MemberRSVPState.self, forKey: .state) ?? .unclaimed
        respondedAt = try c.decodeIfPresent(Date.self, forKey: .respondedAt)
    }
}
