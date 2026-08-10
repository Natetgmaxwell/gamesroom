import Foundation

/// CLI entry point for the casino vision probe.
///
/// Usage:
///   CasinoVisionProbe generate <output-dir> [image-count] [width] [height]
///       Generates a synthetic chip-stack corpus + ground truth.
///   CasinoVisionProbe run <corpus-dir> [confidence-threshold]
///       Runs the on-device detector over the corpus and prints a report.
///   CasinoVisionProbe run <corpus-dir> --json <out.json> [confidence-threshold]
///       Same, but writes the machine-readable report to a file.
///   CasinoVisionProbe scan <photo-dir> [--detector segmentation|rectangles]
///       Runs the detector over a folder of photos with no ground
///       truth — prints what it sees per image. For eyeballing real
///       photos before annotating a corpus.
///
/// Exit code 0 = probe completed (regardless of verdict); 1 = usage or
/// pipeline error. The verdict is in the report, not the exit code.
@main
struct CasinoVisionProbe {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        switch args[1] {
        case "generate":
            guard args.count >= 3 else {
                print("error: generate requires an output directory")
                printUsage()
                exit(1)
            }
            let outDir = URL(fileURLWithPath: args[2])
            let count = args.count > 3 ? Int(args[3]) ?? 10 : 10
            let width = args.count > 4 ? Int(args[4]) ?? 1080 : 1080
            let height = args.count > 5 ? Int(args[5]) ?? 1080 : 1080
            do {
                try SyntheticCorpusGenerator(
                    outputDir: outDir, imageCount: count, size: (width, height)
                ).generate()
                print("generated \(count) synthetic images in \(outDir.path)")
            } catch {
                print("error: \(error)")
                exit(1)
            }

        case "stress":
            guard args.count >= 3 else {
                print("error: stress requires an output directory")
                printUsage()
                exit(1)
            }
            let outDir = URL(fileURLWithPath: args[2])
            let frames = args.count > 3 ? Int(args[3]) ?? 6 : 6
            let width = args.count > 4 ? Int(args[4]) ?? 1080 : 1080
            let height = args.count > 5 ? Int(args[5]) ?? 1080 : 1080
            do {
                try StressCorpusGenerator(
                    outputDir: outDir, framesPerVariant: frames, size: (width, height)
                ).generate()
                print("generated stress corpus (\(StressCorpusGenerator.feltVariants.count) felt variants x \(frames) frames) in \(outDir.path)")
            } catch {
                print("error: \(error)")
                exit(1)
            }

        case "run":
            guard args.count >= 3 else {
                print("error: run requires a corpus directory")
                printUsage()
                exit(1)
            }
            let corpusDir = URL(fileURLWithPath: args[2])
            var jsonOut: URL? = nil
            var threshold = 0.3
            var detectorName = "rectangles"
            var rest = Array(args.dropFirst(3))
            if let i = rest.firstIndex(of: "--json"), i + 1 < rest.count {
                jsonOut = URL(fileURLWithPath: rest[i + 1])
                rest.removeSubrange(i...(i + 1))
            }
            if let i = rest.firstIndex(of: "--detector"), i + 1 < rest.count {
                detectorName = rest[i + 1]
                rest.removeSubrange(i...(i + 1))
            }
            if let t = rest.first, let parsed = Double(t) {
                threshold = parsed
            }
            do {
                let corpus = try loadCorpus(from: corpusDir)
                let files = imageFiles(in: corpusDir)
                var detections: [String: [Detection]] = [:]
                for f in files {
                    detections[f.lastPathComponent] = try detect(
                        url: f, detectorName: detectorName, threshold: threshold
                    )
                }
                var report = Metrics.compute(
                    corpus: corpus,
                    detectionsByImage: detections,
                    confidenceThreshold: detectorName == "rectangles" ? threshold : 0.0
                )
                report.corpusDir = corpusDir.path

                if let out = jsonOut {
                    let data = try JSONEncoder().encode(report)
                    try data.write(to: out)
                    print("report written to \(out.path)")
                }
                printReport(report)
            } catch {
                print("error: \(error)")
                exit(1)
            }

        case "debug":
            guard args.count >= 3 else {
                print("error: debug requires an image path")
                printUsage()
                exit(1)
            }
            let url = URL(fileURLWithPath: args[2])
            var threshold = 0.3
            var detectorName = "rectangles"
            var rest = Array(args.dropFirst(3))
            if let i = rest.firstIndex(of: "--detector"), i + 1 < rest.count {
                detectorName = rest[i + 1]
                rest.removeSubrange(i...(i + 1))
            }
            if let t = rest.first, let parsed = Double(t) {
                threshold = parsed
            }
            do {
                let dets = try detect(url: url, detectorName: detectorName, threshold: threshold)
                print("detected \(dets.count) rectangles:")
                for d in dets {
                    print(String(
                        format: "  x=%.3f y=%.3f w=%.3f h=%.3f color=%@ count=%d conf=%.3f",
                        d.x, d.y, d.w, d.h, d.color, d.count, d.confidence
                    ))
                }
                // If the image lives in a corpus dir, print its truth.
                let dir = url.deletingLastPathComponent()
                if let corpus = try? loadCorpus(from: dir),
                   let truth = corpus.images.first(where: { $0.image == url.lastPathComponent }) {
                    print("truth \(truth.stacks.count) stacks:")
                    for t in truth.stacks {
                        print(String(
                            format: "  x=%.3f y=%.3f w=%.3f h=%.3f color=%@ count=%d",
                            t.x, t.y, t.w, t.h, t.color, t.count
                        ))
                    }
                }
            } catch {
                print("error: \(error)")
                exit(1)
            }

        case "scan":
            guard args.count >= 3 else {
                print("error: scan requires a photo directory")
                printUsage()
                exit(1)
            }
            let photoDir = URL(fileURLWithPath: args[2])
            var detectorName = "segmentation"
            var rest = Array(args.dropFirst(3))
            if let i = rest.firstIndex(of: "--detector"), i + 1 < rest.count {
                detectorName = rest[i + 1]
                rest.removeSubrange(i...(i + 1))
            }
            let files = imageFiles(in: photoDir)
            guard !files.isEmpty else {
                print("error: no images (png/jpg/jpeg/heic) in \(photoDir.path)")
                exit(1)
            }
            print("scanning \(files.count) images with \(detectorName) detector:")
            for f in files {
                do {
                    let dets = try detect(url: f, detectorName: detectorName, threshold: 0.3)
                    print("  \(f.lastPathComponent): \(dets.count) stack(s)")
                    for d in dets {
                        print(String(
                            format: "    x=%.3f y=%.3f w=%.3f h=%.3f color=%@ count=%d conf=%.3f",
                            d.x, d.y, d.w, d.h, d.color, d.count, d.confidence
                        ))
                    }
                } catch {
                    print("  \(f.lastPathComponent): error: \(error)")
                }
            }

        default:
            print("error: unknown command '\(args[1])'")
            printUsage()
            exit(1)
        }
    }

    static func printUsage() {
        print("""
        Usage:
          CasinoVisionProbe generate <output-dir> [image-count] [width] [height]
          CasinoVisionProbe stress <output-dir> [frames-per-variant] [width] [height]
          CasinoVisionProbe run <corpus-dir> [--detector rectangles|segmentation] [--json <out.json>] [confidence-threshold]
          CasinoVisionProbe scan <photo-dir> [--detector rectangles|segmentation]
          CasinoVisionProbe debug <image-path> [--detector rectangles|segmentation] [confidence-threshold]
        """)
    }

    /// Runs the selected detector variant on one image.
    static func detect(url: URL, detectorName: String, threshold: Double) throws -> [Detection] {
        switch detectorName {
        case "segmentation":
            return try ColorSegmentationDetector().detect(url: url)
        default:
            return try OnDeviceDetector(minimumConfidence: Float(threshold)).detect(url: url)
        }
    }

    static func printReport(_ r: ProbeReport) {
        print("""

        ============================================
        CASINO VISION PROBE REPORT
        ============================================
        corpus:        \(r.corpusDir)
        images:        \(r.imageCount)  (truth stacks: \(r.totalTruthStacks))
        detections:    \(r.totalDetected)  (TP \(r.truePositives) / FP \(r.falsePositives) / FN \(r.falseNegatives))
        recall:        \(String(format: "%.3f", r.recall))
        precision:     \(String(format: "%.3f", r.precision))
        color accuracy:\(String(format: "%.3f", r.colorAccuracy))
        count MAE:     \(String(format: "%.2f", r.countMAE)) chips
        mean IoU:      \(String(format: "%.3f", r.meanIoU))
        avg confidence:\(String(format: "%.3f", r.avgConfidence))
        verdict:       \(r.verdict)
        ============================================
        """)
        for img in r.perImage {
            print(String(
                format: "  %@  truth=%d det=%d TP=%d FP=%d FN=%d color=%.2f countMAE=%.2f IoU=%.2f conf=%.2f",
                img.image, img.truthStacks, img.detectedStacks, img.truePositives,
                img.falsePositives, img.falseNegatives, img.colorAccuracy,
                img.countMAE, img.iou, img.avgConfidence
            ))
        }
    }
}
