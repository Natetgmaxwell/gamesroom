//
//  MascotTypography.swift
//  GamesRoom
//
//  V0.99c — ideology → typography mapping for the mascot footer caption.
//  Extends the V0.94 invariant (voice and face agree) to a third channel:
//  voice, face, AND typeface agree. One mapping, one place — views never
//  branch on ideology for fonts themselves.
//
//  Satirical register only, per V0.82: archetypes, never real-world
//  advocacy. The farRight/altRight cells are deliberately typographically
//  BORING — the joke is that their "aesthetic" is unworthy of one. No
//  blackletter, no militaristic display faces, nothing to aestheticise.
//

import Foundation
import SwiftUI

enum MascotTypography {

    /// The transformed caption text (some ideologies mutate the string)
    /// and the font it renders in. `TextStyle` pairs the two so a call
    /// site is always `Text(result.text).font(result.font)`.
    struct TextStyle {
        let text: String
        let font: Font
    }

    /// Ideology → caption typography. The mapping IS the joke.
    static func caption(for ideology: MascotPoliticalIdeology, base: Font = Theme.Typography.caption) -> TextStyle {
        switch ideology {
        case .conservative:
            // Cursive italic — proper penmanship, letters raised right.
            return TextStyle(text: "", font: Theme.Typography.monoItalic)

        case .communist:
            // Maple Mono Regular, no italic — every glyph receives the
            // same width. Radical equality of letterforms. Seize the
            // means of proportion.
            return TextStyle(text: "", font: Theme.Typography.monoCaption)

        case .anarchist:
            // Maple Mono + alternating-case scramble. No authority over
            // capitalisation. Text transform applied by the caller via
            // `transformedText`.
            return TextStyle(text: "", font: Theme.Typography.monoCaption)

        case .apocalypse:
            // SemiBold ALL CAPS — shouting into the void, order-shaped panic.
            return TextStyle(text: "", font: Theme.Typography.monoCaptionSemibold)

        case .order:
            // Maple Mono Regular, no italic — disciplined, upright, on the grid.
            return TextStyle(text: "", font: Theme.Typography.monoCaption)

        case .centrist:
            // SF Pro italic — the status quo, unchanged from V0.36.
            return TextStyle(text: "", font: base.italic())

        case .trickster:
            // Maple Mono italic + scramble — chaos, but *stylish* chaos.
            // The trickster scrambles letters AND borrows the fancy
            // handwriting. Caller applies transformedText for the scramble.
            return TextStyle(text: "", font: Theme.Typography.monoItalic)

        case .apolitical:
            // SF Pro regular — no opinions, not even about letterforms.
            return TextStyle(text: "", font: base)

        case .liberal:
            // SF Pro italic with the standard look — polite, mainstream,
            // indistinguishable from the default at a glance. That IS the joke.
            return TextStyle(text: "", font: base.italic())

        case .farRight, .altRight:
            // Deliberately boring: plain SF Pro, no italic, no costume.
            // Typographic monotony as satire — nothing here is worth
            // decorating. (V0.82: satirical archetypes, never advocacy.)
            return TextStyle(text: "", font: base)
        }
    }

    /// String transforms for ideologies that mutate the caption text.
    /// Returns `text` unchanged when the ideology doesn't transform.
    static func transformedText(_ text: String, for ideology: MascotPoliticalIdeology) -> String {
        switch ideology {
        case .anarchist, .trickster:
            return Self.alternatingCase(text)
        case .apocalypse:
            return text.uppercased()
        default:
            return text
        }
    }

    /// Alternating-case scramble. Deterministic (seeded by character
    /// index, not random) so the same caption always renders the same
    /// way — no flicker across re-renders. Alphanumeric letters only;
    /// punctuation and spacing untouched.
    static func alternatingCase(_ text: String) -> String {
        var letterIndex = 0
        return String(text.map { ch -> Character in
            guard ch.isLetter else { return ch }
            let out = letterIndex.isMultiple(of: 2) ? Character(ch.lowercased()) : Character(ch.uppercased())
            letterIndex += 1
            return out
        })
    }
}
