import SwiftUI

// MARK: - LeaderboardRow
//
// A single row of the standings board. Renders a rank badge (1–N), a member
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
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() } }
                .accessibilityElement(children: .combine)
                .accessibilityHint(Text(isExpanded ? "Tap to collapse trajectory." : "Tap to expand trajectory."))

            if isExpanded {
                Divider().overlay(Theme.Palette.hairline)
                TrajectorySparkline(values: trajectory)
                    .frame(height: 32)
                    .padding(.top, Theme.Layout.cardInset)
                    .padding(.bottom, Theme.Layout.cardInset)
                    .accessibilityLabel(Text("Trajectory sparkline for \(name)"))
                    .accessibilityValue(Text(trajectoryAccessibilityDescription))
            }
        }
        .padding(.vertical, 8)
        .background(isYou ? Theme.Palette.accent.opacity(0.06) : .clear)
        .overlay(alignment: .leading) {
            if isYou {
                Rectangle()
                    .fill(Theme.Palette.accent)
                    .frame(width: 2)
            }
        }
    }

    // MARK: Header subview

    private var header: some View {
        HStack(spacing: 12) {
            rankBadge
            Text(name)
                .font(Theme.Typography.body)
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
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Theme.Palette.accent, lineWidth: 0.5)
                    )
            }
            Spacer(minLength: 8)
            scoreColumn
            chevron
        }
        .padding(.horizontal, Theme.Layout.cardInset)
    }

    private var rankBadge: some View {
        Text("\(rank)")
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Palette.primaryText)
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(rank == 1 ? Theme.Palette.accent.opacity(0.18) : Theme.Palette.surface)
            )
            .overlay(
                Circle()
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .accessibilityLabel(Text("Rank \(rank)"))
    }

    private var scoreColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(score)")
                .font(Theme.Typography.body.monospacedDigit())
                .foregroundStyle(Theme.Palette.primaryText)
            HStack(spacing: 6) {
                Text(deltaLabel)
                    .font(Theme.Typography.footnote.monospacedDigit())
                    .foregroundStyle(deltaColor)
                Text("·")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                Text("\(sessionsPlayed) sessions")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(score) points, last delta \(deltaLabel), \(sessionsPlayed) sessions"))
    }

    private var chevron: some View {
        Image(systemName: isExpanded ? Theme.Icon.chevronUp : Theme.Icon.chevronDown)
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            .frame(width: 16)
    }

    // MARK: Helpers

    private var deltaLabel: String {
        let prefix = lastDelta > 0 ? "+" : ""
        return "\(prefix)\(lastDelta)"
    }

    private var deltaColor: Color {
        if lastDelta > 0 { return Theme.Palette.accent }
        if lastDelta < 0 { return Theme.Palette.primaryText.opacity(0.55) }
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