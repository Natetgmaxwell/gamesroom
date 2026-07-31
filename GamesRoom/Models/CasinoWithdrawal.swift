//
//  CasinoWithdrawal.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  Audit log row for the room's chip bank. Recorded every time a
//  member cashes out chips at the end of a session. Mirrors the
//  pre-v0.8 archive shape; V0.8 adds Hashable.
//

import Foundation

/// One chip-bank withdrawal event.
///
/// Mirrors `public.casino_withdrawals`. `withdrawnBy` is the host
/// who authorized the cash-out (usually the same as `memberId` for
/// self-withdrawals, but the bank can be drained on behalf of a
/// different member — e.g. when a member leaves mid-session and
/// the host cashes them out).
struct CasinoWithdrawal: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let memberId: UUID
    let pointsWithdrawn: Int
    let withdrawnAt: Date
    let withdrawnBy: UUID

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case memberId = "member_id"
        case pointsWithdrawn = "points_withdrawn"
        case withdrawnAt = "withdrawn_at"
        case withdrawnBy = "withdrawn_by"
    }

    init(
        id: UUID,
        sessionId: UUID,
        memberId: UUID,
        pointsWithdrawn: Int,
        withdrawnAt: Date,
        withdrawnBy: UUID
    ) {
        self.id = id
        self.sessionId = sessionId
        self.memberId = memberId
        self.pointsWithdrawn = pointsWithdrawn
        self.withdrawnAt = withdrawnAt
        self.withdrawnBy = withdrawnBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        pointsWithdrawn = try c.decodeIfPresent(Int.self, forKey: .pointsWithdrawn) ?? 0
        withdrawnAt = try c.decode(Date.self, forKey: .withdrawnAt)
        withdrawnBy = try c.decode(UUID.self, forKey: .withdrawnBy)
    }

    /// Whether the host authorized this withdrawal on behalf of a
    /// different member (e.g. a member who already left). Drives
    /// the audit-log icon in the Room History view.
    var isOnBehalfOf: Bool { withdrawnBy != memberId }
}