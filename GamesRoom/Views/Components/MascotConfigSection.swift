//
//  MascotConfigSection.swift
//  GamesRoom
//
//  V0.94 slice C — Host mascot configurator.
//
//  The reusable character-builder row that hosts use to pick a
//  mascot's personality + political ideology AND see the resulting
//  face live. Used by `CreateRoomSheet` (new rooms) and
//  `RoomSettingsSocialSheet` (existing-room edits).
//
//  Hard invariants (V0.94 spec):
//    1. Async surfaces only — this view is a SwiftUI form section,
//       never imported by an in-play view.
//    2. The live preview is rendered by `MascotFaceView`, the same
//       vector renderer the footer / briefing / recap surfaces use.
//       Picking is therefore WYSIWYG with every other surface.
//    3. The "Reset to default Tally" affordance snaps the picker
//       back to the **default Tally face**: personality=.professional,
//       ideology=.apolitical, idle emotion. This is the V0.94 spec's
//       "off mask" and the agreed adjustable / turn-off knob
//       (Connor 2026-08-31).
//
//  Usage:
//
//      MascotConfigSection(
//          name: $mascotName,
//          personality: $mascotPersonality,
//          ideology: $mascotIdeology
//      )
//

import SwiftUI

struct MascotConfigSection: View {

    @Binding var name: String
    @Binding var personality: MascotPersonality
    @Binding var ideology: MascotPoliticalIdeology

    /// Render size for the live preview chip. 120pt gives the brow
    /// calligraphy enough room to read without crowding the form.
    private static let previewSize: CGFloat = 120

    /// The "default Tally" face per the V0.94 spec — `.professional`
    /// personality, `.apolitical` ideology, idle room state.
    private static let defaultPersonality: MascotPersonality = .professional
    private static let defaultIdeology: MascotPoliticalIdeology = .apolitical
    private static let defaultName: String = "Tally"

    /// Whether the current picker state is the default-Tally face.
    /// Drives whether the Reset button is disabled.
    private var isAtDefaultTally: Bool {
        personality == Self.defaultPersonality
            && ideology == Self.defaultIdeology
            && name.trimmingCharacters(in: .whitespacesAndNewlines)
                == Self.defaultName
    }

    var body: some View {
        Section {
            VStack(spacing: 12) {
                MascotFaceView(
                    parameters: MascotFaceEngine.compute(
                        personality: personality,
                        ideology: ideology,
                        state: .idle
                    ),
                    size: Self.previewSize
                )
                .accessibilityLabel(Text(
                    "Preview: \(personality.displayName) mascot, "
                    + "\(ideology.displayName) ideology"
                ))

                Text("\(personality.displayName) · \(ideology.displayName)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.6))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

            TextField(
                "Mascot name",
                text: $name,
                prompt: Text(Self.defaultName)
            )

            Picker("Personality", selection: $personality) {
                ForEach(MascotPersonality.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }

            Picker("Politics", selection: $ideology) {
                ForEach(MascotPoliticalIdeology.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }

            Button {
                name = Self.defaultName
                personality = Self.defaultPersonality
                ideology = Self.defaultIdeology
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset to default Tally")
                }
                .font(Theme.Typography.body)
            }
            .disabled(isAtDefaultTally)
        } header: {
            Text("Mascot")
        } footer: {
            Text("The mascot narrates recaps and surfaces briefings. Pick a face — or reset to the default Tally.")
        }
    }
}

#if DEBUG
#Preview("Builder — apolitical default") {
    Form {
        MascotConfigSection(
            name: .constant("Tally"),
            personality: .constant(.professional),
            ideology: .constant(.apolitical)
        )
    }
    .scrollContentBackground(.hidden)
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("Builder — customised") {
    Form {
        MascotConfigSection(
            name: .constant("Scratch"),
            personality: .constant(.snarky),
            ideology: .constant(.trickster)
        )
    }
    .scrollContentBackground(.hidden)
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif
