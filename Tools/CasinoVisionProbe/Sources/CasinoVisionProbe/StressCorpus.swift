import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Harder synthetic corpus for stress-testing the segmentation detector.
///
/// The original synthetic corpus uses one felt color (mid-value green)
/// and 1-4 stacks. Real rooms vary: table color, lighting, stack
/// density. This generator produces:
///   - 4 felt variants (baseline green, dark blue, burgundy, light green)
///   - 2-6 stacks per frame, wider size range (40-140 px wide, 20-200 px tall)
///   - per-image lighting perturbation (brightness 0.7-1.15)
///   - 1 pure-felt adversarial frame (0 stacks) per felt variant
///
/// Ground truth is written in the same format as the original corpus
/// (`ground-truth.json` at the corpus root), so `run` works unchanged.
struct StressCorpusGenerator {
    let outputDir: URL
    let framesPerVariant: Int
    let size: (w: Int, h: Int)

    static let feltVariants: [(name: String, rgb: (r: CGFloat, g: CGFloat, b: CGFloat))] = [
        ("green", (0.10, 0.42, 0.18)),      // baseline (matches original corpus)
        ("darkblue", (0.08, 0.18, 0.45)),   // non-green felt
        ("burgundy", (0.42, 0.10, 0.10)),   // non-green felt
        ("lightgreen", (0.18, 0.55, 0.28)), // brighter green
    ]

    func generate() throws {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var truths: [ImageTruth] = []
        var index = 0

        for variant in Self.feltVariants {
            // framesPerVariant - 1 populated frames + 1 pure-felt frame.
            for frame in 0..<framesPerVariant {
                let isAdversarial = frame == framesPerVariant - 1
                let name = String(format: "stress-%02d.png", index)
                let url = outputDir.appendingPathComponent(name)
                let (image, stacks) = drawImage(
                    seed: index,
                    felt: variant.rgb,
                    lighting: isAdversarial ? 1.0 : 0.7 + 0.45 * Double(index % 7) / 6.0,
                    stackCount: isAdversarial ? 0 : 2 + Int((UInt64(index * 31 + 7) % 5))
                )
                try writePNG(image, to: url)
                truths.append(ImageTruth(image: name, stacks: stacks))
                index += 1
            }
        }

        let corpus = Corpus(images: truths)
        let data = try JSONEncoder().encode(corpus)
        try data.write(to: outputDir.appendingPathComponent("ground-truth.json"))
    }

    /// Draws one frame with a seeded RNG so runs are reproducible.
    private func drawImage(
        seed: Int,
        felt: (r: CGFloat, g: CGFloat, b: CGFloat),
        lighting: Double,
        stackCount: Int
    ) -> (CGImage, [StackTruth]) {
        var rng = SeededRNG(seed: UInt64(seed * 104729 + 17))
        let w = size.w, h = size.h

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("cannot create context") }

        // Felt background with lighting applied + heavier noise.
        let l = CGFloat(lighting)
        ctx.setFillColor(CGColor(
            red: min(1, felt.r * l), green: min(1, felt.g * l), blue: min(1, felt.b * l), alpha: 1
        ))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for _ in 0..<(w * h / 250) {
            let x = CGFloat(rng.next() % UInt64(w))
            let y = CGFloat(rng.next() % UInt64(h))
            let v = 0.06 + 0.06 * CGFloat(rng.next() % 100) / 100
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 0.18))
            ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
        }

        var truths: [StackTruth] = []
        var placed: [CGRect] = []

        for _ in 0..<stackCount {
            var rect: CGRect = .zero
            var attempts = 0
            repeat {
                let stackW = CGFloat(40 + Int(rng.next() % 100))
                let stackH = CGFloat(20 + Int(rng.next() % 180))
                let x = CGFloat(15 + Int(rng.next() % UInt64(max(1, w - 70))))
                let y = CGFloat(15 + Int(rng.next() % UInt64(max(1, h - 210))))
                rect = CGRect(x: x, y: y, width: stackW, height: stackH)
                attempts += 1
            } while attempts < 30 && placed.contains { $0.intersects(rect.insetBy(dx: -12, dy: -12)) }
            placed.append(rect)

            let color = SyntheticCorpusGenerator.chipColors[Int(rng.next() % UInt64(SyntheticCorpusGenerator.chipColors.count))]
            let chipCount = 1 + Int(rng.next() % 16)
            drawStack(ctx: ctx, rect: rect, color: color.rgb, chipCount: chipCount, lighting: l, rng: &rng)

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

    /// Same chip look as the original generator, with lighting applied.
    private func drawStack(
        ctx: CGContext,
        rect: CGRect,
        color: (r: CGFloat, g: CGFloat, b: CGFloat),
        chipCount: Int,
        lighting: CGFloat,
        rng: inout SeededRNG
    ) {
        let chipH = rect.height / CGFloat(chipCount)
        for i in 0..<chipCount {
            let y = rect.minY + CGFloat(i) * chipH
            let chipRect = CGRect(x: rect.minX, y: y, width: rect.width, height: chipH * 0.92)
            let rim = CGColor(
                red: min(1, color.r * lighting),
                green: min(1, color.g * lighting),
                blue: min(1, color.b * lighting),
                alpha: 1
            )
            let center = CGColor(
                red: min(1, (color.r + 0.25) * lighting),
                green: min(1, (color.g + 0.25) * lighting),
                blue: min(1, (color.b + 0.25) * lighting),
                alpha: 1
            )
            ctx.setFillColor(rim)
            ctx.fill(chipRect)
            let inset = chipRect.insetBy(dx: chipRect.width * 0.12, dy: chipRect.height * 0.15)
            ctx.setFillColor(center)
            ctx.fill(inset)
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
