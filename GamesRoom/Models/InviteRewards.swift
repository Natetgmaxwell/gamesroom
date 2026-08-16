//
//  InviteRewards.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  The result of `get_my_invite_rewards(room_id)` — what
//  `RoomService` returns when a member asks how many friends joined
//  via their codes and how many points they earned. Drives the
//  V0.76 invite-reward banner.
//

import Foundation

/// One row from `get_my_invite_rewards(p_room_id)`. Mirrors the
/// `(friends_joined integer, total_reward bigint)` returns-table
/// shape from migration 076. The Swift decoder routes the JSON into
/// this struct via the `LiveRoomStore.fetchMyInviteRewards(...)`
/// wrapper.
struct InviteRewards: Codable, Hashable {
    let friendsJoined: Int
    let totalReward: Int

    enum CodingKeys: String, CodingKey {
        case friendsJoined = "friends_joined"
        case totalReward = "total_reward"
    }

    init(friendsJoined: Int, totalReward: Int) {
        self.friendsJoined = friendsJoined
        self.totalReward = totalReward
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        friendsJoined = try c.decodeIfPresent(Int.self, forKey: .friendsJoined) ?? 0
        totalReward = try c.decodeIfPresent(Int.self, forKey: .totalReward) ?? 0
    }
}
