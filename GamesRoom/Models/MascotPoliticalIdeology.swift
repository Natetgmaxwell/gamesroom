//
//  MascotPoliticalIdeology.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// 5×5 mascot political-ideology axis. Matches the V0.6 mascot-engine
/// matrix. The "voice direction" string for each cell lives in the
/// mascot-engine service; this type stays declarative.
enum MascotPoliticalIdeology: String, Codable, CaseIterable, Hashable {
    case order
    case centrist
    case trickster
    case anarchist
    case apocalypse

    /// Human-readable label for the host's mascot picker.
    var displayName: String {
        switch self {
        case .order:      return "Order"
        case .centrist:   return "Centrist"
        case .trickster:  return "Trickster"
        case .anarchist:  return "Anarchist"
        case .apocalypse: return "Apocalypse"
        }
    }
}
