//
//  SettlementRequest.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  Input shape for the per-member scan RPC. Sent from the host's
//  Witness Screen when the host taps "Confirm vision" for a
//  member. The RPC writes a row into `public.session_scans` and
//  opens a `public.settlement_attestations` row in the same
//  transaction.
//

import Foundation

/// One member's settlement scan submission.
///
/// `visionAmountPoints` is the canonical value the host is
/// confirming (taken from `VisionSnapshot.totalValue` for
/// `.onDevice`/`.hosted` rows, or typed by hand for `.manual`
/// rows). `confidenceAvg` and `detectionSource` are echoed so the
/// downstream attestation row can be rendered with the same
/// confidence-aware treatment as the witness row.
///
/// `visionSnapshot` is optional — present for `.onDevice` and
/// `.hosted` sources, absent for `.manual` (hand-entered) rows.
struct SettlementRequest: Codable, Hashable {
    let sessionId: UUID
    let memberId: UUID
    let visionAmountPoints: Int64
    let visionSnapshot: VisionSnapshot?
    let confidenceAvg: Double?
    let detectionSource: DetectionSource

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case memberId = "member_id"
        case visionAmountPoints = "vision_amount_points"
        case visionSnapshot = "vision_snapshot"
        case confidenceAvg = "confidence_avg"
        case detectionSource = "detection_source"
    }

    init(
        sessionId: UUID,
        memberId: UUID,
        visionAmountPoints: Int64,
        visionSnapshot: VisionSnapshot? = nil,
        confidenceAvg: Double? = nil,
        detectionSource: DetectionSource
    ) {
        self.sessionId = sessionId
        self.memberId = memberId
        self.visionAmountPoints = visionAmountPoints
        self.visionSnapshot = visionSnapshot
        self.confidenceAvg = confidenceAvg
        self.detectionSource = detectionSource
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        visionAmountPoints = try c.decodeIfPresent(Int64.self, forKey: .visionAmountPoints) ?? 0
        visionSnapshot = try c.decodeIfPresent(VisionSnapshot.self, forKey: .visionSnapshot)
        confidenceAvg = try c.decodeIfPresent(Double.self, forKey: .confidenceAvg)
        let raw = try c.decodeIfPresent(String.self, forKey: .detectionSource)
            ?? DetectionSource.pending.rawValue
        detectionSource = DetectionSource(rawValue: raw) ?? .pending
    }

    /// Structural validation — returns `false` when the request is
    /// obviously malformed (negative points, `.pending` source,
    /// snapshot present for a non-vision source). The RPC layer
    /// does the authoritative check; this is for the UI to gate
    /// the "Confirm" button.
    var isStructurallyValid: Bool {
        guard visionAmountPoints >= 0 else { return false }
        guard detectionSource != .pending else { return false }
        if detectionSource == .manual { return true }
        return visionSnapshot != nil
    }
}