import SwiftUI

// MARK: - MascotBubble
//
// The mascot footer caption. Per the v0.8 brief, the mascot voice is a
// one-line italic 13pt caption under the active CTA — never the lead.
// Tapping it opens the existing deep-dive `MascotBubble` sheet (not a state
// change). This view renders the caption; the sheet is owned by the parent
// page.
//
// The caption uses a real `Button` (per the a11y regression noted in
// `MascotFooterView.swift:52-53`); it replaces the legacy `onTapGesture`.
//
// Usage:
//     MascotBubble(text: "Thea eyes the door. Two seats open.")
//         .onTap { showDeepDive = true }
struct MascotBubble: View {
    let text: String
    let onTap: (() -> Void)?

    init(text: String, onTap: (() -> Void)? = nil) {
        self.text = text
        self.onTap = onTap
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) {
                    caption
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mascot says: \(text)"))
                .accessibilityHint(Text("Tap to open the mascot deep-dive."))
            } else {
                caption
            }
        }
    }

    private var caption: some View {
        Text(text)
            .font(Theme.Typography.caption)
            .italic()
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.78))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if DEBUG
#Preview("Caption, tappable") {
    VStack(spacing: 24) {
        MascotBubble(text: "Thea eyes the door. Two seats open.")
        MascotBubble(text: "Quiet rooms are quiet.", onTap: { })
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif