//
//  RedeemedRoom.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  The result of `redeem_join_code(code)` — what `RoomService`
//  returns when a member successfully redeems a six-character code.
//  Carries the room id (so the parent can push the room) and the
//  room name (so the success toast can echo it back to the user).
//

import Foundation

/// One row from `redeem_join_code(p_code)`. Mirrors the
/// `(room_id uuid, room_name text)` returns-table shape from
/// migrations 004 + 018 (per-room bonus extension). The Swift
/// decoder routes the JSON into this struct via the
/// `LiveRoomStore.redeemJoinCode(...)` wrapper.
struct RedeemedRoom: Identifiable, Codable, Hashable {
    let roomId: UUID
    let roomName: String

    var id: UUID { roomId }

    enum CodingKeys: String, CodingKey {
        case roomId = "room_id"
        case roomName = "room_name"
    }

    init(roomId: UUID, roomName: String) {
        self.roomId = roomId
        self.roomName = roomName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? "Room"
    }
}