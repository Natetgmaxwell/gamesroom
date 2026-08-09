import Foundation

/// Per-image probe results.
struct ImageResult: Codable {
    let image: String
    let truthStacks: Int
    let detectedStacks: Int
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let colorAccuracy: Double   // correct color / matched detections
    let countMAE: Double        // mean absolute error in chip count
    let avgConfidence: Double
    let iou: Double             // mean IoU over matched detections
}

/// Aggregate probe report.
struct ProbeReport: Codable {
    let generatedAt: String
    var corpusDir: String
    let imageCount: Int
    let totalTruthStacks: Int
    let totalDetected: Int
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let recall: Double          // TP / (TP + FN)
    let precision: Double       // TP / (TP + FP)
    let colorAccuracy: Double
    let countMAE: Double
    let avgConfidence: Double
    let meanIoU: Double
    let perImage: [ImageResult]
    let verdict: String
}

/// Computes detection metrics against ground truth.
///
/// Matching: a detection matches a truth stack when their IoU >= 0.3
/// (the standard PASCAL VOC threshold). Each truth stack matches at
/// most one detection; unmatched detections are false positives.
struct Metrics {
    static func compute(
        corpus: Corpus,
        detectionsByImage: [String: [Detection]],
        confidenceThreshold: Double
    ) -> ProbeReport {
        var perImage: [ImageResult] = []
        var totalTP = 0, totalFP = 0, totalFN = 0
        var totalColorCorrect = 0, totalColorMatched = 0
        var totalCountError = 0.0, totalCountSamples = 0
        var totalConfidence = 0.0, totalConfidenceSamples = 0
        var totalIoU = 0.0, totalIoUSamples = 0

        for truth in corpus.images {
            let dets = (detectionsByImage[truth.image] ?? [])
                .filter { $0.confidence >= confidenceThreshold }

            var matched = Set<Int>()
            var tp = 0, fp = 0
            var colorCorrect = 0, colorMatched = 0
            var countError = 0.0, countSamples = 0
            var iouSum = 0.0, iouSamples = 0

            for det in dets {
                var bestIdx = -1
                var bestIoU = 0.3 // match threshold
                for (i, t) in truth.stacks.enumerated() where !matched.contains(i) {
                    let iou = intersectionOverUnion(det, t)
                    if iou >= bestIoU {
                        bestIoU = iou
                        bestIdx = i
                    }
                }
                if bestIdx >= 0 {
                    matched.insert(bestIdx)
                    tp += 1
                    let t = truth.stacks[bestIdx]
                    colorMatched += 1
                    if det.color == t.color { colorCorrect += 1 }
                    countError += abs(Double(det.count - t.count))
                    countSamples += 1
                    iouSum += bestIoU
                    iouSamples += 1
                } else {
                    fp += 1
                }
            }
            let fn = truth.stacks.count - matched.count

            totalTP += tp; totalFP += fp; totalFN += fn
            totalColorCorrect += colorCorrect; totalColorMatched += colorMatched
            totalCountError += countError; totalCountSamples += countSamples
            totalIoU += iouSum; totalIoUSamples += iouSamples
            for d in dets { totalConfidence += d.confidence; totalConfidenceSamples += 1 }

            perImage.append(ImageResult(
                image: truth.image,
                truthStacks: truth.stacks.count,
                detectedStacks: dets.count,
                truePositives: tp,
                falsePositives: fp,
                falseNegatives: fn,
                colorAccuracy: colorMatched > 0 ? Double(colorCorrect) / Double(colorMatched) : 0,
                countMAE: countSamples > 0 ? countError / Double(countSamples) : 0,
                avgConfidence: dets.isEmpty ? 0 : dets.map(\.confidence).reduce(0, +) / Double(dets.count),
                iou: iouSamples > 0 ? iouSum / Double(iouSamples) : 0
            ))
        }

        let recall = totalTP + totalFN > 0 ? Double(totalTP) / Double(totalTP + totalFN) : 0
        let precision = totalTP + totalFP > 0 ? Double(totalTP) / Double(totalTP + totalFP) : 0
        let colorAcc = totalColorMatched > 0 ? Double(totalColorCorrect) / Double(totalColorMatched) : 0
        let countMAE = totalCountSamples > 0 ? totalCountError / Double(totalCountSamples) : 0
        let avgConf = totalConfidenceSamples > 0 ? totalConfidence / Double(totalConfidenceSamples) : 0
        let meanIoU = totalIoUSamples > 0 ? totalIoU / Double(totalIoUSamples) : 0

        let verdict: String
        if recall >= 0.8 && precision >= 0.8 && colorAcc >= 0.8 {
            verdict = "PASS — on-device detection is shippable at this confidence threshold"
        } else if recall >= 0.5 || precision >= 0.5 {
            verdict = "PARTIAL — usable with user-attestation fallback; tune threshold or add hybrid"
        } else {
            verdict = "FAIL — on-device-only path is not viable; hybrid cloud-vision fallback required"
        }

        return ProbeReport(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            corpusDir: "",
            imageCount: corpus.images.count,
            totalTruthStacks: corpus.images.reduce(0) { $0 + $1.stacks.count },
            totalDetected: totalTP + totalFP,
            truePositives: totalTP,
            falsePositives: totalFP,
            falseNegatives: totalFN,
            recall: recall,
            precision: precision,
            colorAccuracy: colorAcc,
            countMAE: countMAE,
            avgConfidence: avgConf,
            meanIoU: meanIoU,
            perImage: perImage,
            verdict: verdict
        )
    }

    /// IoU between a detection and a truth stack (both normalized).
    static func intersectionOverUnion(_ d: Detection, _ t: StackTruth) -> Double {
        let ix = max(d.x, t.x)
        let iy = max(d.y, t.y)
        let iw = min(d.x + d.w, t.x + t.w) - ix
        let ih = min(d.y + d.h, t.y + t.h) - iy
        guard iw > 0, ih > 0 else { return 0 }
        let inter = iw * ih
        let union = d.w * d.h + t.w * t.h - inter
        return union > 0 ? inter / union : 0
    }

    /// IoU between two detections (for NMS).
    static func intersectionOverUnion(_ a: Detection, _ b: Detection) -> Double {
        let ix = max(a.x, b.x)
        let iy = max(a.y, b.y)
        let iw = min(a.x + a.w, b.x + b.w) - ix
        let ih = min(a.y + a.h, b.y + b.h) - iy
        guard iw > 0, ih > 0 else { return 0 }
        let inter = iw * ih
        let union = a.w * a.h + b.w * b.h - inter
        return union > 0 ? inter / union : 0
    }
}
