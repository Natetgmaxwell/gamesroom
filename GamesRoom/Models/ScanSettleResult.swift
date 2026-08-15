//
//  ScanSettleResult.swift
//  GamesRoom
//
//  V0.72 slice 3 — response DTOs for the `scan-settle` edge function.
//
//  Top-level types (not nested inside ScanSettleService) so the
//  Foundation-only test runner can decode them without dragging the
//  service's URLSession + SupabaseClientProvider dependencies into
//  the test compile. The service uses these types directly (`submitChips`
//  returns `ChipsResult`, `submitCards` returns `CardsResult`).
//
//  All wire keys are snake_case; the Swift `CodingKeys` enum maps
//  each property. The edge function emits `{count, total_points,
//  stacks[{color,count}], photo_hash, attempt, attempts_remaining}`
//  for chips and `{count, photo_hash, attempt, attempts_remaining}`
//  for cards.
//

import Foundation

struct ScanSettleChipStack: Codable, Hashable {
    let color: String
    let count: Int
}

struct ScanSettleChipsResult: Codable, Hashable {
    let count: Int
    let totalPoints: Int
    let stacks: [ScanSettleChipStack]
    let photoHash: String
    let attempt: Int
    let attemptsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case count
        case totalPoints = "total_points"
        case stacks
        case photoHash = "photo_hash"
        case attempt
        case attemptsRemaining = "attempts_remaining"
    }
}

struct ScanSettleCardsResult: Codable, Hashable {
    let count: Int
    let photoHash: String
    let attempt: Int
    let attemptsRemaining: Int

    enum CodingKeys: String, CodingKey {
        case count
        case photoHash = "photo_hash"
        case attempt
        case attemptsRemaining = "attempts_remaining"
    }
}
