//
//  EventTransaction.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  Promoted from CasinoService.swift (V0.73) so the Foundation-only
//  test harness (main.swift) can exercise the decode + dispensed
//  meta read without importing Supabase. Same shape as before; the
//  service file keeps AnyJSON.
//

import Foundation

/// One row from `public.transactions`, scoped to a single event.
///
/// Mirrors the `get_event_transactions(p_event_id)` RPC's return shape
/// (migration 024). Used by the host's live transactions board
/// (V0.30/V0.8), the past-event recap, and the host's "Chips to
/// dispense" section (V0.47+).
struct EventTransaction: Decodable, Identifiable, Hashable {
    let id: UUID
    let memberId: UUID
    let memberDisplayName: String
    let kind: String
    let amountPoints: Int64
    let meta: AnyJSON?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case memberId = "member_id"
        case memberDisplayName = "member_display_name"
        case kind
        case amountPoints = "amount_points"
        case meta
        case createdAt = "created_at"
    }

    init(
        id: UUID,
        memberId: UUID,
        memberDisplayName: String,
        kind: String,
        amountPoints: Int64,
        meta: AnyJSON? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.memberId = memberId
        self.memberDisplayName = memberDisplayName
        self.kind = kind
        self.amountPoints = amountPoints
        self.meta = meta
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        memberDisplayName = try c.decodeIfPresent(String.self, forKey: .memberDisplayName) ?? "Member"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        amountPoints = try c.decodeIfPresent(Int64.self, forKey: .amountPoints) ?? 0
        meta = try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }

    /// V0.73 — whether the host has acknowledged physically dispensing
    /// the chips for this withdrawal. Read from the transaction's
    /// `meta` (`{"dispensed": true}`, stamped server-side by
    /// `mark_withdrawal_dispensed`, migration 073). Replaces the
    /// client-only `dispensedWithdrawalIds` set that forgot every
    /// acknowledgement on app relaunch.
    var isDispensed: Bool {
        guard let meta,
              let dict = meta.value as? [String: Any],
              let flag = dict["dispensed"] as? Bool else { return false }
        return flag
    }
}
