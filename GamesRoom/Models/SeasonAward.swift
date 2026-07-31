//
//  SeasonAward.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One award row per recipient per season.
///
/// Four award types per V0.8 brief §"Lifecycle phases" #7:
/// `.phoenix`, `.veteran`, `.whale`, `.drowning`. **`drowning` is
/// private to the member** — the awards card suppresses the row
/// from the host-public surface and the leaderboard; the Services
/// layer is responsible for projecting this row only on the
/// recipient's own device.
struct SeasonAward: Identifiable, Codable, Hashable {
    let id: UUID
    let seasonId: UUID
    let roomId: UUID

    /// The recipient. Always a room member (enforced at the
    /// database).
    let recipientUserId: UUID

    /// Display name of the recipient at the time the award row
    /// was written. Cached so the awards surface renders without a
    /// join to `public.users`.
    let recipientDisplayName: String

    /// Award category. Drives the row's icon + colour.
    let awardType: AwardType

    /// Optional ≤140-char host-curated caption. Renders on the
    /// awards card under the recipient's name.
    let caption: String?

    /// `true` once the recipient has *acknowledged* seeing the
    /// award. Privacy boundary for `.drowning` reads as ack'd if
    /// the row was ever delivered to the recipient's device.
    let acknowledged: Bool

    let awardedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case seasonId = "season_id"
        case roomId = "room_id"
        case recipientUserId = "recipient_user_id"
        case recipientDisplayName = "recipient_display_name"
        case awardType = "award_type"
        case caption
        case acknowledged
        case awardedAt = "awarded_at"
    }

    init(
        id: UUID,
        seasonId: UUID,
        roomId: UUID,
        recipientUserId: UUID,
        recipientDisplayName: String,
        awardType: AwardType,
        caption: String? = nil,
        acknowledged: Bool = false,
        awardedAt: Date
    ) {
        self.id = id
        self.seasonId = seasonId
        self.roomId = roomId
        self.recipientUserId = recipientUserId
        self.recipientDisplayName = recipientDisplayName
        self.awardType = awardType
        self.caption = caption
        self.acknowledged = acknowledged
        self.awardedAt = awardedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        seasonId = try c.decode(UUID.self, forKey: .seasonId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        recipientUserId = try c.decode(UUID.self, forKey: .recipientUserId)
        recipientDisplayName = try c.decodeIfPresent(String.self, forKey: .recipientDisplayName) ?? "Member"
        awardType = try c.decodeIfPresent(AwardType.self, forKey: .awardType) ?? .veteran
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        acknowledged = try c.decodeIfPresent(Bool.self, forKey: .acknowledged) ?? false
        awardedAt = try c.decode(Date.self, forKey: .awardedAt)
    }
}
