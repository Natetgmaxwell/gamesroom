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

/// The season as nights x members. Nights run oldest first; members
/// run by season total, highest first. A missing cell means the member
/// did not play that night (distinct from scoring 0).
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

    /// One night in a member's strip. Won and lost are the sign of
    /// the night, never its size: the sheet draws no magnitude.
    enum Mark: Hashable {
        case won, lost, even, satOut
    }

    func mark(night: UUID, member: UUID) -> Mark {
        guard let p = points(night: night, member: member) else { return .satOut }
        return p > 0 ? .won : (p < 0 ? .lost : .even)
    }

    /// One mark per season night, oldest first.
    func strip(for member: UUID) -> [Mark] {
        nights.map { mark(night: $0.id, member: member) }
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

    // MARK: Level 2 — words for the strips

    /// When a night was, as said in a tap sentence: "today", "5d ago",
    /// "3w ago", "4mo ago".
    static func relativeLabel(_ date: Date, now: Date) -> String {
        let days = Int((now.timeIntervalSince(date) / 86_400).rounded(.down))
        if days < 1 { return "today" }
        if days < 7 { return "\(days)d ago" }
        if days < 60 { return "\(days / 7)w ago" }
        return "\(days / 30)mo ago"
    }

    /// The verbatim numbers under one mark.
    func cellSentence(night: UUID, member: UUID, now: Date) -> String {
        let name = members.first { $0.id == member }?.name ?? "Member"
        let when = nights.first { $0.id == night }.map { Self.relativeLabel($0.playedAt, now: now) } ?? ""
        guard let p = points(night: night, member: member) else {
            return "\(name) sat out, \(when)."
        }
        let running = runningTotal(member: member, through: night)
        return "\(name), \(when): \(SeasonComparison.signed(p)). \(Self.plain(running)) so far."
    }

    /// One member's row as VoiceOver hears it:
    /// "Sam: 4 nights won, 2 lost, 2 sat out, 490 total."
    func rowSentence(member: UUID) -> String {
        let name = members.first { $0.id == member }?.name ?? "Member"
        let total = members.first { $0.id == member }?.total ?? 0
        let marks = strip(for: member)
        let won = marks.filter { $0 == .won }.count
        var parts = ["\(won) \(won == 1 ? "night" : "nights") won", "\(marks.filter { $0 == .lost }.count) lost"]
        let even = marks.filter { $0 == .even }.count
        if even > 0 { parts.append("\(even) even") }
        let out = marks.filter { $0 == .satOut }.count
        if out > 0 { parts.append("\(out) sat out") }
        parts.append("\(Self.plain(total)) total")
        return "\(name): \(parts.joined(separator: ", "))."
    }

    /// The line above the strips. "Won the most nights" counts the
    /// same green marks the strips show (nights finished up).
    func summarySentence() -> String {
        guard !nights.isEmpty else { return "No nights scored." }
        var parts = ["\(SeasonComparison.nightsPhrase(nights.count).capitalizedFirst)."]
        let wins = members.map { m in (m, strip(for: m.id).filter { $0 == .won }.count) }
        if let most = wins.map(\.1).max(), most > 0,
           let top = wins.filter({ $0.1 == most }).onlyElement {
            parts.append("\(top.0.name) won the most nights, \(SeasonComparison.number(most)).")
        }
        var best: (member: Member, points: Int64)?
        for night in nights {
            for member in members {
                if let p = points(night: night.id, member: member.id), p > (best?.points ?? 0) {
                    best = (member, p)
                }
            }
        }
        if let best {
            parts.append("Biggest night: \(best.member.name), \(SeasonComparison.signed(best.points)).")
        }
        return parts.joined(separator: " ")
    }

    /// A total with a true minus sign and no plus: "490", "−120".
    private static func plain(_ value: Int64) -> String {
        value < 0 ? "\u{2212}\(-value)" : "\(value)"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

private extension Array {
    var onlyElement: Element? { count == 1 ? first : nil }
}
