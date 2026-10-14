//
//  SeasonComparisonViews.swift
//  GamesRoom
//
//  v1.2 slice 2c — the Seasons section. Progressive disclosure:
//  level 0 is one bar per season (no tap), with a ghost tick on the
//  current bar where last season ended. No axes, no legend: grey is
//  the past, accent is now, and the numbers sit beside the bars.
//

import SwiftUI

struct SeasonsSection: View {
    let rows: [SeasonHistoryEntry]
    let currentScore: Int64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false

    private var scale: Int64 {
        SeasonComparison.barScale(current: currentScore, pastTotals: rows.map(\.callerTotal))
    }

    private var lastSeasonFinal: Int64? { rows.first?.callerTotal }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Seasons")
            currentRow
            ForEach(rows) { row in
                Divider().overlay(Theme.Palette.hairline)
                pastRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if reduceMotion { grown = true } else {
                withAnimation(.easeOut(duration: 0.5)) { grown = true }
            }
        }
    }

    // MARK: Rows

    private var currentRow: some View {
        let gap = lastSeasonFinal.map { SeasonComparison.gapToLastSeason(current: currentScore, lastSeasonFinal: $0) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("This season")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer(minLength: 8)
                if let gap {
                    Text(SeasonComparison.signed(gap))
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(signColor(gap))
                }
                scoreText(currentScore)
            }
            SeasonBar(
                fraction: SeasonComparison.barFraction(currentScore, scale: scale),
                color: currentScore < 0 ? Theme.Palette.loss : Theme.Palette.accent,
                tick: lastSeasonFinal.map { SeasonComparison.barFraction($0, scale: scale) },
                grown: grown
            )
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SeasonComparison.currentBarSentence(score: currentScore, lastSeasonFinal: lastSeasonFinal)))
        .accessibilityIdentifier("season-row-current")
    }

    private func pastRow(_ row: SeasonHistoryEntry) -> some View {
        let d = row.delta(against: currentScore)
        let name = row.subtitle.isEmpty ? dateRange(row) : row.subtitle
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !row.subtitle.isEmpty {
                        Text(dateRange(row))
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(SeasonComparison.signed(d))
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(signColor(d))
                scoreText(row.callerTotal)
            }
            SeasonBar(
                fraction: SeasonComparison.barFraction(row.callerTotal, scale: scale),
                color: Theme.Palette.primaryText.opacity(0.28),
                tick: nil,
                grown: grown
            )
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(SeasonComparison.pastBarSentence(name: name, total: row.callerTotal, currentScore: currentScore)))
        .accessibilityIdentifier("season-row-\(row.ordinal)")
    }

    // MARK: Helpers

    private func scoreText(_ value: Int64) -> some View {
        Text("\(value)")
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Palette.primaryText)
            .frame(minWidth: 72, alignment: .trailing)
    }

    private func signColor(_ value: Int64) -> Color {
        value > 0 ? Theme.Palette.gain : (value < 0 ? Theme.Palette.loss : Theme.Palette.primaryText.opacity(0.4))
    }

    private func dateRange(_ row: SeasonHistoryEntry) -> String {
        if let ended = row.endedAt {
            return "\(row.startedAt.formatted(.dateTime.month().day().year())) – \(ended.formatted(.dateTime.month().day().year()))"
        }
        return row.startedAt.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One season as a bar. `tick` marks where last season ended, drawn
/// as a thin grey line crossing the bar, so "am I past it?" is read
/// by position, not by numbers.
struct SeasonBar: View {
    let fraction: Double
    let color: Color
    let tick: Double?
    let grown: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: max(geo.size.width * (grown ? fraction : 0), fraction > 0 ? 2 : 0), height: 6)
                if let tick {
                    Rectangle()
                        .fill(Theme.Palette.primaryText.opacity(0.6))
                        .frame(width: 1.5, height: 14)
                        .offset(x: min(geo.size.width * tick, geo.size.width - 1.5))
                }
            }
            .frame(height: 14)
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}
