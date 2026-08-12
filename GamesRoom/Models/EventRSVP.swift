//
//  EventRSVP.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One-line claimed-seat roster for social proof. Pure string
/// formatting so the Foundation runner can test it.
enum SocialProof {
    static func claimedSeatsCaption(claimedNames: [String]) -> String? {
        let names = claimedNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) has claimed a seat"
        case 2:
            return "\(names[0]) and \(names[1]) have claimed seats"
        default:
            return "\(names[0]), \(names[1]) +\(names.count - 2) more have claimed seats"
        }
    }
}

/// One member's RSVP row for one event, joined with the member's
/// display name. Returned by the `get_event_rsvps` RPC (migration
/// 047) so the briefing slot can render the seat grid — which
/// chairs are claimed, by whom, and which are still open.
struct EventRSVP: Identifiable, Codable, Hashable {
    /// Composite `eventId:memberId` exposed to UI lists. Stable.
    let id: String
    let eventId: UUID
    let memberId: UUID
    let displayName: String
    let state: MemberRSVPState

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case memberId = "member_id"
        case displayName = "display_name"
        case state
    }

    init(
        eventId: UUID,
        memberId: UUID,
        displayName: String,
        state: MemberRSVPState
    ) {
        self.id = "\(eventId.uuidString):\(memberId.uuidString)"
        self.eventId = eventId
        self.memberId = memberId
        self.displayName = displayName
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eventId = try c.decode(UUID.self, forKey: .eventId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        state = try c.decodeIfPresent(MemberRSVPState.self, forKey: .state) ?? .unclaimed
        id = "\(eventId.uuidString):\(memberId.uuidString)"
    }
}
