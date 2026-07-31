//
//  ChipColor.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One of the six chip colors in the casino pack. Pure data —
/// `defaultValue` and `displayName` are static lookups, no UI
/// imports. The chip's visual color is reconstructed by the UI
/// service from this raw string.
enum ChipColor: String, Codable, CaseIterable, Hashable {
    case red
    case blue
    case green
    case black
    case white
    case custom

    /// Default point value. `.custom` is 0 by convention — the
    /// room's `CasinoConfig.chipColorMap` owns the actual value.
    var defaultValue: Int {
        switch self {
        case .red:    return 5
        case .blue:   return 10
        case .green:  return 25
        case .black:  return 100
        case .white:  return 1
        case .custom: return 0
        }
    }

    /// Human-readable label for the chip-color picker in Room
    /// Settings → Casino. The hex/RGB mapping lives in the UI
    /// Theme service.
    var displayName: String {
        switch self {
        case .red:    return "Red"
        case .blue:   return "Blue"
        case .green:  return "Green"
        case .black:  return "Black"
        case .white:  return "White"
        case .custom: return "Custom"
        }
    }
}
