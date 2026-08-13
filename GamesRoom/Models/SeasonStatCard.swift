//
//  SeasonStatCard.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  V0.53 ledger-as-social-surface — the shareable stat card. One
//  printable PNG per member per season, generated on the member's own
//  device and shared through the system share sheet. It is a *personal*
//  card: only the member's own numbers and public awards, never a
//  ranking position, never a badge shelf. Drowning is excluded before
//  render.
//

import Foundation

/// The member's own season record — the numbers the stat card shows.
/// No one else's numbers, no rank, no scoreboard.
struct SeasonStatRecord: Codable, Hashable {
    /// Sessions the member attended (≥1 casino_settlement transaction).
    let sessionsPlayed: Int

    /// Net chips across the season (sum of casino_settlement deltas).
    let netChips: Int64

    /// Best single-session net (largest positive delta), or `nil` if
    /// the member never had a positive session.
    let bestSingleSession: Int64?

    /// Worst single-session net (most negative delta), or `nil` if the
    /// member never had a negative session.
    let worstSingleSession: Int64?

    /// Longest run of consecutive attended sessions.
    let longestStreak: Int
}

/// The shareable stat card value. A pure struct the view renders into
/// a PNG via `ImageRenderer`. `awards` holds only the member's public
/// awards (Drowning excluded before the card is built).
struct SeasonStatCard: Identifiable, Codable, Hashable {
    let roomName: String
    let seasonOrdinal: Int
    let seasonSubtitle: String
    let memberName: String
    let record: SeasonStatRecord
    let awards: [AwardType]
    let mascotLine: String

    /// Stable identity for the share sheet / ForEach.
    var id: String { "\(roomName)-\(seasonOrdinal)-\(memberName)" }
}
