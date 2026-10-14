//
//  SeasonComparisonViews.swift
//  GamesRoom
//
//  v1.2 slice 2c — the Seasons section. Progressive disclosure:
//  level 0 is one bar per season (no tap), with a ghost tick on the
//  current bar where last season ended. No axes, no legend: grey is
//  the past, accent is now, and the numbers sit beside the bars.
//  Level 1 (tap a row) is the dual trace: that season night by night
//  over the season before it as a grey ghost, plus one sentence.
//

import SwiftUI

struct SeasonsSection: View {
    let rows: [SeasonHistoryEntry]
    let currentScore: Int64
    /// The caller's running total after each night this season
    /// (from the active season grid). Empty until migration 101.
    var currentNights: [Int64] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    /// Which row shows its trace: 0 = this season, else the ordinal.
    @State private var expanded: Int?

    private var scale: Int64 {
        SeasonComparison.barScale(current: currentScore, pastTotals: rows.map(\.callerTotal))
    }

    private var lastSeasonFinal: Int64? { rows.first?.callerTotal }

    private func nights(_ row: SeasonHistoryEntry) -> [Int64] {
        SeasonComparison.nightTotals(row.scoreProgression)
    }

    private func toggle(_ key: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            expanded = expanded == key ? nil : key
        }
    }

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
                chevron(open: expanded == 0, enabled: !currentNights.isEmpty)
            }
            SeasonBar(
                fraction: SeasonComparison.barFraction(currentScore, scale: scale),
                color: currentScore < 0 ? Theme.Palette.loss : Theme.Palette.accent,
                tick: lastSeasonFinal.map { SeasonComparison.barFraction($0, scale: scale) },
                grown: grown
            )
        }
        .padding(.vertical, 12)
        .expandableRow(
            enabled: !currentNights.isEmpty,
            isExpanded: expanded == 0,
            label: SeasonComparison.currentBarSentence(score: currentScore, lastSeasonFinal: lastSeasonFinal),
            identifier: "season-row-current",
            toggle: { toggle(0) }
        ) {
            let ghost = rows.first.map(nights) ?? []
            SeasonTraceDetail(
                solid: currentNights,
                ghost: ghost,
                solidColor: Theme.Palette.accent,
                sentence: SeasonComparison.currentTraceSentence(current: currentNights, previous: ghost)
            )
        }
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
                chevron(open: expanded == row.ordinal, enabled: !row.scoreProgression.isEmpty)
            }
            SeasonBar(
                fraction: SeasonComparison.barFraction(row.callerTotal, scale: scale),
                color: Theme.Palette.primaryText.opacity(0.28),
                tick: nil,
                grown: grown
            )
        }
        .padding(.vertical, 12)
        .expandableRow(
            enabled: !row.scoreProgression.isEmpty,
            isExpanded: expanded == row.ordinal,
            label: SeasonComparison.pastBarSentence(name: name, total: row.callerTotal, currentScore: currentScore),
            identifier: "season-row-\(row.ordinal)",
            toggle: { toggle(row.ordinal) }
        ) {
            let season = nights(row)
            let before = rows.first(where: { $0.ordinal < row.ordinal }).map(nights) ?? []
            SeasonTraceDetail(
                solid: season,
                ghost: before,
                solidColor: Theme.Palette.primaryText.opacity(0.85),
                sentence: SeasonComparison.pastTraceSentence(season: season, before: before)
            )
        }
    }

    // MARK: Helpers

    private func scoreText(_ value: Int64) -> some View {
        Text("\(value)")
            .font(Theme.Typography.mono)
            .foregroundStyle(Theme.Palette.primaryText)
            .frame(minWidth: 72, alignment: .trailing)
    }

    /// Same column and glyph as the standings rows, so the two
    /// sections' numbers line up. Blank when there is nothing to open.
    private func chevron(open: Bool, enabled: Bool) -> some View {
        Image(systemName: open ? Theme.Icon.chevronUp : Theme.Icon.chevronDown)
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Palette.primaryText.opacity(enabled ? 0.4 : 0))
            .frame(width: 16)
            .padding(.leading, 2)
            .accessibilityHidden(true)
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

// MARK: - Level 1

