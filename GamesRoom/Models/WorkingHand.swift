//
//  WorkingHand.swift
//  GamesRoom
//
//  V0.51 per-member working-hand readout for active casino play.
//  Foundation only.
//

import Foundation

/// One room member's working hand + bank balance for an active
/// casino event.
///
/// Mirrors `public.get_event_working_hands(p_event_id)` (migration
/// 065). `workingHand` is the sum of the member's open
/// `casino_withdrawals` rows for the session — chips currently in
/// play, not yet returned to the bank. `pointsBalance` is the
/// member's current `room_memberships.points_balance` — the bank.
///
/// `Identifiable.id` keys off `memberId` so the SwiftUI `ForEach`
/// is stable per member. Snake-case `CodingKeys` mirror the RPC
/// return columns. `Int` decode for `workingHand` / `pointsBalance`
/// matches the `CasinoWithdrawal.pointsWithdrawn: Int` precedent
/// (the V0.27 spec caps the casino pack at 1,000-point bets so a
/// balance > 2^31 is out of scope).
struct WorkingHand: Codable, Identifiable, Hashable {
    let memberId: UUID
    let displayName: String
    let workingHand: Int
    let pointsBalance: Int

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case displayName = "display_name"
        case workingHand = "working_hand"
        case pointsBalance = "points_balance"
    }

    init(
        memberId: UUID,
        displayName: String,
        workingHand: Int,
        pointsBalance: Int
    ) {
        self.memberId = memberId
        self.displayName = displayName
        self.workingHand = workingHand
        self.pointsBalance = pointsBalance
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        workingHand = try c.decodeIfPresent(Int.self, forKey: .workingHand) ?? 0
        pointsBalance = try c.decodeIfPresent(Int.self, forKey: .pointsBalance) ?? 0
    }

    var id: UUID { memberId }
}
