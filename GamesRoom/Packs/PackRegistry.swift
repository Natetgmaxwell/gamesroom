//
//  PackRegistry.swift
//  GamesRoom
//
//  Track P0.3 — pack registry.
//
//  Single source of truth for resolving `PackDefinition`s by slug.
//  The AddEventSheet picker reads `PackRegistry.shared.all`; the
//  scoring dashboard reads `PackRegistry.shared.definition(for:)`
//  to find the right policy when the host submits a round.
//
//  Adding a new pack requires:
//    1. A new struct in `Packs.swift` conforming to `PackDefinition`.
//    2. An entry in `PackRegistry.allPacks` below.
//    3. A row in `public.packs` (migration 034 or follow-up) so
//       the AddEventSheet picker can submit the slug.
//

import Foundation

/// Singleton registry. Not a true singleton (no `shared static`)
///
/// because tests construct their own — see `PackRegistryTests` —
/// but the production app uses `PackRegistry.shared` everywhere.
final class PackRegistry: @unchecked Sendable {

    /// The production registry instance. Pre-populated with the
    /// four V0.8 packs.
    static let shared = PackRegistry()

    /// Every pack registered for V0.8. Insertion order matches
    /// the picker display order in `AddEventSheet`.
    let allPacks: [any PackDefinition.Type]

    init(allPacks: [any PackDefinition.Type] = PackRegistry.defaultPacks) {
        self.allPacks = allPacks
    }

    /// The four V0.8 packs in picker order. New packs go in here.
    /// Mirrors the migration 034 seed ordering.
    static let defaultPacks: [any PackDefinition.Type] = [
        CasinoPack.self,
        CardsAgainstHumanityPack.self,
        MonopolyDealPack.self,
        PlutoChessPack.self
    ]

    /// Looks up a pack by slug. Returns `nil` if the slug doesn't
    /// match any registered pack — the caller should fall back to
    /// a neutral state (the AddEventSheet picker guarantees the
    /// slug is in this set, so `nil` only fires for legacy events
    /// with a `monopoly-deal` / `blackjack` slug).
    func definition(for slug: String) -> (any PackDefinition.Type)? {
        allPacks.first { $0.slug == slug }
    }

    /// True when the slug is one of the four registered V0.8
    /// packs. Used by the picker to refuse unknown slugs at
    /// submit time so the server doesn't error on `create_event`.
    func isRegistered(slug: String) -> Bool {
        definition(for: slug) != nil
    }

    /// Win-points lookup for single-winner packs. Returns `1` as a
    /// safe default for any pack without an explicit win-points
    /// field (the value is informational — the server is the
    /// source of truth).
    func winPoints(for slug: String) -> Int {
        switch slug {
        case CardsAgainstHumanityPack.slug: return CardsAgainstHumanityPack.winPoints
        case MonopolyDealPack.slug:         return MonopolyDealPack.winPoints
        case PlutoChessPack.slug:           return PlutoChessPack.winPoints
        case CasinoPack.slug:               return 0
        default:                            return 1
        }
    }
}