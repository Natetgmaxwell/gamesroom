import SwiftUI

// MARK: - TrajectorySparkline
//
// A 32pt-tall mini line chart over an array of deltas (one per past session,
// newest on the right). No axes, no labels — just the shape of the arc.
//
// The stroke is `Theme.Palette.accent` (the single brass-warm voice). The
// baseline (zero delta) is `Theme.Palette.hairline`. Positive values draw
// above the baseline; negative below.
//
// Usage:
//     TrajectorySparkline(values: [-40, 20, 120, 80])
//         .frame(width: 200)
struct TrajectorySparkline: View {
    let values: [Int]

    /// The fixed visual height. Width is provided by the parent.
    private let height: CGFloat = 32

    init(values: [Int]) {
        self.values = values
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Baseline
                Path { path in
                    let y = geo.size.height / 2
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
                .stroke(Theme.Palette.hairline, style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))

                // Trajectory line + fill
                if values.count >= 2 {
                    trajectoryPath(in: geo.size)
                        .stroke(
                            Theme.Palette.accent,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                } else if values.count == 1 {
                    // Single point: render as a small tick on the baseline.
                    Circle()
                        .fill(Theme.Palette.accent)
                        .frame(width: 4, height: 4)
                        .position(
                            x: geo.size.width / 2,
                            y: geo.size.height / 2 + yOffset(for: values[0], in: geo.size.height)
                        )
                }
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("Trajectory sparkline"))
        .accessibilityValue(Text(sparklineAccessibilityDescription))
    }

    // MARK: Path construction

    private func trajectoryPath(in size: CGSize) -> Path {
        Path { path in
            let stepX = size.width / CGFloat(max(values.count - 1, 1))
            let midY = size.height / 2
            let maxAbs = max(values.map(abs).max() ?? 1, 1)
            let amplitude = (size.height / 2) - 2  // 2pt padding from edges

            for (index, value) in values.enumerated() {
                let x = CGFloat(index) * stepX
                let normalized = CGFloat(value) / CGFloat(maxAbs)
                let y = midY - (normalized * amplitude)

                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
    }

    private func yOffset(for value: Int, in height: CGFloat) -> CGFloat {
        let maxAbs = max(abs(value), 1)
        let amplitude = (height / 2) - 2
        let normalized = CGFloat(value) / CGFloat(maxAbs)
        return -normalized * amplitude
    }

    // MARK: A11y

    private var sparklineAccessibilityDescription: String {
        guard !values.isEmpty else { return "no data" }
        let joined = values.map { ($0 >= 0 ? "+" : "") + String($0) }.joined(separator: ", ")
        return joined
    }
}

#if DEBUG
#Preview("Sparklines") {
    VStack(alignment: .leading, spacing: 16) {
        TrajectorySparkline(values: [-40, 20, 120, 80])
            .frame(width: 200)
        TrajectorySparkline(values: [60, -80, 100, -20, 40])
            .frame(width: 200)
        TrajectorySparkline(values: [10])
            .frame(width: 200)
        TrajectorySparkline(values: [])
            .frame(width: 200)
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif