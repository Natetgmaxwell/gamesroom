//
//  SeasonComparisonViews.swift
//  GamesRoom
//
//  v1.2 slice 2c — the Seasons section. Progressive disclosure:
//  level 0 is one bar per season (no tap), with a ghost tick on the
//  current bar where last season ended. No axes, no legend: grey is
//  the past, accent is now, and the numbers sit beside the bars.
//  Each bar carries the count of nights behind it, so the length is
//  never read on its own.
//  Level 1 (tap a row) is the dual trace: that season night by night
//  over the season before it as a grey ghost, plus one sentence.
//  Level 2 ("Every night") is one row per member with a strip of the
//  season's nights: green finished up, red down, an outline sat out,
//  under one line that says so.
//

import SwiftUI

struct SeasonsSection: View {
    let roomId: UUID
    let youId: UUID?
    let rows: [SeasonHistoryEntry]
    let currentScore: Int64
    /// The caller's running total after each night this season
    /// (from the active season grid). Empty until migration 101.
    var currentNights: [Int64] = []

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var grown = false
    /// Which row shows its trace: 0 = this season, else the ordinal.
    @State private var expanded: Int?
    @State private var gridSheet: GridSheetItem?
    @EnvironmentObject private var roomService: RoomService

    private var scale: Int64 {
        SeasonComparison.barScale(current: currentScore, pastTotals: rows.map(\.callerTotal))
    }

    private var lastSeasonFinal: Int64? { rows.first?.callerTotal }

    private func nights(_ row: SeasonHistoryEntry) -> [Int64] {
        SeasonComparison.nightTotals(row.scoreProgression)
    }

    /// What a bar's score was made over, in the fewest words. Empty
    /// when the season has no night data yet: a bar with no honest
    /// label is better than one with a wrong one.
    private func nightsCaption(_ count: Int) -> String {
        guard count > 0 else { return "" }
        return count == 1 ? "1 night" : "\(count) nights"
    }

    private func toggle(_ key: Int) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            expanded = expanded == key ? nil : key
        }
        if expanded == key, key != 0, let season = rows.first(where: { $0.ordinal == key }) {
            Task { await roomService.loadSeasonGrid(roomId: roomId, seasonId: season.seasonId) }
        }
    }

    /// Opens level 2 for a season when its grid is loaded; nil hides
    /// the "Every night" action (no grid until migration 101).
    private func openGrid(_ seasonId: UUID?, title: String) -> (() -> Void)? {
        guard let grid = roomService.cachedSeasonGrid(roomId: roomId, seasonId: seasonId) else { return nil }
        return { gridSheet = GridSheetItem(id: seasonId?.uuidString ?? "current", title: title, grid: grid) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Seasons")
                .padding(.bottom, Theme.Layout.roomHeaderGap)
            currentRow
            ForEach(rows) { row in
                Divider().overlay(Theme.Palette.hairline)
                pastRow(row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $gridSheet) { item in
            SeasonGridSheet(title: item.title, grid: item.grid, youId: youId)
        }
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
                grown: grown,
                caption: nightsCaption(currentNights.count)
            )
        }
        .padding(.vertical, Theme.Layout.roomRowInset)
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
                sentence: SeasonComparison.currentTraceSentence(current: currentNights, previous: ghost),
                onOpenGrid: openGrid(nil, title: "This season")
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
                grown: grown,
                caption: nightsCaption(nights(row).count)
            )
        }
        .padding(.vertical, Theme.Layout.roomRowInset)
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
                sentence: SeasonComparison.pastTraceSentence(season: season, before: before),
                onOpenGrid: openGrid(row.seasonId, title: name)
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
/// by position, not by numbers. `caption` says how many nights the
/// bar's score was made over, so no bar sits there unexplained. The
/// caption column is always reserved, even when empty, so every bar in
/// the section starts at the same x and lengths stay comparable.
struct SeasonBar: View {
    let fraction: Double
    let color: Color
    let tick: Double?
    let grown: Bool
    var caption: String = ""

