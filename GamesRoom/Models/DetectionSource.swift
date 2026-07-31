//
//  DetectionSource.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Where a `SessionScan`'s `visionAmountPoints` came from. Persisted
/// by the database as the raw string so new sources can be added
/// without an app release; the case list here covers what the app
/// actively renders today.
enum DetectionSource: String, Codable, CaseIterable, Hashable {
    /// On-device rectangle detection + hue heuristic. Default per
    /// `CasinoConfig.visionProvider == .onDevice`.
    case onDevice = "on_device"

    /// Hosted vision API per `CasinoConfig.visionProvider`. Higher
    /// accuracy, ~2–5s latency, requires API key.
    case hosted

    /// The row was recorded by hand by the host (e.g. dispute
    /// resolution).
    case manual

    /// No scan has been recorded yet. Placeholder state for the
    /// UI's pending slot.
    case pending

    /// Whether the source's confidence_avg can be trusted to drive
    /// the auto-confirm treatment in the UI.
    var hasConfidence: Bool {
        switch self {
        case .onDevice, .hosted: return true
        case .manual, .pending:  return false
        }
    }
}
