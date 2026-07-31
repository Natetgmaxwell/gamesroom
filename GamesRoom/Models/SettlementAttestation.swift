//
//  SettlementAttestation.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  The dispute-bearing row for one member's settlement. Mirrors
//  `public.settlement_attestations`. The `isFinal` flag is derived
//  from `closedAt != nil` so callers don't have to repeat the
//  null-check.
//

import Foundation

/// One member's settlement attestation for a session.
///
/// Lifecycle:
/// 1. `openedAt` is set when the host confirms the scan.
/// 2. `attestedAt` is set when the member taps "Yes, looks right"
///    on the Witness Screen.
/// 3. `closedAt` is set when the host finalizes the room — either
///    by accepting the attestation or by resolving a dispute.
///
/// `claimedAmountPoints` is the member's self-reported amount.
/// When `claimedAmountPoints != nil && claimedAmountPoints !=
/// visionAmountPoints`, the row is in a disputed state.
struct SettlementAttestation: Codable, Identifiable, Hashable {
    let id: UUID
    let sessionId: UUID
    let roomId: UUID
    let memberId: UUID
    let visionAmountPoints: Int64
    let claimedAmountPoints: Int64?
    let disputed: Bool
    let disputeReason: String?
    let detectionSource: String
    let confidenceAvg: Double?
    let openedAt: Date
    let attestedAt: Date?
    let closedAt: Date?

    /// `closedAt != nil`. Set after the host finalizes — the row is
    /// then immutable from the app's point of view (the audit log
    /// preserves it for posterity).
    var isFinal: Bool { closedAt != nil }

    /// `attestedAt != nil`. The member has tapped "Yes, looks
    /// right" on the Witness Screen, but the host has not yet
    /// finalized.
    var isAttested: Bool { attestedAt != nil && closedAt == nil }

    /// `openedAt` set but neither attested nor finalized. Pending
    /// member response on the Witness Screen.
    var isAwaitingMember: Bool { attestedAt == nil && closedAt == nil }

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case roomId = "room_id"
        case memberId = "member_id"
        case visionAmountPoints = "vision_amount_points"
        case claimedAmountPoints = "claimed_amount_points"
        case disputed
        case disputeReason = "dispute_reason"
        case detectionSource = "detection_source"
        case confidenceAvg = "confidence_avg"
        case openedAt = "opened_at"
        case attestedAt = "attested_at"
        case closedAt = "closed_at"
    }

    init(
        id: UUID,
        sessionId: UUID,
        roomId: UUID,
        memberId: UUID,
        visionAmountPoints: Int64,
        claimedAmountPoints: Int64? = nil,
        disputed: Bool = false,
        disputeReason: String? = nil,
        detectionSource: String = "on_device",
        confidenceAvg: Double? = nil,
        openedAt: Date,
        attestedAt: Date? = nil,
        closedAt: Date? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.roomId = roomId
        self.memberId = memberId
        self.visionAmountPoints = visionAmountPoints
        self.claimedAmountPoints = claimedAmountPoints
        self.disputed = disputed
        self.disputeReason = disputeReason
        self.detectionSource = detectionSource
        self.confidenceAvg = confidenceAvg
        self.openedAt = openedAt
        self.attestedAt = attestedAt
        self.closedAt = closedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        visionAmountPoints = try c.decode(Int64.self, forKey: .visionAmountPoints)
        claimedAmountPoints = try c.decodeIfPresent(Int64.self, forKey: .claimedAmountPoints)
        disputed = try c.decodeIfPresent(Bool.self, forKey: .disputed) ?? false
        disputeReason = try c.decodeIfPresent(String.self, forKey: .disputeReason)
        detectionSource = try c.decodeIfPresent(String.self, forKey: .detectionSource) ?? "on_device"
        confidenceAvg = try c.decodeIfPresent(Double.self, forKey: .confidenceAvg)
        openedAt = try c.decode(Date.self, forKey: .openedAt)
        attestedAt = try c.decodeIfPresent(Date.self, forKey: .attestedAt)
        closedAt = try c.decodeIfPresent(Date.self, forKey: .closedAt)
    }

    /// Effective P&L for this attestation. When the row is
    /// finalized and the member's claim differs from the vision
    /// amount, the resolved value is the `claimedAmountPoints` (the
    /// dispute's resolution). Otherwise it's the vision amount.
    var resolvedAmountPoints: Int64 {
        if let claimed = claimedAmountPoints, disputed { return claimed }
        return visionAmountPoints
    }
}