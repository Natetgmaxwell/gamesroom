import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Runs the on-device detection pipeline on one image:
/// 1. `VNDetectRectanglesRequest` finds candidate chip-stack regions.
/// 2. Each candidate is classified by dominant hue into a chip color.
/// 3. Stack height / chip thickness estimates the chip count.
///
/// This mirrors the intended on-device path in the app (Vision
/// framework rectangle detection + hue heuristic), so probe results
/// transfer to the real implementation.
struct OnDeviceDetector {
    let minimumConfidence: Float

    init(minimumConfidence: Float = 0.3) {
        self.minimumConfidence = minimumConfidence
    }

    /// Detects chip stacks in the image at `url`.
    /// Returns detections sorted by confidence, descending.
    func detect(url: URL) throws -> [Detection] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ProbeError.cannotLoadImage(url.path)
        }
        let width = cg.width
        let height = cg.height

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = minimumConfidence
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.05
        request.maximumObservations = 20

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([request])

        // Gate rectangle detections through attention saliency: chips
        // are salient objects, felt texture is not. This kills the
        // felt-hallucination failure mode of the raw rectangle
        // detector (measured: 9 FPs on a pure-felt frame).
        let salientBoxes = try salientRegions(cg: cg)

        let observations = (request.results ?? []).sorted {
            $0.confidence > $1.confidence
        }

        var detections: [Detection] = []
        for obs in observations {
            let box = obs.boundingBox // normalized, origin bottom-left
            let center = CGPoint(x: box.midX, y: box.midY)
            guard salientBoxes.contains(where: { $0.contains(center) }) else { continue }

            let x = Double(box.origin.x)
            let y = Double(1.0 - box.origin.y - box.size.height) // flip to top-left
            let w = Double(box.size.width)
            let h = Double(box.size.height)

            let color = classifyColor(in: cg, box: box)
            let count = estimateCount(boxHeight: box.size.height, imageHeight: height)

            detections.append(Detection(
                x: x, y: y, w: w, h: h,
                color: color,
                count: count,
                confidence: Double(obs.confidence)
            ))
        }
        return nonMaximumSuppression(detections)
    }

    /// Runs attention-based saliency and returns the salient regions
    /// in normalized bottom-left coordinates (same space as Vision
    /// rectangle boxes).
    private func salientRegions(cg: CGImage) throws -> [CGRect] {
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try handler.perform([saliency])
        guard let result = saliency.results?.first else { return [] }
        return result.salientObjects?.map(\.boundingBox) ?? []
    }

    /// Merges overlapping detections into single stack boxes.
    ///
    /// Raw `VNDetectRectanglesRequest` output over-detects on chip
    /// stacks: each chip's lighter center band is itself a rectangle,
    /// so one stack of N chips yields N overlapping boxes. Greedy NMS
    /// keeps the highest-confidence box per cluster and drops the
    /// rest (IoU >= 0.3 = same stack).
    private func nonMaximumSuppression(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for det in detections.sorted(by: { $0.confidence > $1.confidence }) {
            let overlaps = kept.contains { Metrics.intersectionOverUnion($0, det) >= 0.3 }
            if !overlaps {
                kept.append(det)
            }
        }
        return kept
    }

    /// Classifies the dominant chip color inside a detected rectangle
    /// by sampling the center region and averaging hue.
    private func classifyColor(in cg: CGImage, box: CGRect) -> String {
        let px = Int(box.midX * CGFloat(cg.width))
        let py = Int((1.0 - box.midY) * CGFloat(cg.height))
        let sampleW = max(8, Int(box.width * CGFloat(cg.width) * 0.4))
        let sampleH = max(8, Int(box.height * CGFloat(cg.height) * 0.4))

        guard let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return "unknown" }

        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        let bpc = cg.bitsPerComponent

        var totalHue: Double = 0
        var totalSat: Double = 0
        var samples = 0

        for dy in 0..<sampleH {
            for dx in 0..<sampleW {
                let x = min(max(px - sampleW / 2 + dx, 0), cg.width - 1)
                let y = min(max(py - sampleH / 2 + dy, 0), cg.height - 1)
                let off = y * bpr + x * bpp
                let r: Double, g: Double, b: Double
                if bpc == 16 {
                    r = Double(ptr[off]) / 255.0
                    g = Double(ptr[off + 1]) / 255.0
                    b = Double(ptr[off + 2]) / 255.0
                } else {
                    r = Double(ptr[off]) / 255.0
                    g = Double(ptr[off + 1]) / 255.0
                    b = Double(ptr[off + 2]) / 255.0
                }
                let (hue, sat, _) = rgbToHsv(r: r, g: g, b: b)
                totalHue += hue
                totalSat += sat
                samples += 1
            }
        }
        guard samples > 0 else { return "unknown" }
        let avgHue = totalHue / Double(samples)
        let avgSat = totalSat / Double(samples)

        if avgSat < 0.12 { return "white" }
        switch avgHue {
        case 0..<0.08, 0.92...1.0: return "red"
        case 0.08..<0.30: return "yellow" // not a standard chip color; keep for diagnostics
        case 0.30..<0.50: return "green"
        case 0.50..<0.72: return "blue"
        case 0.72..<0.92: return "black"
        default: return "unknown"
        }
    }

    /// Estimates chip count from the detected rectangle's height.
    /// Assumes a chip is ~3.3mm thick and the stack is photographed
    /// roughly head-on; the count is height / chipThickness in
    /// normalized units scaled by image height.
    private func estimateCount(boxHeight: CGFloat, imageHeight: Int) -> Int {
        let pxHeight = boxHeight * CGFloat(imageHeight)
        // A single chip is typically 8-12 px tall in a 1080p frame
        // when the stack fills a reasonable portion of the frame.
        let chipPx: CGFloat = 10
        return max(1, Int((pxHeight / chipPx).rounded()))
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case cannotLoadImage(String)
    case cannotWriteImage(String)

    var description: String {
        switch self {
        case .cannotLoadImage(let p): return "cannot load image: \(p)"
        case .cannotWriteImage(let p): return "cannot write image: \(p)"
        }
    }
}

/// RGB (0-1) to HSV. Hue in [0,1), sat/val in [0,1].
func rgbToHsv(r: Double, g: Double, b: Double) -> (h: Double, s: Double, v: Double) {
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
