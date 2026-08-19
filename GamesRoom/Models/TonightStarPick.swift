//
//  TonightStarPick.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Host's override category for Tonight's Star on a single event.
/// Picked by the host, not a member vote — the chip-swing default
/// (largest single-session net positive) is the fallback. V0.84 C2
/// (Carnegie Champions).
enum TonightStarOverrideCategory: String, Codable, CaseIterable, Hashable {
    /// "Played the night's best hand." Praise-first per C4.
    case bestPlay = "best_play"
    /// "Lost every pot and kept the table laughing." Praise-first
    /// — never a leaderboard position.
    case goodSport = "good_sport"
    /// "Held the room together — runner, dealer, settler of side
    /// bets." Praise-first.
    case heldTheRoom = "held_the_room"
    /// "Showed up and slotted straight in. The table's better for
    /// it." Praise-first.
    case showedUp = "showed_up"
    /// Host's own call; carries an inline `custom_text`.
    case custom

    /// Display label for the host's category picker + the
    /// ceremonial-card category line.
    var displayName: String {
        switch self {
        case .bestPlay:    return "Best Play"
        case .goodSport:   return "Good Sport"
        case .heldTheRoom: return "Held the Room"
        case .showedUp:    return "Showed Up"
        case .custom:      return "Custom"
        }
    }

    /// Short label for the chips row on the host's "Change the
    /// call" picker. Lowercase on-chip copy.
    var shortLabel: String {
        switch self {
        case .bestPlay:    return "Best play"
        case .goodSport:   return "Good sport"
        case .heldTheRoom: return "Held the room"
        case .showedUp:    return "Showed up"
        case .custom:      return "Custom"
        }
    }
}

/// Tonight's Star card surfaced on the ceremonial card. The host
/// pick (when present) wins; otherwise the 067 chip-swing default
/// is returned with `overrideCategory == nil`. V0.84 C2.
struct TonightStarCard: Codable, Hashable {
    let memberId: UUID
    let memberDisplayName: String
    /// `nil` for the chip-swing fallback (no host override).
    let overrideCategory: TonightStarOverrideCategory?
    /// Host-supplied custom line, only when `overrideCategory ==
    /// .custom`. Rendered alongside (not inside) the mascot line.
    let customText: String?
    /// `"host_pick"` when the host has overridden Tonight's Star;
    /// `"chip_swing"` when the card is the 067 fallback.
    let source: String

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case memberDisplayName = "member_display_name"
        case overrideCategory = "override_category"
        case customText = "custom_text"
        case source
    }

    init(
        memberId: UUID,
        memberDisplayName: String,
        overrideCategory: TonightStarOverrideCategory?,
        customText: String?,
        source: String
    ) {
        self.memberId = memberId
        self.memberDisplayName = memberDisplayName
        self.overrideCategory = overrideCategory
        self.customText = customText
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        memberDisplayName = try c.decode(String.self, forKey: .memberDisplayName)
        overrideCategory = try c.decodeIfPresent(
            TonightStarOverrideCategory.self, forKey: .overrideCategory
        )
        customText = try c.decodeIfPresent(String.self, forKey: .customText)
        source = try c.decode(String.self, forKey: .source)
    }
}

/// One member-written one-line drop for the room's host. Read on
/// the host's next pre-event visit; consumed by the host when
/// they've read it. V0.84 C5.
struct RoomMemberNote: Codable, Hashable {
    let id: UUID
    let roomId: UUID
    let memberId: UUID
    let memberDisplayName: String
    let noteText: String
    let createdAt: Date
    /// `nil` until the host has stamped the row via
    /// `mark_member_notes_consumed`.
    let consumedByHostAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case memberId = "member_id"
        case memberDisplayName = "member_display_name"
        case noteText = "note_text"
        case createdAt = "created_at"
        case consumedByHostAt = "consumed_by_host_at"
    }

    init(
        id: UUID,
        roomId: UUID,
        memberId: UUID,
        memberDisplayName: String,
        noteText: String,
        createdAt: Date,
        consumedByHostAt: Date?
    ) {
        self.id = id
        self.roomId = roomId
        self.memberId = memberId
        self.memberDisplayName = memberDisplayName
        self.noteText = noteText
        self.createdAt = createdAt
        self.consumedByHostAt = consumedByHostAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        memberDisplayName = try c.decode(String.self, forKey: .memberDisplayName)
        noteText = try c.decode(String.self, forKey: .noteText)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        consumedByHostAt = try c.decodeIfPresent(Date.self, forKey: .consumedByHostAt)
    }
}