    /// Same column and width as `scoreText`, so the caption under a
    /// bar lines up with the number above it.
    private static let captionWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: Theme.Layout.roomHeaderGap) {
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
            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                .lineLimit(1)
                .frame(width: Self.captionWidth, alignment: .trailing)
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
    var onOpenGrid: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if let onOpenGrid {
                Button(action: onOpenGrid) {
                    HStack(spacing: 4) {
                        Text("Every night")
                        Image(systemName: Theme.Icon.chevronRight)
                            .font(Theme.Typography.footnote)
                            .accessibilityHidden(true)
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Shows every member's nights, won and lost."))
                .accessibilityIdentifier("season-grid-open")
            }
        }
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

// MARK: - Level 2

struct GridSheetItem: Identifiable {
    let id: String
    let title: String
    let grid: SeasonGrid
}

/// The season, one row per member: the Members list idiom (monogram,
/// name, total on the right) with a strip of the season's nights in
/// place of the caption, oldest on the left. Green = finished the
/// night up, red = down, an outline = sat out. Sign only, never size.
/// One grey key line, no axes or dates; tap a mark for its numbers
/// and date.
struct SeasonGridSheet: View {
    let title: String
    let grid: SeasonGrid
    let youId: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: Cell?
    private let now = Date()
    private let avatarSize: CGFloat = 32
    private let avatarGap: CGFloat = 12

    struct Cell: Hashable {
        let night: UUID
        let member: UUID
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(grid.summarySentence())
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("season-grid-summary")
                    Text("Each mark is a night. Green won, red lost, outline sat out.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("season-grid-key")
                    ForEach(Array(grid.members.enumerated()), id: \.element.id) { r, member in
                        if r > 0 { Divider().overlay(Theme.Palette.hairline) }
                        memberRow(r, member)
                    }
                }
                .padding(Theme.Layout.edgePadding)
            }
            .background(Theme.Palette.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func memberRow(_ r: Int, _ member: SeasonGrid.Member) -> some View {
        let isYou = member.id == youId
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: avatarGap) {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.18))
                    .frame(width: avatarSize, height: avatarSize)
                    .overlay(
                        Text(initials(member.name))
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(member.name)
                            .font(Theme.Typography.body.weight(isYou ? .semibold : .regular))
                            .foregroundStyle(Theme.Palette.primaryText)
                            .lineLimit(1)
                        if isYou {
                            Text("you")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(isYou ? "You, " + grid.rowSentence(member: member.id) : grid.rowSentence(member: member.id)))
                    .accessibilityIdentifier("season-strip-row-\(r)")
                    strip(r, member)
                }
                Spacer(minLength: 8)
                Text("\(member.total)")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(minWidth: 72, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            if let selected, selected.member == member.id {
                Text(grid.cellSentence(night: selected.night, member: selected.member, now: now))
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .padding(.leading, avatarSize + avatarGap)
                    .transition(.opacity)
                    .accessibilityIdentifier("season-grid-detail")
            }
        }
        .padding(.vertical, 12)
    }

    /// One mark per night, oldest first. Marks shrink to fit long
    /// seasons; the tap target stays a full row tall.
    private func strip(_ r: Int, _ member: SeasonGrid.Member) -> some View {
        HStack(spacing: 3) {
            ForEach(Array(grid.nights.enumerated()), id: \.element.id) { c, night in
                let cell = Cell(night: night.id, member: member.id)
                let mark = grid.mark(night: night.id, member: member.id)
                let ring = ring(mark, cell)
                Button { select(cell) } label: {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(fill(mark))
                        .overlay(
                            RoundedRectangle(cornerRadius: 2.5)
                                .stroke(ring.color, lineWidth: ring.width)
                        )
                        .frame(minWidth: 4, maxWidth: 10)
                        .frame(height: 14)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(grid.cellSentence(night: night.id, member: member.id, now: now)))
                .accessibilityIdentifier("season-grid-mark-\(r)-\(c)")
            }
        }
    }

    private func select(_ cell: Cell) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
            selected = selected == cell ? nil : cell
        }
    }

    private func fill(_ mark: SeasonGrid.Mark) -> Color {
        switch mark {
        case .won: return Theme.Palette.gain
        case .lost: return Theme.Palette.loss
        case .even: return Theme.Palette.primaryText.opacity(0.3)
        case .satOut: return .clear
        }
    }

    /// Selection wins. Otherwise a sat-out night keeps a 1pt hairline
    /// on the same shape and size, so the slot reads as a night that
    /// was sat out rather than as a rendering gap.
    private func ring(_ mark: SeasonGrid.Mark, _ cell: Cell) -> (color: Color, width: CGFloat) {
        if selected == cell { return (Theme.Palette.primaryText, 1.5) }
        return mark == .satOut ? (Theme.Palette.hairline, 1) : (.clear, 0)
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}
