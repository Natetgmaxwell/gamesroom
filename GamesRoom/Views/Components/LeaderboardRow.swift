import SwiftUI

/// One row of the season leaderboard.
///
/// The default view is name + score + last-delta, intentionally quiet
/// so the active event card can be the visual hero. Tapping a row
/// expands it inline to show the trajectory sparkline — the at-a-glance
/// "how am I trending" surface for the masked-autistic / 2e target user.
struct LeaderboardRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let isSelf: Bool
    /// Live event affordance: when set and `isSelf`, the row shows
    /// a "Withdraw" button tied to the user's current points balance.
    /// Only host-or-self in an active casino event should set this.
    var withdrawAction: (() -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var isExpanded: Bool = false

    private var contentPadding: CGFloat { 16 }

    private var scoreLabel: String? {
        // Empty string → don't render. "—" is for "played but zeroed
        // out" (rare). No sessions and no score = no character at all,
        // so the row doesn't carry decorative em-dashes that read as
        // "AI generated placeholder."
        if entry.seasonScore == 0 && entry.sessionsPlayed == 0 { return nil }
        if entry.seasonScore == 0 { return "0" }
        return "\(entry.seasonScore)"
    }

    private var lastDeltaLabel: String? {
        guard entry.sessionsPlayed > 0 else { return nil }
        let prefix = entry.lastSessionDelta >= 0 ? "+" : ""
        return "\(prefix)\(entry.lastSessionDelta)"
    }

    private var lastDeltaColor: Color {
        if entry.lastSessionDelta > 0 { return .green }
        if entry.lastSessionDelta < 0 { return .red.opacity(0.85) }
        return Theme.secondaryText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                rankBadge

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.displayName)
                            .font(.system(size: 15, weight: isSelf ? .semibold : .regular))
                            .foregroundStyle(isSelf ? Theme.accent : Theme.primaryText)
                        if isSelf {
                            Text("you")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    if let label = lastDeltaLabel {
                        HStack(spacing: 4) {
                            Text("Last: \(label)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(lastDeltaColor)
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                            Text("\(entry.sessionsPlayed) session\(entry.sessionsPlayed == 1 ? "" : "s")")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    } else {
                        Text("No sessions yet")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let scoreLabel {
                        Text(scoreLabel)
                            .font(.system(size: 17, weight: .regular, design: .serif))
                            .foregroundStyle(isSelf ? Theme.accent : Theme.primaryText)
                    }
                    if entry.pointsBalance > 0 {
                        Text("\(entry.pointsBalance) pts")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .frame(minWidth: 48, alignment: .trailing)

                if let withdrawAction, isSelf {
                    Button("Withdraw", action: withdrawAction)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, contentPadding)
            .contentShape(Rectangle())
            .onTapGesture { isExpanded.toggle() }

            if isExpanded {
                TrajectorySparkline(deltas: entry.trajectory.map { $0.delta })
                    .frame(height: 32)
                    .padding(.horizontal, contentPadding)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Theme.accent)
                    .frame(width: 3)
                Color.clear
            }
            .opacity(isSelf ? 1.0 : 0.0)
        )
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    @ViewBuilder
    private var rankBadge: some View {
        if entry.isHost {
            // Host floats at the top by convention, but doesn't compete
            // in the ranking. A small HOST chip replaces the placeholder
            // em-dash that previously flanked every empty row.
            RoleBadge(role: .host)
        } else if entry.sessionsPlayed == 0 && entry.seasonScore == 0 {
            // Brand-new member, hasn't played. Leave the rank slot
            // empty rather than rendering a typographic ornament.
            Color.clear.frame(width: 22)
        } else if rank == 1 {
            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.15))
                    .frame(width: 22, height: 22)
                Text("1")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.accent)
            }
        } else {
            Text("\(rank)")
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 22)
        }
    }
}
