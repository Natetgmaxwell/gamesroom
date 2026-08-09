import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Generates a synthetic chip-stack corpus for pipeline smoke-testing.
///
/// Real photos are the gold standard (see README capture instructions),
/// but a synthetic corpus exercises the full pipeline — rectangle
/// detection, hue classification, count estimation — and catches
/// pipeline bugs before a human spends an hour photographing chips.
///
/// Each image draws 1-4 stacks of poker chips on a felt-like
/// background. Ground truth is written as `ground-truth.json` at the
/// corpus root.
struct SyntheticCorpusGenerator {
    let outputDir: URL
    let imageCount: Int
    let size: (w: Int, h: Int)

    static let chipColors: [(name: String, rgb: (r: CGFloat, g: CGFloat, b: CGFloat))] = [
        ("red", (0.80, 0.10, 0.10)),
        ("blue", (0.10, 0.20, 0.80)),
        ("green", (0.10, 0.60, 0.20)),
        ("black", (0.12, 0.12, 0.14)),
        ("white", (0.92, 0.92, 0.90)),
    ]

    func generate() throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var truths: [ImageTruth] = []

        for i in 0..<imageCount {
            let name = String(format: "synthetic-%02d.png", i)
            let url = outputDir.appendingPathComponent(name)
            let (image, stacks) = drawImage(seed: i)
            try writePNG(image, to: url)
            truths.append(ImageTruth(image: name, stacks: stacks))
        }

        let corpus = Corpus(images: truths)
        let data = try JSONEncoder().encode(corpus)
        try data.write(to: outputDir.appendingPathComponent("ground-truth.json"))
    }

    /// Draws one frame with a seeded RNG so runs are reproducible.
    private func drawImage(seed: Int) -> (CGImage, [StackTruth]) {
        var rng = SeededRNG(seed: UInt64(seed * 7919 + 13))
        let w = size.w, h = size.h

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("cannot create context") }

        // Felt background with slight noise.
        ctx.setFillColor(CGColor(red: 0.10, green: 0.42, blue: 0.18, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<(w * h / 400) {
            let x = CGFloat(rng.next() % UInt64(w))
            let y = CGFloat(rng.next() % UInt64(h))
            let v = 0.08 + 0.04 * CGFloat(rng.next() % 100) / 100
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 0.15))
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }

        let stackCount = 1 + Int(rng.next() % 4)
        var truths: [StackTruth] = []
        var placed: [CGRect] = []

        for _ in 0..<stackCount {
            // Try to place a stack without overlapping existing ones.
            var rect: CGRect = .zero
            var attempts = 0
            repeat {
                let stackW = CGFloat(60 + Int(rng.next() % 50))
                let stackH = CGFloat(30 + Int(rng.next() % 90))
                let x = CGFloat(20 + Int(rng.next() % UInt64(max(1, w - 80))))
                let y = CGFloat(20 + Int(rng.next() % UInt64(max(1, h - 120))))
                rect = CGRect(x: x, y: y, width: stackW, height: stackH)
                attempts += 1
            } while attempts < 20 && placed.contains { $0.intersects(rect.insetBy(dx: -20, dy: -20)) }
            placed.append(rect)

            let color = Self.chipColors[Int(rng.next() % UInt64(Self.chipColors.count))]
            let chipCount = 1 + Int(rng.next() % 12)
            drawStack(ctx: ctx, rect: rect, color: color.rgb, chipCount: chipCount, rng: &rng)

            truths.append(StackTruth(
                x: Double(rect.minX / CGFloat(w)),
                y: Double((CGFloat(h) - rect.maxY) / CGFloat(h)),
                w: Double(rect.width / CGFloat(w)),
                h: Double(rect.height / CGFloat(h)),
                color: color.name,
                count: chipCount
            ))
        }

        guard let image = ctx.makeImage() else { fatalError("cannot make image") }
        return (image, truths)
    }

    /// Draws a vertical stack of chips as stacked rounded rectangles
    /// with a colored rim and a lighter center (the classic chip look).
    private func drawStack(
        ctx: CGContext,
        rect: CGRect,
        color: (r: CGFloat, g: CGFloat, b: CGFloat),
        chipCount: Int,
        rng: inout SeededRNG
    ) {
        let chipH = rect.height / CGFloat(chipCount)
        for i in 0..<chipCount {
            let y = rect.minY + CGFloat(i) * chipH
            let chipRect = CGRect(x: rect.minX, y: y, width: rect.width, height: chipH * 0.92)
            let rim = CGColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
            let center = CGColor(
                red: min(1, color.r + 0.25),
                green: min(1, color.g + 0.25),
                blue: min(1, color.b + 0.25),
                alpha: 1
            )
            ctx.setFillColor(rim)
            ctx.fill(chipRect)
            let inset = chipRect.insetBy(dx: chipRect.width * 0.12, dy: chipRect.height * 0.15)
            ctx.setFillColor(center)
            ctx.fill(inset)
            // Edge highlight for depth.
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
            ctx.fill(CGRect(x: chipRect.minX, y: chipRect.minY, width: chipRect.width, height: 1.5))
        }
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ProbeError.cannotWriteImage(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ProbeError.cannotWriteImage(url.path)
        }
    }
}

/// Tiny deterministic RNG (xorshift) so corpus generation is
/// reproducible across runs.
struct SeededRNG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
