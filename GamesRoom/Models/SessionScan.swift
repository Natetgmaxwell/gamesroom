//
//  SessionScan.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Per-member scan row inside one session. Populated either by
/// on-device vision, by the hosted vision API (per `CasinoConfig`),
/// or by the member tapping "I didn't scan" (a default = no P&L).
///
/// The detection source drives the UI's confidence-aware treatment
/// of the row — high-confidence on-device rows render unconditionally;
/// low-confidence hosted rows open the V0.29 dispute surface.
struct SessionScan: Identifiable, Codable, Hashable {
    let memberId: UUID
    let memberDisplayName: String

    /// Vision-derived points for this member in this session. May be
    /// 0 if the member defaulted (didn't scan) and the host made
    /// them whole.
    let visionAmountPoints: Int64

    /// Source of the `visionAmountPoints` value. The string form is
    /// persisted by the database for forward-compat with new vision
    /// providers (e.g. ".onDevice" / ".minimaxVision" / ".manual").
    let detectionSource: DetectionSource

    /// Optional. Average confidence across all detected stacks in
    /// this scan. `nil` when `detectionSource == .manual`.
    let confidenceAvg: Double?

    /// Whether the member declined to scan entirely. When `true`,
    /// their net P&L is 0 for this session.
    let didNotScan: Bool

    /// When the scan (or default) was recorded. `nil` only on
    /// legacy rows.
    let recordedAt: Date?

    /// When the session settled (i.e. the host finalized). `nil`
    /// until settlement.
    let finalizedAt: Date?

    /// `memberId` is the stable identity within the session scope.
    var id: UUID { memberId }

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case memberDisplayName = "member_display_name"
        case visionAmountPoints = "vision_amount_points"
        case detectionSource = "detection_source"
        case confidenceAvg = "confidence_avg"
        case didNotScan = "did_not_scan"
        case recordedAt = "recorded_at"
        case finalizedAt = "finalized_at"
    }

    init(
        memberId: UUID,
        memberDisplayName: String,
        visionAmountPoints: Int64,
        detectionSource: DetectionSource,
        confidenceAvg: Double? = nil,
        didNotScan: Bool = false,
        recordedAt: Date? = nil,
        finalizedAt: Date? = nil
    ) {
        self.memberId = memberId
        self.memberDisplayName = memberDisplayName
        self.visionAmountPoints = visionAmountPoints
        self.detectionSource = detectionSource
        self.confidenceAvg = confidenceAvg
        self.didNotScan = didNotScan
        self.recordedAt = recordedAt
        self.finalizedAt = finalizedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        memberDisplayName = try c.decodeIfPresent(String.self, forKey: .memberDisplayName) ?? "Member"
        visionAmountPoints = try c.decodeIfPresent(Int64.self, forKey: .visionAmountPoints) ?? 0
        let raw = try c.decodeIfPresent(String.self, forKey: .detectionSource) ?? DetectionSource.pending.rawValue
        detectionSource = DetectionSource(rawValue: raw) ?? .pending
        confidenceAvg = try c.decodeIfPresent(Double.self, forKey: .confidenceAvg)
        didNotScan = try c.decodeIfPresent(Bool.self, forKey: .didNotScan) ?? false
        recordedAt = try c.decodeIfPresent(Date.self, forKey: .recordedAt)
        finalizedAt = try c.decodeIfPresent(Date.self, forKey: .finalizedAt)
    }

    /// Member has not yet recorded a scan (and is not defaulted).
    /// Used by the UI to render a pending slot in the per-member
    /// attest row on the Witness Screen.
    var isPending: Bool { detectionSource == .pending && !didNotScan }

    /// Member was finalized at 0 P&L (didn't scan). Used by the UI
    /// to render the muted "sat out" indicator.
    var isDefaulted: Bool { didNotScan }
}
