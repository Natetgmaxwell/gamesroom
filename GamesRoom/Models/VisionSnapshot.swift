//
//  VisionSnapshot.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  One frame's worth of vision detection output. Mirrors the
//  pre-v0.8 archive shape, except the inner `DetectedStack` now
//  uses the new BoundingBox instead of CGRect.
//

import Foundation

/// Output of one vision-pipeline run (on-device or hosted) on a
/// captured frame. Stored on `SettlementAttestation` snapshots and
/// sent as part of the per-member `SettlementRequest` RPC.
///
/// `totalValue` is the pre-computed points sum across every
/// `stacks[i]` for the capture moment. `discarded` is set when
/// the pipeline decided the frame was unusable (too dark, motion
/// blur, no detected stacks) and the host should re-capture.
struct VisionSnapshot: Codable, Hashable {
    let stacks: [DetectedStack]
    let totalValue: Int
    let confidenceAvg: Double
    let discarded: Bool
    let photoHash: String?

    enum CodingKeys: String, CodingKey {
        case stacks
        case totalValue = "total_value"
        case confidenceAvg = "confidence_avg"
        case discarded
        case photoHash = "photo_hash"
    }

    init(
        stacks: [DetectedStack],
        totalValue: Int,
        confidenceAvg: Double,
        discarded: Bool,
        photoHash: String? = nil
    ) {
        self.stacks = stacks
        self.totalValue = totalValue
        self.confidenceAvg = confidenceAvg
        self.discarded = discarded
        self.photoHash = photoHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stacks = try c.decodeIfPresent([DetectedStack].self, forKey: .stacks) ?? []
        totalValue = try c.decodeIfPresent(Int.self, forKey: .totalValue) ?? 0
        confidenceAvg = try c.decodeIfPresent(Double.self, forKey: .confidenceAvg) ?? 0
        discarded = try c.decodeIfPresent(Bool.self, forKey: .discarded) ?? false
        photoHash = try c.decodeIfPresent(String.self, forKey: .photoHash)
    }

    /// Whether the snapshot carries enough information to drive an
    /// auto-confirm in the UI. Equivalent to "not discarded AND has
    /// at least one detected stack AND confidence above a coarse
    /// threshold". The exact threshold is a UI policy; this is the
    /// structural predicate.
    var hasUsableSignal: Bool {
        !discarded && !stacks.isEmpty && confidenceAvg > 0
    }
}