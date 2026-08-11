//
//  Packs.swift
//  GamesRoom
//
//  Track P0.3 — the four V0.8 pack definitions.
//
//  Each pack is a frozen value-type conforming to `PackDefinition`.
//  The picker in `AddEventSheet` reads from `PackRegistry.shared`,
//  which holds one of each. The host-side scoring dashboard
//  dispatches on `scoringType` to pick the right input form.
//
//  Slugs MUST match `public.packs.slug` exactly (per migration 034
//  seed). The displayName / description mirror what migration 034
//  inserts so the server-side `packs` table and the iOS picker
//  agree byte-for-byte.
//

import Foundation

// MARK: - Casino

/// V0.8 Casino pack. `withdraw_return` scoring type — each member
/// withdraws chips to start the round and returns their winnings
/// at the end; the net delta is recorded per member. The V0.7.1
/// host-batched model was replaced in V0.8 with the per-member
/// scan flow (migration 030); the V0.8 picker still classifies
/// the pack as `casino` so legacy events keep FK-resolving.
struct CasinoPack: PackDefinition {
    static let slug = "casino"
    static let displayName = "Casino"
    static let description = "Chip-based casino games. Each player withdraws to start, returns winnings at end."
    static let iconSystemName = "circle.hexagongrid.fill"
    static let scoringType: PackScoringType = .withdrawReturn

    /// Default starting withdrawal per member (mirrors
    /// `public.packs.withdraw_default` per migration 034).
    static let withdrawDefault: Int = 10
}

// MARK: - Cards Against Humanity

/// V0.34 Cards Against Humanity pack. `count_based` scoring type —
/// the round's judge picks one winner who takes the black card; the
/// score is the COUNT of black cards held at session end. The host
/// enters the number of cards the winner takes per round (default 1)
/// and the member tallies their own stack at session end via the
/// vision card-counting flow (CAHCardScanSheet).
///
/// `winPoints` stays at 1 — it's the default cards-per-round value;
/// the host can step the per-round count up via the host-side scoring
/// sheet. The RoomRegistry's `winPoints(for:)` lookup continues to
/// return this default.
struct CardsAgainstHumanityPack: PackDefinition {
    static let slug = "cards_against_humanity"
    static let displayName = "Cards Against Humanity"
    static let description = "Card-judging party game. The judge's pick wins the round and keeps the black card — score is cards won."
    static let iconSystemName = "rectangle.stack.fill"
    static let scoringType: PackScoringType = .countBased

    /// Default cards per round (mirrors migration 034's win_points).
    /// Per-round count can be adjusted by the host at scoring time.
    static let winPoints: Int = 1
}

// MARK: - Monopoly Deal

/// V0.8 Monopoly Deal pack. `single_winner` scoring type — winner
/// of the round takes the pot. Note: the *legacy* V0.7 pack was
/// `monopoly-deal` (hyphen); V0.8 deliberately uses the underscore
/// form (per migration 034) so the picker stop selecting the
/// non-conforming slug.
struct MonopolyDealPack: PackDefinition {
    static let slug = "monopoly_deal"
    static let displayName = "Monopoly Deal"
    static let description = "Card-based Monopoly. Winner takes the pot."
    static let iconSystemName = "creditcard.fill"
    static let scoringType: PackScoringType = .singleWinner

    /// One win-point per round.
    static let winPoints: Int = 1
}

// MARK: - Pluto Chess

/// V0.8 Pluto Chess pack. `single_winner` scoring type — winner of
/// the game earns one point.
struct PlutoChessPack: PackDefinition {
    static let slug = "pluto_chess"
    static let displayName = "Pluto Chess"
    static let description = "Chess-variant pack."
    static let iconSystemName = "crown.fill"
    static let scoringType: PackScoringType = .singleWinner

    /// One win-point per round.
    static let winPoints: Int = 1
}