//
//  SeasonComparison.swift
//  GamesRoom
//
//  v1.2 slice 2c. Pure comparison math behind the Seasons section:
//  bar scales (level 0), dual-trace gaps (level 1) and the sentences
//  VoiceOver reads for each. Foundation only so the CLI runner can
//  test it.
//

import Foundation

enum SeasonComparison {

    // MARK: Level 0 — bars

    /// One shared scale for every bar in the section so lengths are
    /// comparable down the column. The largest magnitude among the
    /// current score and every past final wins; never zero.
    static func barScale(current: Int64?, pastTotals: [Int64]) -> Int64 {
        let magnitudes = ([current].compactMap { $0 } + pastTotals).map { abs($0) }
        return max(magnitudes.max() ?? 0, 1)
    }

    /// Bar length as a 0...1 fraction of the shared scale. Negative
    /// totals draw the same length as their magnitude; the colour
    /// carries the sign.
    static func barFraction(_ value: Int64, scale: Int64) -> Double {
        guard scale > 0 else { return 0 }
        return min(Double(abs(value)) / Double(scale), 1)
    }

    /// The caller's current score against where last season ended.
    /// Positive = past last season's finish.
    static func gapToLastSeason(current: Int64, lastSeasonFinal: Int64) -> Int64 {
        current - lastSeasonFinal
    }

    /// VoiceOver sentence for the current-season bar.
    static func currentBarSentence(score: Int64, lastSeasonFinal: Int64?) -> String {
        let base = "This season, \(score) so far"
        guard let last = lastSeasonFinal else { return base + "." }
        let gap = gapToLastSeason(current: score, lastSeasonFinal: last)
        if gap > 0 { return base + ", \(gap) past where last season ended." }
        if gap < 0 { return base + ", \(-gap) short of where last season ended." }
        return base + ", level with where last season ended."
    }

    /// VoiceOver sentence for a past-season bar. `currentScore` is
    /// the caller's score this season; the comparison is told from
    /// this season's point of view.
    static func pastBarSentence(name: String, total: Int64, currentScore: Int64) -> String {
        let d = currentScore - total
        let comparison: String
        if d > 0 { comparison = "This season is \(d) ahead." }
        else if d < 0 { comparison = "This season is \(-d) behind." }
        else { comparison = "This season is level with it." }
        return "\(name), finished on \(total). \(comparison)"
    }

    // MARK: Level 1 — dual trace

    /// One running total per night from a `score_progression` series.
    /// The server emits one point per transaction, so a night with
    /// several transactions repeats its timestamp; keep the last.
    static func nightTotals(_ points: [SeasonScorePoint]) -> [Int64] {
        var out: [Int64] = []
        var lastAt: Date?
        for p in points {
            if p.at == lastAt, !out.isEmpty { out[out.count - 1] = p.total } else { out.append(p.total) }
            lastAt = p.at
        }
        return out
    }

    /// The gap between the solid line and the ghost at the solid
    /// line's latest night. When the ghost ran fewer nights, its
    /// final total stands in. nil when either line is empty.
    static func traceGap(current: [Int64], previous: [Int64]) -> Int64? {
        guard let last = current.last, !previous.isEmpty else { return nil }
        return last - previous[min(current.count, previous.count) - 1]
    }

    /// The one plain sentence under the current season's trace.
    static func currentTraceSentence(current: [Int64], previous: [Int64]) -> String {
        guard let last = current.last else { return "No nights scored yet this season." }
        let nights = nightsPhrase(current.count)
        guard let gap = traceGap(current: current, previous: previous) else {
            return "\(last) after \(nights). Nothing from last season to compare."
        }
        let lead: String
        if gap > 0 { lead = "Ahead of last season by \(gap) after \(nights)." }
        else if gap < 0 { lead = "Behind last season by \(-gap) after \(nights)." }
        else { lead = "Level with last season after \(nights)." }
        let more = previous.count - current.count
        guard more > 0 else { return lead }
        return lead + " Last season ran \(more == 1 ? "one more night" : "\(number(more)) more nights")."
    }

    /// The sentence under a past season's trace, told against the
    /// season before it.
    static func pastTraceSentence(season: [Int64], before: [Int64]) -> String {
        guard let final = season.last else { return "No nights scored that season." }
        guard let prior = before.last else { return "First season here. Finished on \(final)." }
        let d = final - prior
        if d > 0 { return "Finished \(d) ahead of the season before." }
        if d < 0 { return "Finished \(-d) behind the season before." }
        return "Finished level with the season before."
    }

    static func nightsPhrase(_ n: Int) -> String {
        n == 1 ? "one night" : "\(number(n)) nights"
    }

    /// Small counts read as words in a sentence; larger stay digits.
    static func number(_ n: Int) -> String {
        let words = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return (0..<words.count).contains(n) ? words[n] : "\(n)"
    }

    /// Signed label with a true minus sign, matching standings.
    static func signed(_ value: Int64) -> String {
        if value > 0 { return "+\(value)" }
        if value < 0 { return "\u{2212}\(-value)" }
        return "0"
    }
}
