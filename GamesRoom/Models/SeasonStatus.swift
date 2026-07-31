//
//  SeasonStatus.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Lifecycle state of a Season. Drives the `.seasonClose`
/// `DominantAction` case on the quiet slot of the room page.
enum SeasonStatus: String, Codable, CaseIterable, Hashable {
    /// Current, open season. The room page renders the Quiet hero
    /// with this season's subtitle.
    case active

    /// Closed by the host. The room page renders the awards
    /// surface; the season subtitle is read-only until a new season
    /// opens.
    case ended

    /// Human-readable label for host tools.
    var displayName: String {
        switch self {
        case .active: return "Active"
        case .ended:  return "Ended"
        }
    }
}
