//
//  PackDefinition.swift
//  GamesRoom
//
//  Track P0.3 — the pack contract.
//
//  One source of truth for every supported games-night pack. Each
//  pack carries:
//
//    1. Stable metadata (slug, display name, description, icon, theme tint)
//    2. A scoring input shape (what the host submits at the table)
//    3. A score-computation contract (how the input resolves to one or
//       more `transactions` rows + a season-score delta per member)
//    4. A renderer hint (a SwiftUI view-id the host-side scoring
//       dashboard dispatches on)
//
//  The four V0.8 MVP packs — casino, cards_against_humanity,
//  monopoly_deal, pluto_chess — each conform. Legacy V0.7
//  `monopoly-deal` / `blackjack` rows from migration 012 are still
//  readable but the iOS picker only surfaces the four conformers.
//
//  All packs resolve through `PackRegistry.shared.definition(for: slug)`.
//  Server-side `public.packs` table is the authoritative availability
//  list (per migration 034), but the Swift definition is the
//  authoritative scoring contract — pack metadata drift between
//  server and client is caught by the `PackRegistry` round-trip
//  cases in the Foundation-only test runner (`main.swift`).
//
//

import Foundation

/// The contract every V0.8 pack implements. New packs ship by
/// adding a struct that conforms and registering it in
/// `PackRegistry.shared`; nothing else in the app should know the
/// concrete pack type.
protocol PackDefinition {
    /// Stable server-side slug (matches `public.packs.slug`).
    /// The slug is the canonical identifier — never display name —
    /// because two packs can share a display name across locales.
    static var slug: String { get }

    /// Human-readable name shown in the picker + on the pack shelf.
    static var displayName: String { get }

    /// One-line description shown in the pack shelf card.
    static var description: String { get }

    /// SF Symbol used for the pack shelf tile.
    static var iconSystemName: String { get }

    /// Scoring-type discriminator — drives the default points
    /// awarded by the host-side scoring dashboard. Mirrors
    /// `public.packs.scoring_type` from migration 012.
    static var scoringType: PackScoringType { get }

    /// V0.9 Wave 2 Slice 2.1 — slug used to look up how-to content
    /// in `PackHowToCatalog`. Defaults to `slug` so existing pack
    /// implementations get sensible behaviour without an override.
    /// A pack that wants a different lookup key (e.g. a localised
    /// how-to variant) can override.
    static var howToSlug: String { get }
}

extension PackDefinition {
    static var howToSlug: String { slug }
}

/// Discriminator from `public.packs.scoring_type`. Three V0.34
/// families are supported:
/// - `single_winner`: the round picks one member, awards
///   `winPoints` to that member's season score (Monopoly Deal,
///   Pluto Chess).
/// - `withdraw_return`: the round records a net delta per
///   member (Casino); the host enters each member's return
///   amount and the net delta is returned-to-balance minus
///   withdrawn.
/// - `count_based`: the round records a count of items held
///   (Cards Against Humanity — the winner keeps the black
///   card, and the score is the COUNT of black cards held at
///   session end). The host enters the number of cards the
///   winner takes per round (default 1).
enum PackScoringType: String, Codable, CaseIterable, Hashable {
    case singleWinner = "single_winner"
    case withdrawReturn = "withdraw_return"
    case countBased = "count_based"

    /// Human-readable scoring-family label for the picker + settings
    /// rows. One source of truth so PackDetailView, RoomSettingsSheet
    /// and the pack shelf all read the same string.
    var displayLabel: String {
        switch self {
        case .singleWinner:   return "Single winner"
        case .withdrawReturn: return "Withdraw & return"
        case .countBased:     return "Count-based"
        }
    }
}