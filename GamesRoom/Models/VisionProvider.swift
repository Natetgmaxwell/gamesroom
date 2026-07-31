//
//  VisionProvider.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  Split out from CasinoConfig.swift so the VisionProvider enum can
//  appear in services that don't need to load the rest of the
//  CasinoConfig shape.
//

import Foundation

/// Vision provider choice for a room's casino pack.
///
/// Two providers in V0.8. `.onDevice` is the default; `.hosted`
/// requires the per-room `visionApiKey` on `CasinoConfig`. The model
/// layer only carries the discriminator — provider behaviour lives in
/// the vision service.
enum VisionProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Local rectangle detection + hue heuristic. No network, no
    /// key. Lower accuracy.
    case onDevice = "on_device"

    /// Hosted vision API. Higher accuracy, ~2–5s latency, requires
    /// the per-room `visionApiKey`.
    case hosted = "hosted"

    /// Identifiable conformance for SwiftUI pickers (UI layer).
    /// No Foundation/UI dependencies live inside this property.
    var id: String { rawValue }

    /// Human-readable label for the host's Room Settings → Casino
    /// picker.
    var displayName: String {
        switch self {
        case .onDevice: return "On-device (default)"
        case .hosted:   return "Hosted vision API"
        }
    }
}
