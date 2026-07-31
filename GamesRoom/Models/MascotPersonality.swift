//
//  MascotPersonality.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// 5×5 mascot personality axis. Matches the V0.6 mascot-engine
/// matrix. Behavioural description (the `promptFragment` /
/// "voice direction" strings) lives in the mascot-engine service
/// layer — keeping this type purely declarative.
enum MascotPersonality: String, Codable, CaseIterable, Hashable {
    case professional
    case friendly
    case snarky
    case sarcastic
    case unhinged

    /// Human-readable label for the host's mascot picker.
    var displayName: String {
        switch self {
        case .professional: return "Professional"
        case .friendly:     return "Friendly"
        case .snarky:       return "Snarky"
        case .sarcastic:    return "Sarcastic"
        case .unhinged:     return "Unhinged"
        }
    }
}
