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
    // V0.82 — six new voices. Satirical character archetypes for
    // the mascot, in the same light-comedy register as the
    // original five; never real-world advocacy.
    case communist
    case conservative
    case liberal
    case apolitical
    case farRight
    case altRight

    /// Human-readable label for the host's mascot picker.
    var displayName: String {
        switch self {
        case .order:       return "Order"
        case .centrist:    return "Centrist"
        case .trickster:   return "Trickster"
        case .anarchist:   return "Anarchist"
        case .apocalypse:  return "Apocalypse"
        case .communist:   return "Communist"
        case .conservative: return "Conservative"
        case .liberal:     return "Liberal"
        case .apolitical:  return "Apolitical"
        case .farRight:    return "Far-right"
        case .altRight:    return "Alt-right"
        }
    }
}
