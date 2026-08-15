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
/// Two providers. `.onDevice` is the legacy local rectangle detection
/// + hue heuristic. `.hosted` is the V0.72 authoritative hosted
/// vision model — runs server-side via the `scan-settle` edge
/// function (slice 2); no client key, no per-room `visionApiKey`.
/// The model layer only carries the discriminator — provider
/// behaviour lives in the vision service.
enum VisionProvider: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Local rectangle detection + hue heuristic. No network, no
    /// key. Lower accuracy.
    case onDevice = "on_device"

    /// Hosted vision model. The DB value is the canonical
    /// `casino_room_config.vision_provider = 'minimax_vision'`
    /// string (migration 027 + 069). The count is authoritative —
    /// members see the result, never adjust it.
    case hosted = "minimax_vision"

    /// Identifiable conformance for SwiftUI pickers (UI layer).
    /// No Foundation/UI dependencies live inside this property.
    var id: String { rawValue }

    /// Human-readable label for the host's Room Settings → Casino
    /// picker.
    var displayName: String {
        switch self {
        case .onDevice: return "On-device (default)"
        case .hosted:   return "Hosted vision (MiniMax)"
        }
    }
}
