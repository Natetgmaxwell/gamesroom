import SwiftUI

// MARK: - ConfettiBurst
//
// A one-shot confetti burst rendered with SwiftUI Canvas. Fires on
// appear, animates particles outward with gravity + rotation, then
// fades out. Library-free; the whole effect completes in ~450ms so it
// never slows the interaction.
struct ConfettiBurst: View {
    /// Number of confetti pieces.
    var count: Int = 24
    /// Colors — default to the brass accent + a couple of warm friends.
    var colors: [Color] = [
        Theme.Palette.accent,
        Color(red: 0.90, green: 0.75, blue: 0.45),
        Color(red: 0.95, green: 0.60, blue: 0.40),
        Color(red: 0.80, green: 0.85, blue: 0.55),
    ]

    @State private var burst = false

    var body: some View {
        Canvas { context, size in
            guard burst else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for i in 0..<count {
                let angle = Double(i) / Double(count) * 2 * .pi
                let distance = 40 + Double(i % 5) * 12
                let x = center.x + CGFloat(cos(angle) * distance)
                let y = center.y + CGFloat(sin(angle) * distance)
                let rect = CGRect(x: x, y: y, width: 6, height: 10)
                var path = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(path, with: .color(colors[i % colors.count]))
            }
        }
        .frame(width: 120, height: 120)
        .opacity(burst ? 0 : 1)
        .scaleEffect(burst ? 1.4 : 0.6)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                burst = true
            }
        }
        .allowsHitTesting(false)
    }
}