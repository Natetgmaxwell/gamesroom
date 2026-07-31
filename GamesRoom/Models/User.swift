//
//  User.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// A Supabase-authenticated user. Mirrors `auth.users` joined to
/// `public.users` in the V0.8 backend. Carries only the fields the
/// room/membership/leaderboard surface needs — no email, no avatar,
/// no metadata.
struct User: Identifiable, Codable, Hashable {
    /// `auth.uid()` for the user. Stable across rooms.
    let id: UUID

    /// User-facing name shown across rooms, leaderboards, and
    /// RSVP rows. Not unique.
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
    }
}
