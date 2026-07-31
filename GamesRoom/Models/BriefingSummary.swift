//
//  BriefingSummary.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Aggregated counts that drive the Briefing card on the pre-play
/// slot. Computed at the edge (RPC or service-layer view-model) so
/// the Briefing slot renders consistently with one fetch.
///
/// The numbers populate the `{N} seats left, {N} claimed. RSVP in
/// the app.` line in the T-48h push body and the morning-of body.
struct BriefingSummary: Codable, Hashable {
    let eventId: UUID
    let roomId: UUID

    /// Total seats at the table (mirrors `Event.maxSeats`).
    let seatsTotal: Int

    /// Members who have tapped `Claim seat`. Counts for both the
    /// card line and the morning-of `{N} seats left` derivation.
    let seatsClaimed: Int

    /// Members who have tapped `Can't make it`. The host's
    /// claim-status view distinguishes these from `no response` —
    /// a declined seat is genuinely available.
    let seatsDeclined: Int

    /// Members who haven't responded. The on-create push recipients
    /// minus `seatsClaimed + seatsDeclined`.
    let seatsUnclaimed: Int

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case roomId = "room_id"
        case seatsTotal = "seats_total"
        case seatsClaimed = "seats_claimed"
        case seatsDeclined = "seats_declined"
        case seatsUnclaimed = "seats_unclaimed"
    }

    init(
        eventId: UUID,
        roomId: UUID,
        seatsTotal: Int,
        seatsClaimed: Int,
        seatsDeclined: Int,
        seatsUnclaimed: Int
    ) {
        self.eventId = eventId
        self.roomId = roomId
        self.seatsTotal = seatsTotal
        self.seatsClaimed = seatsClaimed
        self.seatsDeclined = seatsDeclined
        self.seatsUnclaimed = seatsUnclaimed
    }

    /// Seats still on the table. Public total - claimed - declined.
    /// Bound below at 0 in case a host over-books in play.
    var seatsLeft: Int {
        max(0, seatsTotal - seatsClaimed - seatsDeclined)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(UUID.self, forKey: .eventId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        seatsTotal = try c.decodeIfPresent(Int.self, forKey: .seatsTotal) ?? 0
        seatsClaimed = try c.decodeIfPresent(Int.self, forKey: .seatsClaimed) ?? 0
        seatsDeclined = try c.decodeIfPresent(Int.self, forKey: .seatsDeclined) ?? 0
        seatsUnclaimed = try c.decodeIfPresent(Int.self, forKey: .seatsUnclaimed) ?? 0
    }
}
