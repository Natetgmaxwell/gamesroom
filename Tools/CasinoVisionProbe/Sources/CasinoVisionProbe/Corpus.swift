import Foundation
import CoreGraphics
import ImageIO

/// Ground-truth annotation for one image in the probe corpus.
struct StackTruth: Codable {
    /// Normalized [0,1] bounding box of the stack.
    let x: Double, y: Double, w: Double, h: Double
    /// Expected chip color (red/blue/green/black/white).
    let color: String
    /// Expected number of chips in the stack.
    let count: Int
}

struct ImageTruth: Codable {
    let image: String
    let stacks: [StackTruth]
}

struct Corpus: Codable {
    let images: [ImageTruth]
}

/// One detection produced by the probe pipeline.
struct Detection {
    let x: Double, y: Double, w: Double, h: Double
    let color: String
    let count: Int
    let confidence: Double
}

/// Loads ground truth from a corpus directory. Looks for
/// `ground-truth.json` at the corpus root; falls back to per-image
/// `<name>.truth.json` sidecars when the root file is absent.
func loadCorpus(from dir: URL) throws -> Corpus {
    let rootTruth = dir.appendingPathComponent("ground-truth.json")
    if FileManager.default.fileExists(atPath: rootTruth.path) {
        let data = try Data(contentsOf: rootTruth)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }
    let fm = FileManager.default
    let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    var images: [ImageTruth] = []
    for f in files where f.pathExtension == "truth.json" {
        let data = try Data(contentsOf: f)
        let t = try JSONDecoder().decode(ImageTruth.self, from: data)
        images.append(t)
    }
    return Corpus(images: images)
}

/// Enumerates the image files in a corpus directory (png/jpg/jpeg/heic).
func imageFiles(in dir: URL) -> [URL] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    let exts: Set<String> = ["png", "jpg", "jpeg", "heic"]
    return files.filter { exts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}
