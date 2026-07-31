//
//  RoomRole.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Role a member holds in a room.
///
/// The V0.8 layout exposes host-only chrome (host observation
/// text-field, room-settings gear, "+ Add an event" CTA) by
/// comparing against this enum at the UI layer — never inside the
/// model.
enum RoomRole: String, Codable, CaseIterable, Hashable {
    case host
    case member

    /// Per-V0.8-layout §"Layout Decisions" L6.
    var isHost: Bool {
        self == .host
    }
}
