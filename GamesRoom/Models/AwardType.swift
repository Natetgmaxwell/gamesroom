//
//  AwardType.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One of the season-end awards.
///
/// `.drowning` is the privacy-sensitive one — the recipient sees it
/// privately on the awards card; the host-public awards surface
/// suppresses it. This privacy boundary is enforced at the Services
/// layer when projecting rows, never inside this type.
///
/// V0.53 ledger-as-social-surface (migration 067) added four awards:
/// `.ironMann`, `.comebackKid`, `.goodSport`, and `.tonightStar`.
/// The first three are season-end awards computed in `close_season`;
/// `.tonightStar` is ephemeral (computed at session finalize, never
/// persisted as a `season_awards` row). All four are public.
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

    /// Longest run of consecutive attended sessions (min run 3).
    /// Attended = ≥1 casino_settlement transaction in the session.
    /// Always public.
    case ironMann = "iron_mann"

    /// Member who went season-minimum net < 0 and ended the season
    /// net > 0; winner = largest (season_end_net − season_minimum).
    /// Always public.
    case comebackKid = "comeback_kid"

    /// Among members with ≥3 losing sessions, the one with the
    /// highest median of those session nets (smallest typical loss).
    /// Voice-only per the Good Sport principle — never a
    /// leaderboard position, never a scored metric. Always public.
    case goodSport = "good_sport"

    /// Ephemeral per-night ceremonial-card moment. Computed at
    /// session finalize, never persisted as a `season_awards` row.
    /// Always public.
    case tonightStar = "tonight_star"

    /// Whether the award is private to the recipient.
    var isPrivate: Bool {
        self == .drowning
    }

    /// Display label for the awards card.
    var displayName: String {
        switch self {
        case .phoenix:     return "Phoenix"
        case .veteran:     return "Veteran"
        case .whale:       return "Whale"
        case .drowning:    return "Drowning"
        case .ironMann:    return "Iron Mann"
        case .comebackKid: return "Comeback Kid"
        case .goodSport:   return "Good Sport"
        case .tonightStar: return "Tonight's Star"
        }
    }
}
