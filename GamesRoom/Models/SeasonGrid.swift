//
//  SeasonGrid.swift
//  GamesRoom
//
//  v1.2 slice 2c. Points per game night per member for one season,
//  from `get_season_grid` (migration 101). Pure data + derivations,
//  Foundation only.
//

import Foundation

/// One row of `get_season_grid`: one member's points on one night.
struct SeasonGridRow: Codable, Hashable {
    let sessionId: UUID
    let playedAt: Date
    let memberId: UUID
    let displayName: String
    let points: Int64

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case playedAt = "played_at"
        case memberId = "member_id"
        case displayName = "display_name"
        case points
    }
}

/// The season as a nights x members matrix. Nights run oldest first;
/// members run by season total, highest first. A missing cell means
/// the member did not play that night (distinct from scoring 0).
struct SeasonGrid: Hashable {
    struct Night: Hashable, Identifiable {
        let id: UUID
        let playedAt: Date
    }

    struct Member: Hashable, Identifiable {
        let id: UUID
        let name: String
        let total: Int64
    }

    let nights: [Night]
    let members: [Member]
    private let cells: [UUID: [UUID: Int64]]

    init(rows: [SeasonGridRow]) {
        var cells: [UUID: [UUID: Int64]] = [:]
        var nightDates: [UUID: Date] = [:]
        var names: [UUID: String] = [:]
        var totals: [UUID: Int64] = [:]
        for row in rows {
            cells[row.sessionId, default: [:]][row.memberId, default: 0] += row.points
            nightDates[row.sessionId] = min(nightDates[row.sessionId] ?? row.playedAt, row.playedAt)
            names[row.memberId] = row.displayName
            totals[row.memberId, default: 0] += row.points
        }
        self.cells = cells
        self.nights = nightDates
            .map { Night(id: $0.key, playedAt: $0.value) }
            .sorted { ($0.playedAt, $0.id.uuidString) < ($1.playedAt, $1.id.uuidString) }
        self.members = totals
            .map { Member(id: $0.key, name: names[$0.key] ?? "Member", total: $0.value) }
            .sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }

    var isEmpty: Bool { nights.isEmpty }

    func points(night: UUID, member: UUID) -> Int64? {
        cells[night]?[member]
    }

    /// Largest single-night magnitude in the season. Every cell's
    /// colour intensity is read against this, so the grid's darkest
    /// green is the season's best night.
    var maxMagnitude: Int64 {
        max(cells.values.flatMap { $0.values }.map { abs($0) }.max() ?? 0, 1)
    }

    /// 0...1 colour intensity for a cell. Played cells never drop
    /// below a floor so a small score still reads as "played".
    func intensity(_ points: Int64) -> Double {
        guard points != 0 else { return 0 }
        return max(0.18, min(Double(abs(points)) / Double(maxMagnitude), 1))
    }

    /// The member's running total after each night they played,
    /// oldest first. This is the line on the dual trace.
    func cumulative(for member: UUID) -> [Int64] {
        var running: Int64 = 0
        return nights.compactMap { night in
            guard let p = points(night: night.id, member: member) else { return nil }
            running += p
            return running
        }
    }

    /// Running total for a member through (and including) a night.
    func runningTotal(member: UUID, through night: UUID) -> Int64 {
        var running: Int64 = 0
        for n in nights {
            running += points(night: n.id, member: member) ?? 0
            if n.id == night { break }
        }
        return running
    }

    /// The member with the night's top score, nil on a tie or an
    /// empty night.
    func winner(of night: UUID) -> UUID? {
        guard let row = cells[night], let best = row.values.max() else { return nil }
        let top = row.filter { $0.value == best }
        return top.count == 1 ? top.first?.key : nil
    }

    // MARK: Level 2 — words for the grid

    /// Row marker for a night: "today", "5d ago", "3w ago", "4mo ago".
    static func relativeLabel(_ date: Date, now: Date) -> String {
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
        if days < 1 { return "today" }
        if days < 7 { return "\(days)d ago" }
        if days < 60 { return "\(days / 7)w ago" }
        return "\(days / 30)mo ago"
    }

    /// The verbatim numbers under one square.
    func cellSentence(night: UUID, member: UUID, now: Date) -> String {
        let name = members.first { $0.id == member }?.name ?? "Member"
        let when = nights.first { $0.id == night }.map { Self.relativeLabel($0.playedAt, now: now) } ?? ""
        guard let p = points(night: night, member: member) else {
            return "\(name) sat out, \(when)."
        }
        let running = runningTotal(member: member, through: night)
        let so = running < 0 ? "\u{2212}\(-running)" : "\(running)"
        return "\(name), \(when): \(SeasonComparison.signed(p)). \(so) so far."
    }

    /// What VoiceOver hears before the squares: the season's shape
    /// in one or two sentences.
    func summarySentence(now: Date) -> String {
        guard !nights.isEmpty else { return "No nights scored." }
        var wins: [UUID: Int] = [:]
        for night in nights { if let w = winner(of: night.id) { wins[w, default: 0] += 1 } }
        var parts = ["\(SeasonComparison.nightsPhrase(nights.count).capitalizedFirst)."]
        if let most = wins.values.max(),
           let top = wins.filter({ $0.value == most }).map(\.key).onlyElement,
           let name = members.first(where: { $0.id == top })?.name {
            parts.append("\(name) won the most nights, \(SeasonComparison.number(most)).")
        }
        var best: (night: Night, member: Member, points: Int64)?
        for night in nights {
            for member in members {
                if let p = points(night: night.id, member: member.id), p > (best?.points ?? 0) {
                    best = (night, member, p)
                }
            }
        }
        if let best {
            parts.append("Biggest night: \(best.member.name), \(SeasonComparison.signed(best.points)), \(Self.relativeLabel(best.night.playedAt, now: now)).")
        }
        return parts.joined(separator: " ")
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
