//
//  Member.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// A user's row inside one room. Mirrors `public.members`.
/// Carries everything needed to identify membership and surface the
/// V0.8 MemberNotes social-preferences card (L3, KEEP & PROMOTE).
struct Member: Identifiable, Codable, Hashable {
    /// Composite `roomId:userId` exposed to UI lists; falls back to
    /// `userId.uuidString` alone when the payload omits `room_id`.
    /// Synthesised in `init(from:)`, stable.
    let id: String

    /// The remote `get_room_members` RPC does not return `room_id`
    /// in its legacy shape (migration 049 truncated the column list);
    /// `nil` when the server omits it.
    let roomId: UUID?

    let userId: UUID

    /// Role at the time the row was fetched; promoted via a separate
    /// mutation when the host hands over the room.
    let role: RoomRole

    /// When the user joined this room. UTC. Falls back to
    /// `.distantPast` when the server omits `joined_at` so an
    /// unknown join time is deterministic, not "now".
    let joinedAt: Date

    /// Last time the user opened this room's page. Used to drive the
    /// "still here?" amber wash on quiet state.
    let lastSeenAt: Date?

    /// Display name as of the last fetch. Cached so the leaderboard
    /// can render without a join to `public.users`.
    let displayName: String

    /// Host-visible social text + room-wide conversation prompt.
    /// Defaults to empty when the member hasn't set one yet — the
    /// UI surfaces the default value at write time, not at read.
    let socialPreference: SocialPreference

    /// Host-assigned team label for the season (F-MVP-05 V2-full,
    /// migration 049). `nil` = unassigned.
    let team: String?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case userId = "user_id"
        case role
        case joinedAt = "joined_at"
        case lastSeenAt = "last_seen_at"
        case displayName = "display_name"
        case socialPreference = "social_preference"
        case team
    }

    init(
        id: String,
        roomId: UUID,
        userId: UUID,
        role: RoomRole,
        joinedAt: Date,
        lastSeenAt: Date? = nil,
        displayName: String,
        socialPreference: SocialPreference = .empty,
        team: String? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.userId = userId
        self.role = role
        self.joinedAt = joinedAt
        self.lastSeenAt = lastSeenAt
        self.displayName = displayName
        self.socialPreference = socialPreference
        self.team = team
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        let decodedRoomId = try c.decodeIfPresent(UUID.self, forKey: .roomId)
        roomId = decodedRoomId
        if let decodedRoomId {
            id = "\(decodedRoomId.uuidString):\(userId.uuidString)"
        } else {
            id = userId.uuidString
        }
        role = try c.decode(RoomRole.self, forKey: .role)
        joinedAt = try c.decodeIfPresent(Date.self, forKey: .joinedAt) ?? .distantPast
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        socialPreference = try c.decodeIfPresent(SocialPreference.self, forKey: .socialPreference) ?? .empty
        team = try c.decodeIfPresent(String.self, forKey: .team)
    }
}
