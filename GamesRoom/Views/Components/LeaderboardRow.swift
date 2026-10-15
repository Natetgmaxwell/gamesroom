import SwiftUI

// MARK: - LeaderboardRow
//
// A single row of the standings board. Renders a rank (1–N), a member
// name, the current season score, last delta, and sessions played. Tapping
// the row expands it to reveal the trajectory sparkline behind it.
//
// The local-member's row is highlighted (`isYou`). T4's "see all" chevron is
// owned by the parent section, not by this row.
//
// Usage:
//     LeaderboardRow(
//         rank: 1,
//         name: "Thea",
//         score: 1240,
//         lastDelta: +80,
//         sessionsPlayed: 6,
//         trajectory: [-40, +20, +120, +80],
//         isYou: false
//     )
struct LeaderboardRow: View {
    let rank: Int
    let name: String
    let score: Int
    let lastDelta: Int
    let sessionsPlayed: Int
    let trajectory: [Int]
    let isYou: Bool
    let isRecentlyCorrected: Bool

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !trajectory.isEmpty else { return }
                    withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityHint(trajectory.isEmpty
                    ? Text("")
                    : Text(isExpanded ? "Tap to collapse trajectory." : "Tap to expand trajectory."))

            if isExpanded {
                TrajectorySparkline(values: trajectory)
                    .frame(height: 32)
                    .padding(.vertical, Theme.Layout.cardInset)
                    .accessibilityLabel(Text("Trajectory sparkline for \(name)"))
                    .accessibilityValue(Text(trajectoryAccessibilityDescription))
            }
        }
        .padding(.vertical, Theme.Layout.roomRowInset)
    }

    // MARK: Header subview

    private var header: some View {
        HStack(spacing: 12) {
            rankBadge
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(name)
                        .font(Theme.Typography.body.weight(isYou ? .semibold : .regular))
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                    if isRecentlyCorrected {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(Text("Score recently corrected"))
                            .transition(.opacity.combined(with: .scale))
                    }
                    if isYou {
                        Text("you")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                Text(sessionsPlayed == 1 ? "1 session" : "\(sessionsPlayed) sessions")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            scoreColumn
            chevron
        }
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(Theme.Typography.monoCaption)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            .frame(width: 24, alignment: .leading)
            .accessibilityLabel(Text("Rank \(rank)"))
    }

    private var scoreColumn: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // No night played yet means no last delta: a lone score
            // reads cleaner than a "0 0" pair.
            if sessionsPlayed > 0 {
                Text(deltaLabel)
                    .font(Theme.Typography.monoCaption)
                    .foregroundStyle(deltaColor)
            }
            Text("\(score)")
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.primaryText)
                .frame(minWidth: 72, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(sessionsPlayed > 0
            ? "\(score) points, last delta \(deltaLabel), \(sessionsPlayed) sessions"
            : "\(score) points, no sessions yet"))
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? Theme.Icon.chevronUp : Theme.Icon.chevronDown)
            .accessibilityHidden(true)
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            .frame(width: 16)
            // Nothing to expand before the first night; keep the
            // column so scores still line up across rows.
            .opacity(trajectory.isEmpty ? 0 : 1)
    }

    // MARK: Helpers

    private var deltaLabel: String {
        if lastDelta > 0 { return "+\(lastDelta)" }
        if lastDelta < 0 { return "−\(-lastDelta)" }
        return "0"
    }

    private var deltaColor: Color {
        if lastDelta > 0 { return Theme.Palette.gain }
        if lastDelta < 0 { return Theme.Palette.loss }
        return Theme.Palette.primaryText.opacity(0.4)
    }

    private var trajectoryAccessibilityDescription: String {
        guard !trajectory.isEmpty else { return "no data" }
        let joined = trajectory.map { ($0 >= 0 ? "+" : "") + String($0) }.joined(separator: ", ")
        return joined
    }
}

#if DEBUG
#Preview("Leaderboard rows") {
    VStack(spacing: 0) {
        LeaderboardRow(rank: 1, name: "Thea", score: 1240, lastDelta: 80, sessionsPlayed: 6, trajectory: [-40, 20, 120, 80], isYou: false, isRecentlyCorrected: false)
        Divider().overlay(Theme.Palette.hairline)
        LeaderboardRow(rank: 2, name: "You", score: 980, lastDelta: -20, sessionsPlayed: 5, trajectory: [60, -80, 100, -20], isYou: true, isRecentlyCorrected: true)
        Divider().overlay(Theme.Palette.hairline)
        LeaderboardRow(rank: 3, name: "Marco", score: 720, lastDelta: 0, sessionsPlayed: 4, trajectory: [10, 10, -20, 0], isYou: false, isRecentlyCorrected: false)
    }
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif