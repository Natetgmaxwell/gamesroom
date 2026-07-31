//
//  BoundingBox.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  Replaces CGRect in the V0.8 vision pipeline so the model layer
//  stays Foundation-pure (no CoreGraphics import). Coordinates are
//  normalized to the image's [0,1] square at capture time, so the
//  UI can map them onto any preview frame without rescaling.
//

import Foundation

/// Normalized axis-aligned rectangle from the vision pipeline.
///
/// Values are stored in the unit square `[0, 1] x [0, 1]`. `x` and
/// `y` are the top-left origin; `w` and `h` are width and height.
/// All four are `Double` so `Codable` round-trips JSON without
/// precision loss.
struct BoundingBox: Codable, Hashable {
    let x: Double
    let y: Double
    let w: Double
    let h: Double

    init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// Top-left corner as a point pair. Convenience for callers
    /// that want to render an overlay without doing the math.
    var minX: Double { x }
    var minY: Double { y }

    /// Width and height — re-exposed for the same reason as
    /// `minX`/`minY`; callers (especially the UI overlay) often
    /// reach for `.w`/`.h` directly.
    var width: Double { w }
    var height: Double { h }

    /// Right and bottom edges. Derived.
    var maxX: Double { x + w }
    var maxY: Double { y + h }

    /// Clamp the box into the unit square. Vision outputs
    /// occasionally spill a few pixels past the edge of the frame
    /// when chips touch the border; the UI overlay expects boxes
    /// inside `[0, 1]`.
    func clamped() -> BoundingBox {
        let nx = min(max(x, 0), 1)
        let ny = min(max(y, 0), 1)
        let nw = min(max(w, 0), 1 - nx)
        let nh = min(max(h, 0), 1 - ny)
        return BoundingBox(x: nx, y: ny, w: nw, h: nh)
    }
}