//
//  RoomPackConfig.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Per-room payout override for one pack. Mirrors
/// `public.room_pack_configs` (migration 047).
///
/// The pack's static `winPoints` is the global default; a row in
/// this table overrides it for one room. The host edits payouts
/// from the pack shelf / settings; the host-side scoring sheet
/// reads the override so the round it submits carries the room's
/// configured payout instead of the global default.
struct RoomPackConfig: Identifiable, Codable, Hashable {
    /// Composite `roomId:packSlug` exposed to UI lists. Stable.
    let id: String
    let roomId: UUID
    let packSlug: String
    let winPoints: Int

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case packSlug = "pack_slug"
        case winPoints = "win_points"
    }

    init(
        roomId: UUID,
        packSlug: String,
        winPoints: Int
    ) {
        self.id = "\(roomId.uuidString):\(packSlug)"
        self.roomId = roomId
        self.packSlug = packSlug
        self.winPoints = winPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        packSlug = try c.decode(String.self, forKey: .packSlug)
        winPoints = try c.decodeIfPresent(Int.self, forKey: .winPoints) ?? 1
        id = "\(roomId.uuidString):\(packSlug)"
    }
}
