//
//  DetectedStack.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  V0.8 shape: replaces the pre-v0.8 CGRect boundingBox with the new
//  Foundation-pure BoundingBox type (x, y, w, h normalized to
//  [0,1]). Everything else mirrors the archive shape.
//

import Foundation

/// One detected chip stack inside a `VisionSnapshot`. Produced by
/// either the on-device rectangle detector or the hosted vision
/// API. The vision service is responsible for mapping the chip
/// color via the room's `CasinoConfig.chipColorMap` (or
/// `ChipColor.defaultValue` when `standardPresets == true`).
struct DetectedStack: Codable, Identifiable, Hashable {
    /// Which seat at the table this stack belongs to. `nil` when
    /// the vision provider couldn't associate the stack with a seat
    /// (typical for hosted-API output that doesn't know the room's
    /// seating layout).
    let seatIndex: Int?

    /// The detected chip color for this stack.
    let chipColor: ChipColor

    /// Estimated chip count for this stack. The points value is
    /// derived downstream via `CasinoConfig.value(for: chipColor) *
    /// count`.
    let count: Int

    /// Detector's self-reported confidence for this stack, in
    /// `[0, 1]`. The snapshot's `confidenceAvg` is the arithmetic
    /// mean of every stack's `confidence`.
    let confidence: Double

    /// Normalized bounding rectangle for this stack inside the
    /// captured frame. Foundation-pure (no CGRect) so this model
    /// can flow through services that don't link CoreGraphics.
    let boundingBox: BoundingBox

    /// Synthetic identity — `(seat, color, count)` is unique within
    /// one snapshot. Two snapshots with the same stack signature
    /// can coexist in a list and stay distinguishable in SwiftUI.
    var id: String { "\(seatIndex ?? -1)-\(chipColor.rawValue)-\(count)" }

    enum CodingKeys: String, CodingKey {
        case seatIndex = "seat_index"
        case chipColor = "chip_color"
        case count
        case confidence
        case boundingBox = "bounding_box"
    }

    init(
        seatIndex: Int?,
        chipColor: ChipColor,
        count: Int,
        confidence: Double,
        boundingBox: BoundingBox
    ) {
        self.seatIndex = seatIndex
        self.chipColor = chipColor
        self.count = count
        self.confidence = confidence
        self.boundingBox = boundingBox
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seatIndex = try c.decodeIfPresent(Int.self, forKey: .seatIndex)
        // Default the chip color to .custom rather than failing the
        // whole stack when the vision provider returns an unknown
        // label — the points value for .custom is 0 anyway, so the
        // snapshot totals stay sensible.
        let colorRaw = try c.decodeIfPresent(String.self, forKey: .chipColor) ?? ChipColor.custom.rawValue
        chipColor = ChipColor(rawValue: colorRaw) ?? .custom
        count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        boundingBox = try c.decodeIfPresent(BoundingBox.self, forKey: .boundingBox)
            ?? BoundingBox(x: 0, y: 0, w: 0, h: 0)
    }

    /// Points value for this stack under the supplied
    /// `CasinoConfig`. Convenience for the host screen's live
    /// preview, which sums this across the snapshot.
    func points(using config: CasinoConfig) -> Int {
        config.value(for: chipColor) * count
    }
}