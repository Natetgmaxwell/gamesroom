//
//  ChipSegmentationDetector.swift
//  GamesRoom
//
//  Track B model layer. Pure algorithm — Foundation + CoreGraphics
//  only (no Vision framework, no UI). The CoreGraphics import is the
//  one exception to the Models "Foundation only" convention: the
//  detector operates on CGImage.
//
//  F-CAS-02 LOCKED detector, ported from
//  Tools/CasinoVisionProbe/Sources/CasinoVisionProbe/ColorSegmentationDetector.swift.
//  Measured on the stress corpus: recall 0.975, precision 1.000,
//  color accuracy 0.974, zero pure-felt false positives. The
//  rectangle-detector approach it replaces was disqualified
//  (precision 0.394 — hallucinated 6-9 boxes on pure felt).
//
//  Pipeline (background-adaptive, not green-felt-only):
//  1. Estimate the table color from the frame border (median RGB of
//     a 4px strip).
//  2. Mask pixels whose RGB distance from the background >= 0.15.
//  3. Dilate the mask (3x3) so low-contrast black chips survive.
//  4. Connected-component labeling (4-connectivity, union-find).
//  5. Drop components below `minAreaFraction` of the frame.
//  6. Merge vertically-adjacent components into stacks.
//  7. Classify color (saturation-first: neutral chips split by
//     value); estimate count from stack height (~10px per chip).
//
//  Known weakness (carried from the probe): count MAE ~6 chips on
//  low-contrast stacks. The scan UI's editable counts are the
//  user-attestation fallback.
//
//  `minSaturation` is retained for API parity with the probe; the
//  background-adaptive mask superseded the saturation threshold.
//

import Foundation
import CoreGraphics

struct ChipSegmentationDetector {
    let minSaturation: Double
    let minAreaFraction: Double

    init(minSaturation: Double = 0.35, minAreaFraction: Double = 0.0008) {
        self.minSaturation = minSaturation
        self.minAreaFraction = minAreaFraction
    }

