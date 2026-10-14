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

    /// Signed label with a true minus sign, matching standings.
    static func signed(_ value: Int64) -> String {
        if value > 0 { return "+\(value)" }
        if value < 0 { return "\u{2212}\(-value)" }
        return "0"
    }
}
