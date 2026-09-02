//
//  MascotNotificationAttachment.swift
//  GamesRoom
//
//  V0.95 D — rich-notification identity for the room mascot.
//
//  Every notification the mascot speaks can carry its face: the
//  engine's FaceParameters are rendered to a PNG once (ImageRenderer,
//  same pattern as SeasonStatCard), cached on disk keyed by the
//  parameters, and attached to the UNNotificationRequest. iOS shows
//  the attachment as the notification's thumbnail on the lock screen
//  and full-width in the expanded banner.
//
//  Design notes:
//  - Cache key = SHA-256-ish stable hash of the deterministic
//    parameter inputs (personality, ideology, state). The engine is
//    a pure function, so identical inputs always produce identical
//    faces — one file per distinct room-state the member sees.
//  - Files live in Library/Caches: expendable by design. A cache
//    miss just re-renders (cheap, one small Canvas).
//  - All failures are non-fatal: the caller gets `nil` and the
//    notification ships text-only. A missing face must never block
//    a push.
//

import Foundation
import SwiftUI
import UserNotifications

enum MascotNotificationAttachment {

    /// Render size for the attachment PNG. Notifications show the
    /// thumbnail at ~40–60pt on most devices; 2× retina headroom on
    /// 124pt keeps the brow calligraphy legible in the expanded view.
    private static let renderSize: CGFloat = 124

    /// Renders the face and returns a notification attachment, or
    /// `nil` on any failure (text-only fallback). MainActor because
    /// `ImageRenderer` touches UI machinery.
    @MainActor
    static func attachment(
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        state: RoomState
    ) async -> UNNotificationAttachment? {
        let parameters = MascotFaceEngine.compute(
            personality: personality,
            ideology: ideology,
            state: state
        )
        guard let url = cachedFaceURL(for: parameters) ?? renderAndCache(parameters) else {
            return nil
        }
        return try? UNNotificationAttachment(
            identifier: "mascot-face",
            url: url,
            options: nil
        )
    }

    // MARK: - Cache

    private static var cacheDirectory: URL? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("MascotNotificationFaces", isDirectory: true)
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stable cache key: the enum raw values fully determine the
    /// render (the engine is a pure function of exactly these).
    private static func cacheKey(for parameters: FaceParameters) -> String {
        "\(parameters.personality.rawValue)-\(parameters.ideology.rawValue)-\(parameters.state.rawValue)"
    }

    private static func cachedFaceURL(for parameters: FaceParameters) -> URL? {
        guard let dir = cacheDirectory else { return nil }
        let url = dir.appendingPathComponent("\(cacheKey(for: parameters)).png")
        let exists = (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
        return exists ? url : nil
    }

    // MARK: - Render

    @MainActor
    private static func renderAndCache(_ parameters: FaceParameters) -> URL? {
        let view = MascotFaceView(parameters: parameters, size: renderSize)
        let renderer = ImageRenderer(content: view)
        renderer.scale = UIScreen.main.scale
        renderer.proposedSize = ProposedViewSize(width: renderSize, height: renderSize)
        guard let image = renderer.uiImage,
              let data = image.pngData() else {
            return nil
        }
        guard let dir = cacheDirectory else { return nil }
        let url = dir.appendingPathComponent("\(cacheKey(for: parameters)).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
