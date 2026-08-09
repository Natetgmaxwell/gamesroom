import Foundation
import CoreGraphics
import ImageIO

/// Color-segmentation-first detector.
///
/// The naive `VNDetectRectanglesRequest` approach hallucinates on
/// textured felt (measured: 6-9 FPs on a pure-felt frame). The
/// classical robust approach for chip stacks is the inverse: segment
/// saturated pixels first (chips are saturated, felt is not), find
/// connected components, then classify each component by dominant hue.
///
/// Pipeline:
/// 1. Downsample the image (speed).
/// 2. Threshold pixels by saturation (>= `minSaturation`).
/// 3. Connected-component labeling on the saturated mask.
/// 4. Drop components smaller than `minAreaFraction` of the frame.
/// 5. Each surviving component = one stack candidate.
/// 6. Classify color by mean hue; estimate count by component height.
struct ColorSegmentationDetector {
    let minSaturation: Double
    let minAreaFraction: Double

    init(minSaturation: Double = 0.35, minAreaFraction: Double = 0.0008) {
        self.minSaturation = minSaturation
        self.minAreaFraction = minAreaFraction
    }

    func detect(url: URL) throws -> [Detection] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProbeError.cannotLoadImage(url.path)
        }
        return detect(cg: cg)
    }

    func detect(cg: CGImage) -> [Detection] {
        let width = cg.width
        let height = cg.height

        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return [] }
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8

        // 1. Chip-likeness mask.
        //
        // Saturation alone cannot separate chips from felt: green
        // felt is itself highly saturated (measured sat ~0.76 on the
        // synthetic felt). The working rule is value + hue:
        //   - bright pixels (value >= 0.55): white/red/blue chips
        //   - dark pixels (value <= 0.25): black chips
        //   - non-green hues (hue outside [0.25, 0.45]): red/blue
        //     chips even at mid value
        // Felt (mid-value green) fails all three.
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bpr + x * bpp
                let r = Double(ptr[off]) / 255.0
                let g = Double(ptr[off + 1]) / 255.0
                let b = Double(ptr[off + 2]) / 255.0
                let (hue, _, value) = rgbToHsv(r: r, g: g, b: b)
                let isBright = value >= 0.55
                let isDark = value <= 0.25
                let isNonGreenHue = hue < 0.25 || hue > 0.45
                if isBright || isDark || isNonGreenHue {
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

        // 2. Merge components into stacks.
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

        var detections: [Detection] = []
        for group in stackGroups {
            let minX = group.map(\.stats.minX).min()!
            let minY = group.map(\.stats.minY).min()!
            let maxX = group.map(\.stats.maxX).max()!
            let maxY = group.map(\.stats.maxY).max()!
            let boxW = Double(maxX - minX + 1) / Double(width)
            let boxH = Double(maxY - minY + 1) / Double(height)
            let x = Double(minX) / Double(width)
            let y = Double(minY) / Double(height)

            // 3. Color: area-weighted mean hue over the group.
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
            let color: String
            if avgSat < 0.3 {
                // Neutral chip (black/white): saturation is too low
                // for hue to mean anything. Split by value.
                color = avgVal < 0.5 ? "black" : "white"
            } else {
                color = classifyHue(avgHue)
            }

            // 4. Count: stack height / chip thickness.
            let count = max(1, Int((boxH * Double(height) / 10.0).rounded()))

            let area = group.reduce(0) { $0 + $1.stats.count }
            detections.append(Detection(
                x: x, y: y, w: boxW, h: boxH,
                color: color,
                count: count,
                confidence: Double(area) / Double(width * height) * 100
            ))
        }
        return detections.sorted { $0.confidence > $1.confidence }
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

    private func classifyHue(_ hue: Double) -> String {
        switch hue {
        case 0..<0.08, 0.92...1.0: return "red"
        case 0.08..<0.30: return "yellow"
        case 0.30..<0.50: return "green"
        case 0.50..<0.72: return "blue"
        case 0.72..<0.92: return "black"
        default: return "unknown"
        }
    }
}
