//
//  Room.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One Games Room. Mirrors `public.rooms` joined to the per-room
/// mascot configuration the V0.6 / V0.26 mascot engine expects.
///
/// Per V0.8 brief §"Layout Decisions", Room owns:
/// - mascot name + personality + political ideology
/// - per-room feature toggles (briefing / calendar / social /
///   narration)
/// - the join-time starting bonus (`joinStartingBonus`)
/// - host-side flags (`nextEventDescription`, `mascotApiKey`)
/// - per-claimant role hint (`userRole`) — what role the *current
///   authenticated user* holds in this room at read time.
struct Room: Identifiable, Codable, Hashable {
    let id: UUID
    let name: String

    // MARK: Mascot (V0.6 + V0.26)

    let mascotName: String
    let mascotPersonality: MascotPersonality
    let mascotPoliticalIdeology: MascotPoliticalIdeology

    /// Optional API key the host has provisioned for hosted mascot
    /// generation. `nil` ⇒ on-device (Foundation Models) or
    /// templated fallback.
    let mascotApiKey: String?

    // MARK: Ownership / timing

    let createdBy: UUID
    let createdAt: Date
    let updatedAt: Date

    /// Whether the room is currently broadcasting. Drives the
    /// Rooms-list dot indicator.
    let isLive: Bool

    /// One-line teaser shown on the room card in the list. Host-set;
    /// optional.
    let nextEventDescription: String?

    /// Points awarded to a member the moment they claim a seat at
    /// the active event. V0.31 default: 200.
    let joinStartingBonus: Int

    /// The current authenticated user's role in this room. Provided
    /// by the rooms-list RPC for free; the UI does not derive this.
    let userRole: RoomRole

    // MARK: V0.26 feature toggles

    /// Whether the Briefing slot renders push-style notifications at
    /// T-48h and morning-of.
    let briefing48hEnabled: Bool

    /// Whether the host's events auto-add to their personal
    /// calendar (with consent).
    let calendarAutoAddHost: Bool

    /// Whether members can author a social-preference row.
    let socialPreferencesEnabled: Bool

    /// Whether the mascot generates per-event narration copy (vs.
    /// templated fallback). Per V0.8 brief, narration happens via
    /// the **footer caption** only.
    let socialNarrationEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mascotName = "mascot_name"
        case mascotPersonality = "mascot_personality"
        case mascotPoliticalIdeology = "mascot_political_ideology"
        case mascotApiKey = "mascot_api_key"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isLive = "is_live"
        case nextEventDescription = "next_event_description"
        case joinStartingBonus = "join_starting_bonus"
        case userRole = "user_role"
        case briefing48hEnabled = "briefing_48h_enabled"
        case calendarAutoAddHost = "calendar_auto_add_host"
        case socialPreferencesEnabled = "social_preferences_enabled"
        case socialNarrationEnabled = "social_narration_enabled"
    }

    init(
        id: UUID,
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        createdBy: UUID,
        createdAt: Date,
        updatedAt: Date,
        isLive: Bool,
        nextEventDescription: String? = nil,
        joinStartingBonus: Int = 200,
        mascotApiKey: String? = nil,
        userRole: RoomRole,
        briefing48hEnabled: Bool = true,
        calendarAutoAddHost: Bool = false,
        socialPreferencesEnabled: Bool = true,
        socialNarrationEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.mascotName = mascotName
        self.mascotPersonality = mascotPersonality
        self.mascotPoliticalIdeology = mascotPoliticalIdeology
        self.mascotApiKey = mascotApiKey
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isLive = isLive
        self.nextEventDescription = nextEventDescription
        self.joinStartingBonus = joinStartingBonus
        self.userRole = userRole
        self.briefing48hEnabled = briefing48hEnabled
        self.calendarAutoAddHost = calendarAutoAddHost
        self.socialPreferencesEnabled = socialPreferencesEnabled
        self.socialNarrationEnabled = socialNarrationEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        mascotName = try c.decode(String.self, forKey: .mascotName)
        mascotPersonality = try c.decode(MascotPersonality.self, forKey: .mascotPersonality)
        mascotPoliticalIdeology = try c.decode(MascotPoliticalIdeology.self, forKey: .mascotPoliticalIdeology)
        mascotApiKey = try c.decodeIfPresent(String.self, forKey: .mascotApiKey)
        createdBy = try c.decode(UUID.self, forKey: .createdBy)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        isLive = try c.decode(Bool.self, forKey: .isLive)
        nextEventDescription = try c.decodeIfPresent(String.self, forKey: .nextEventDescription)
        joinStartingBonus = try c.decodeIfPresent(Int.self, forKey: .joinStartingBonus) ?? 200
        userRole = try c.decode(RoomRole.self, forKey: .userRole)
        briefing48hEnabled = try c.decodeIfPresent(Bool.self, forKey: .briefing48hEnabled) ?? true
        calendarAutoAddHost = try c.decodeIfPresent(Bool.self, forKey: .calendarAutoAddHost) ?? false
        socialPreferencesEnabled = try c.decodeIfPresent(Bool.self, forKey: .socialPreferencesEnabled) ?? true
        socialNarrationEnabled = try c.decodeIfPresent(Bool.self, forKey: .socialNarrationEnabled) ?? true
    }
}
