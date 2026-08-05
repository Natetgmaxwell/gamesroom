//
//  SeatDeposit.swift
//  GamesRoom
//
//  F-MVP-04 — seat deposit model. Pure data type. Foundation only.
//
//  One row per (event, user) when the room has a non-zero
//  seat_deposit_amount. Status transitions: held → refunded |
//  forfeited. Mirrors migration 043's public.seat_deposits.
//

import Foundation

struct SeatDeposit: Identifiable, Codable, Hashable {
    let id: UUID
    let amount: Int
    let status: Status
    let heldAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case status
        case heldAt = "held_at"
    }

    init(id: UUID, amount: Int, status: Status, heldAt: Date) {
        self.id = id
        self.amount = amount
        self.status = status
        self.heldAt = heldAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount) ?? 0
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "held"
        status = Status(rawValue: raw) ?? .held
        heldAt = try c.decodeIfPresent(Date.self, forKey: .heldAt) ?? Date()
    }

    enum Status: String, Codable, CaseIterable, Hashable {
        case held
        case refunded
        case forfeited

        var displayName: String {
            switch self {
            case .held:     return "Held"
            case .refunded: return "Refunded"
            case .forfeited: return "Forfeited"
            }
        }
    }

    var isResolved: Bool { status != .held }
}
