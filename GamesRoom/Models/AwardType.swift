//
//  AwardType.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One of four season-end awards.
///
/// `.drowning` is the privacy-sensitive one — the recipient sees it
/// privately on the awards card; the host-public awards surface
/// suppresses it. This privacy boundary is enforced at the Services
/// layer when projecting rows, never inside this type.
enum AwardType: String, Codable, CaseIterable, Hashable {
    /// Most-improved. Member who climbed the leaderboard furthest
    /// across the season.
    case phoenix

    /// Most-played. Member with the highest `sessionsPlayed` on the
    /// season. Always public.
    case veteran

    /// Biggest single-session net positive. Always public. Single
    /// winner per season.
    case whale

    /// Member whose balance trended negative across the season.
    /// Surfaces only to the recipient, never to the host-public
    /// feed or other members.
    case drowning

    /// Whether the award is private to the recipient.
    var isPrivate: Bool {
        self == .drowning
    }

    /// Display label for the awards card.
    var displayName: String {
        switch self {
        case .phoenix:   return "Phoenix"
        case .veteran:   return "Veteran"
        case .whale:     return "Whale"
        case .drowning:  return "Drowning"
        }
    }
}