    /// Runs the segmentation pipeline on one frame and returns the
    /// detected chip stacks, sorted by confidence descending.
    /// `confidence` is normalized to [0, 1] as a frame-coverage
    /// proxy: `min(1, areaFraction * 20)` — a stack filling 5% of
    /// the frame reports 1.0.
    func detect(cg: CGImage) -> [DetectedStack] {
        let width = cg.width
        let height = cg.height

        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8

        // 1. Chip-likeness mask, background-adaptive.
        //
        // The original rule (bright / dark / non-green-hue) is tuned
        // to green felt and collapses on non-green tables (measured:
        // whole frame masks on dark-blue and burgundy felts — one
        // giant detection, recall 0.388). The general rule is
        // background-adaptive: estimate the table color from the
        // frame border, then mask pixels whose RGB distance from the
        // background exceeds a threshold. Chips differ from the
        // table; the table is one uniform color.
        let bg = estimateBackground(ptr: ptr, bpr: bpr, bpp: bpp, width: width, height: height)
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * bpp
                let r = Double(ptr[off]) / 255.0
                let g = Double(ptr[off + 1]) / 255.0
                let b = Double(ptr[off + 2]) / 255.0
                let dr = r - bg.r, dg = g - bg.g, db = b - bg.b
                let dist = (dr * dr + dg * dg + db * db).squareRoot()
                if dist >= 0.15 {
                    mask[y * width + x] = 1
                }
            }
        }

        // 1b. Dilate the mask (3x3).
        //
        // Black chips are low-contrast against dark felt: only the
        // thin dark rim passes the mask, and the rim alone is below
        // the min-area threshold. Dilation fills the chip body so the
        // component survives. It also bridges the per-chip bands.
        var dilated = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                guard mask[y * width + x] == 1 else { continue }
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        dilated[ny * width + nx] = 1
                    }
                }
            }
        }
        mask = dilated

        // 2. Connected components (4-connectivity, two-pass with
        // union-find to keep it simple and correct).
        let labels = connectedComponents(mask: mask, width: width, height: height)

        // 3. Aggregate per-component stats.
        var stats: [Int: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let l = labels[y * width + x]
                guard l > 0 else { continue }
                var s = stats[l] ?? (0, x, y, x, y)
                s.count += 1
                s.minX = min(s.minX, x)
                s.minY = min(s.minY, y)
                s.maxX = max(s.maxX, x)
                s.maxY = max(s.maxY, y)
                stats[l] = s
            }
        }

        let minArea = Int(Double(width * height) * minAreaFraction)
        var components: [(label: Int, stats: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int))] = []
        for (l, s) in stats where s.count >= minArea {
            components.append((l, s))
        }
        // Sort deterministically (top-to-bottom, left-to-right) before
        // merging. `stats` is a Dictionary; iterating it directly makes
        // merge order — and therefore stack grouping — vary per process
        // (Swift randomizes Dictionary order). Measured: recall
        // 0.963-0.975, precision 0.951-0.987 across runs of the same
        // binary on the same corpus.
        components.sort {
            if $0.stats.minY != $1.stats.minY { return $0.stats.minY < $1.stats.minY }
            return $0.stats.minX < $1.stats.minX
        }

        // 4. Merge components into stacks.
        //
        // A stack of N chips is N vertically-adjacent components (each
        // chip's center band is separated from its neighbours by the
        // dark rim). Components whose x-intervals overlap by > 50%
        // AND whose vertical gap is small belong to the same stack
        // column; merge them into one detection with the union
        // bounding box. The gap check keeps two separate stacks in
        // the same x-column from gluing together.
        var stackGroups: [[(label: Int, stats: (count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int))]] = []
        for comp in components {
            var mergedInto: Int? = nil
            for (gi, group) in stackGroups.enumerated() {
                let gx = group.reduce((minX: Int.max, maxX: Int.min)) {
                    (min($0.minX, $1.stats.minX), max($0.maxX, $1.stats.maxX))
                }
                let gy = group.reduce((minY: Int.max, maxY: Int.min)) {
                    (min($0.minY, $1.stats.minY), max($0.maxY, $1.stats.maxY))
                }
                let overlap = min(gx.maxX, comp.stats.maxX) - max(gx.minX, comp.stats.minX)
                let compW = comp.stats.maxX - comp.stats.minX
                let compH = comp.stats.maxY - comp.stats.minY
                let gap = comp.stats.minY > gy.maxY
                    ? comp.stats.minY - gy.maxY
                    : gy.minY - comp.stats.maxY
                if compW > 0
                    && Double(overlap) / Double(compW) > 0.5
                    && gap <= min(compH, 24) {
                    mergedInto = gi
                    break
                }
            }
            if let gi = mergedInto {
                stackGroups[gi].append(comp)
            } else {
                stackGroups.append([comp])
            }
        }

        var detections: [DetectedStack] = []
        for group in stackGroups {
            let minX = group.map(\.stats.minX).min()!
            let minY = group.map(\.stats.minY).min()!
            let maxX = group.map(\.stats.maxX).max()!
            let maxY = group.map(\.stats.maxY).max()!
            let boxW = Double(maxX - minX + 1) / Double(width)
            let boxH = Double(maxY - minY + 1) / Double(height)
            let x = Double(minX) / Double(width)
            let y = Double(minY) / Double(height)

            // 5. Color: area-weighted mean hue over the group.
            // White chips have low saturation, so their hue is
            // meaningless; classify by value first.
            var hueSum = 0.0
            var satSum = 0.0
            var valSum = 0.0
            var samples = 0
            for comp in group {
                for yy in comp.stats.minY...comp.stats.maxY {
                    for xx in comp.stats.minX...comp.stats.maxX {
                        guard labels[yy * width + xx] == comp.label else { continue }
                        let off = yy * bpr + xx * bpp
                        let r = Double(ptr[off]) / 255.0
                        let g = Double(ptr[off + 1]) / 255.0
                        let b = Double(ptr[off + 2]) / 255.0
                        let (hue, sat, value) = rgbToHsv(r: r, g: g, b: b)
                        hueSum += hue
                        satSum += sat
                        valSum += value
                        samples += 1
                    }
                }
            }
            let avgHue = samples > 0 ? hueSum / Double(samples) : 0
            let avgSat = samples > 0 ? satSum / Double(samples) : 0
            let avgVal = samples > 0 ? valSum / Double(samples) : 0
            let color: ChipColor
            if avgSat < 0.3 {
                // Neutral chip (black/white): saturation is too low
                // for hue to mean anything. Split by value.
                color = avgVal < 0.5 ? .black : .white
            } else {
                color = classifyHue(avgHue)
            }

            // 6. Count: stack height / chip thickness (~10px per chip
            // in a 1080p-class frame).
            let count = max(1, Int((boxH * Double(height) / 10.0).rounded()))

            let area = group.reduce(0) { $0 + $1.stats.count }
            let areaFraction = Double(area) / Double(width * height)
            detections.append(DetectedStack(
                seatIndex: nil,
                chipColor: color,
                count: count,
                confidence: min(1.0, areaFraction * 20),
                boundingBox: BoundingBox(x: x, y: y, w: boxW, h: boxH)
            ))
        }
        return detections.sorted { $0.confidence > $1.confidence }
    }

    /// Estimates the table/felt color from the frame border.
    ///
    /// The border of a chip photo is almost always table, not chips
    /// (stacks sit in the middle). Median RGB over a 4px border strip
    /// is robust to noise and to a stray chip touching the edge.
    private func estimateBackground(
        ptr: UnsafePointer<UInt8>, bpr: Int, bpp: Int, width: Int, height: Int
    ) -> (r: Double, g: Double, b: Double) {
        let border = 4
        var rs: [Double] = [], gs: [Double] = [], bs: [Double] = []
        rs.reserveCapacity((width + height) * border * 2)
        gs.reserveCapacity(rs.capacity)
        bs.reserveCapacity(rs.capacity)
        for y in 0..<height {
            for x in 0..<width {
                guard x < border || x >= width - border || y < border || y >= height - border else { continue }
                let off = y * bpr + x * bpp
                rs.append(Double(ptr[off]) / 255.0)
                gs.append(Double(ptr[off + 1]) / 255.0)
                bs.append(Double(ptr[off + 2]) / 255.0)
            }
        }
        rs.sort(); gs.sort(); bs.sort()
        let mid = rs.count / 2
        return (rs[mid], gs[mid], bs[mid])
    }

    /// Two-pass connected-component labeling with union-find.
    private func connectedComponents(mask: [UInt8], width: Int, height: Int) -> [Int] {
        var labels = [Int](repeating: 0, count: mask.count)
        var parent = [0] // dummy at index 0; parent[label] == label for roots
        var nextLabel = 1

        func find(_ a: Int) -> Int {
            var root = a
            while parent[root] != root { root = parent[root] }
            var cur = a
            while parent[cur] != cur {
                let nxt = parent[cur]
                parent[cur] = root
                cur = nxt
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                guard mask[idx] == 1 else { continue }
                let up = y > 0 ? labels[idx - width] : 0
                let left = x > 0 ? labels[idx - 1] : 0
                if up == 0 && left == 0 {
                    labels[idx] = nextLabel
                    parent.append(nextLabel)
                    nextLabel += 1
                } else if up != 0 && left == 0 {
                    labels[idx] = up
                } else if up == 0 && left != 0 {
                    labels[idx] = left
                } else {
                    labels[idx] = min(up, left)
                    union(up, left)
                }
            }
        }
        // Relabel through union-find roots.
        for i in 0..<labels.count where labels[i] > 0 {
            labels[i] = find(labels[i])
        }
        return labels
    }

    /// Hue band → chip color. The 0.08..<0.30 band (orange/yellow)
    /// is not a standard chip color in the app's set, so it maps to
    /// `.custom` (0 points) — the member sees it and can re-scan.
    private func classifyHue(_ hue: Double) -> ChipColor {
        switch hue {
        case 0..<0.08, 0.92...1.0: return .red
        case 0.08..<0.30: return .custom
        case 0.30..<0.50: return .green
        case 0.50..<0.72: return .blue
        case 0.72..<0.92: return .black
        default: return .custom
        }
    }
}

/// RGB (0-1) to HSV. Hue in [0,1), sat/val in [0,1].
private func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let d = maxC - minC
    var h: Double = 0
    if d != 0 {
        if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
    }
    let s = maxC == 0 ? 0 : d / maxC
    return (h, s, maxC)
}

/// F-CAS-02 v0.34 — low-confidence re-scan gate.
///
/// `confidence` is a frame-coverage proxy, so below 0.3 the stacks
/// occupy <1.5% of the frame and the height-based count estimate
/// is unreliable.
enum ScanConfidenceGate {
    static let rescanThreshold: Double = 0.3

    static func shouldPromptRescan(confidenceAvg: Double) -> Bool {
        confidenceAvg < rescanThreshold
    }
}