private extension View {
    /// A season row that opens its trace on tap. VoiceOver hears the
    /// bar as one sentence and the trace as a second one.
    func expandableRow<Detail: View>(
        enabled: Bool,
        isExpanded: Bool,
        label: String,
        identifier: String,
        toggle: @escaping () -> Void,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            self
                .contentShape(Rectangle())
                .onTapGesture { if enabled { toggle() } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(label))
                .accessibilityIdentifier(identifier)
                .accessibilityAddTraits(enabled ? .isButton : [])
                .accessibilityHint(Text(enabled ? (isExpanded ? "Hides the night by night comparison." : "Shows the night by night comparison.") : ""))
            if isExpanded {
                detail()
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
    }
}

/// The dual trace plus its sentence. The sentence is what VoiceOver
/// reads; the drawing is hidden from it.
struct SeasonTraceDetail: View {
    let solid: [Int64]
    let ghost: [Int64]
    let solidColor: Color
    let sentence: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SeasonDualTrace(solid: solid, ghost: ghost, solidColor: solidColor)
                .frame(height: 76)
            Text(sentence)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(sentence))
        .accessibilityIdentifier("season-trace")
    }
}

/// Two running totals on one shared scale, night by night. The ghost
/// is the earlier season in grey; the solid line is the season being
/// read. The gap between them is tinted green or red where the solid
/// line is ahead or behind. No axes, gridlines or legend; the solid
/// line's latest value is the only label.
struct SeasonDualTrace: View {
    let solid: [Int64]
    let ghost: [Int64]
    let solidColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let labelHeight: CGFloat = 14
            let size = CGSize(width: geo.size.width - 6, height: geo.size.height - labelHeight - 4)
            let plot = TracePlot(solid: solid, ghost: ghost, size: size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(plot.gapBands.enumerated()), id: \.offset) { _, band in
                    band.path.fill((band.ahead ? Theme.Palette.gain : Theme.Palette.loss).opacity(0.14))
                        .opacity(Double(drawn))
                }
                plot.line(ghost)
                    .stroke(Theme.Palette.primaryText.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                plot.line(solid)
                    .trim(from: 0, to: drawn)
                    .stroke(solidColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let end = plot.point(solid.count - 1, solid.last) {
                    Circle()
                        .fill(solidColor)
                        .frame(width: 5, height: 5)
                        .position(end)
                        .opacity(Double(drawn))
                    Text("\(solid.last ?? 0)")
                        .font(Theme.Typography.monoFootnote)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        .fixedSize()
                        .position(
                            x: min(max(end.x, 24), size.width - 18),
                            y: end.y < size.height / 2 ? min(end.y + 12, size.height + labelHeight / 2) : max(end.y - 12, 6)
                        )
                }
            }
            .padding(.horizontal, 3)
        }
        .accessibilityHidden(true)
        .onAppear {
            if reduceMotion { drawn = 1 } else {
                withAnimation(.easeOut(duration: 0.6)) { drawn = 1 }
            }
        }
    }
}

/// Geometry for the dual trace: both series share one x step (night
/// index) and one y range (always including zero).
private struct TracePlot {
    let solid: [Int64]
    let ghost: [Int64]
    let size: CGSize

    private var count: Int { max(solid.count, ghost.count, 2) }
    private var lo: Int64 { min((solid + ghost).min() ?? 0, 0) }
    private var hi: Int64 { max((solid + ghost).max() ?? 0, 0) }

    func point(_ i: Int, _ value: Int64?) -> CGPoint? {
        guard let value, i >= 0 else { return nil }
        let range = max(Double(hi - lo), 1)
        let x = size.width * CGFloat(i) / CGFloat(count - 1)
        let y = size.height * CGFloat(1 - Double(value - lo) / range)
        return CGPoint(x: x, y: y)
    }

    func line(_ series: [Int64]) -> Path {
        Path { p in
            for (i, v) in series.enumerated() {
                guard let pt = point(i, v) else { continue }
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
        }
    }

    /// One quad per night step where both lines exist, tinted by
    /// which line is ahead at the step's end.
    var gapBands: [(path: Path, ahead: Bool)] {
        let n = min(solid.count, ghost.count)
        guard n >= 2 else { return [] }
        return (1..<n).compactMap { i in
            guard let s0 = point(i - 1, solid[i - 1]), let s1 = point(i, solid[i]),
                  let g0 = point(i - 1, ghost[i - 1]), let g1 = point(i, ghost[i]) else { return nil }
            var path = Path()
            path.move(to: s0); path.addLine(to: s1); path.addLine(to: g1); path.addLine(to: g0); path.closeSubpath()
            return (path, solid[i] >= ghost[i])
        }
    }
}
