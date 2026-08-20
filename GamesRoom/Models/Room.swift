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

    /// Total seats at the table for events in this room. Drives
    /// the `Stepper` bounds on the Operations section of
    /// `RoomSettingsSheet`. Defaults to 6 (the pre-V0.8 default).
    let maxSeats: Int

    /// How many invites each existing member is allowed to send.
    /// Defaults to 3 (the V0.7.1 default).
    let memberInviteQuota: Int

    // MARK: Host journal (P1.5 — host operations polish)

    /// The host's bounded observation/journal field. Single free-
    /// text line surfaced on Room Settings; member cannot edit.
    /// Migration 036 adds the `host_journal text` column; the iOS
    /// decoder falls back to `nil` on legacy rows that pre-date
    /// the migration. Bounded to 280 chars at the SQL layer.
    let hostJournal: String?

    // MARK: M4 — installed pack slugs (room-level pack state)

    /// Slugs of the packs installed in this room. Mirrors the
    /// `public.room_packs` table (migration 041). The room never
    /// reaches up to the global catalog — only these slugs are
    /// visible. `nil` means "use the legacy V0.8 default of all
    /// four packs" so legacy rooms pre-migration keep rendering
    /// the same shelf.
    let installedPackSlugs: [String]?

    /// Per-room opt-in for sharing the member's own Drowning season-end award.
    /// When true, other opted-in members + the host can read this
    /// member's Drowning row (RLS-gated by migration 045). Default false.
    let memberDrowningOptIn: Bool
    /// V0.54 — per-room opt-in for receiving pre-play logistics pushes
    /// (on-create / T-48h / morning-of). Default false (quiet-by-default).
    /// The current user's own membership opt-in, surfaced through
    /// `get_my_rooms` (migration 066) and drives the BriefingSlot
    /// toggle in `RoomDetailView`. Renaming the decoder key to
    /// `notifications_enabled` is safe: get_my_rooms still returns
    /// `member_drowning_opt_in` for back-compat.
    let notificationsEnabled: Bool

    /// V0.55 — cross-room overlap signal (substrate 1.2). How many
    /// co-members of this room the caller also sits with in at least
    /// one other room, plus up to 5 of their display names. Computed
    /// fresh by `get_my_rooms` (migration 068); drives the room-row
    /// overlap badge. Defaults to 0 / empty on legacy rows.
    let overlapCount: Int
    let overlapNames: [String]

    /// V0.83 — hours after `played_at` before the lazy auto-close
    /// stamps `settled_at` on an un-finalized event (migration 081).
    /// Host-adjustable from Room Settings → Operations; bounded
    /// 1...72 server-side. Defaults to 8 (the V0.83 default).
    let autoCloseHours: Int

    /// V0.85 — seat deposit amount in CC (migration 085; renames
    /// 082's `no_show_tax_amount`, absorbing the dormant 043
    /// `seat_deposit_amount`). Host-adjustable from Room Settings
    /// → Seat deposit; bounded 0...1000 server-side. Defaults to
    /// 200. The amount that leaves the member's balance into
    /// escrow at claim and returns on the "I'm here" tap.
    let seatDepositAmount: Int

    /// V0.85 — whether the deposit escrow runs (migration 085).
    /// `.escrow` (default) is the canonical V0.85 mode: claim
    /// charges the deposit, arrival returns it, the host decides
    /// forfeits. `.off` disables deposits — claims are plain RSVP
    /// upserts. The old auto/prompt/manual raws decode to
    /// `.escrow` (the host forfeit-confirm replaces them).
    let seatDepositTrigger: SeatDepositTrigger

    /// V0.85 — minutes after `played_at` during which a missing
    /// check-in is still "within grace" on the arrival card
    /// (migration 085). Host-adjustable; bounded 0...120.
    /// Defaults to 10.
    let seatDepositGraceMinutes: Int

    /// V0.85 — where a forfeited deposit lands (migration 085).
    /// `.nextPot` is the locked default; the chips ride the next
    /// event's pot. `.hostCharityPot` and `.split` record the
    /// destination in the ledger row's meta.
    let seatDepositDestination: SeatDepositDestination

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
        case maxSeats = "max_seats"
        case memberInviteQuota = "member_invite_quota"
        case hostJournal = "host_journal"
        case installedPackSlugs = "installed_pack_slugs"
        case seatDepositAmount = "seat_deposit_amount"
        case seatDepositTrigger = "seat_deposit_trigger"
        case seatDepositGraceMinutes = "seat_deposit_grace_minutes"
        case seatDepositDestination = "seat_deposit_destination"
        /// V0.85 — pre-085 payloads still carry 082's raws; the
        /// decoder falls back to these when the renamed keys are
        /// absent. Encode always writes the V0.85 keys.
        case legacyNoShowTaxAmount = "no_show_tax_amount"
        case legacyNoShowTaxTrigger = "no_show_tax_trigger"
        case legacyNoShowTaxGraceMinutes = "no_show_tax_grace_minutes"
        case legacyNoShowTaxDestination = "no_show_tax_destination"
        case memberDrowningOptIn = "member_drowning_opt_in"
    case notificationsEnabled = "notifications_enabled"
    case overlapCount = "overlap_count"
    case overlapNames = "overlap_names"
    case autoCloseHours = "auto_close_hours"
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
        socialNarrationEnabled: Bool = true,
        maxSeats: Int = 6,
        memberInviteQuota: Int = 3,
        hostJournal: String? = nil,
        installedPackSlugs: [String]? = nil,
        seatDepositAmount: Int = 200,
        seatDepositTrigger: SeatDepositTrigger = .escrow,
        seatDepositGraceMinutes: Int = 10,
        seatDepositDestination: SeatDepositDestination = .nextPot,
        memberDrowningOptIn: Bool = false,
        notificationsEnabled: Bool = false,
        overlapCount: Int = 0,
        overlapNames: [String] = [],
        autoCloseHours: Int = 8
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
        self.maxSeats = maxSeats
        self.memberInviteQuota = memberInviteQuota
        self.hostJournal = hostJournal
        self.installedPackSlugs = installedPackSlugs
        self.seatDepositAmount = seatDepositAmount
        self.seatDepositTrigger = seatDepositTrigger
        self.seatDepositGraceMinutes = seatDepositGraceMinutes
        self.seatDepositDestination = seatDepositDestination
        self.memberDrowningOptIn = memberDrowningOptIn
        self.notificationsEnabled = notificationsEnabled
        self.overlapCount = overlapCount
        self.overlapNames = overlapNames
        self.autoCloseHours = autoCloseHours
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
        maxSeats = try c.decodeIfPresent(Int.self, forKey: .maxSeats) ?? 6
        memberInviteQuota = try c.decodeIfPresent(Int.self, forKey: .memberInviteQuota) ?? 3
        hostJournal = try c.decodeIfPresent(String.self, forKey: .hostJournal)
        installedPackSlugs = try c.decodeIfPresent([String].self, forKey: .installedPackSlugs)
        seatDepositAmount = try c.decodeIfPresent(Int.self, forKey: .seatDepositAmount)
            ?? c.decodeIfPresent(Int.self, forKey: .legacyNoShowTaxAmount) ?? 200
        let triggerRaw = try c.decodeIfPresent(String.self, forKey: .seatDepositTrigger)
            ?? c.decodeIfPresent(String.self, forKey: .legacyNoShowTaxTrigger)
            ?? SeatDepositTrigger.escrow.rawValue
        seatDepositTrigger = SeatDepositTrigger(rawValue: triggerRaw) ?? .escrow
        seatDepositGraceMinutes = try c.decodeIfPresent(Int.self, forKey: .seatDepositGraceMinutes)
            ?? c.decodeIfPresent(Int.self, forKey: .legacyNoShowTaxGraceMinutes) ?? 10
        let destRaw = try c.decodeIfPresent(String.self, forKey: .seatDepositDestination)
            ?? c.decodeIfPresent(String.self, forKey: .legacyNoShowTaxDestination)
            ?? SeatDepositDestination.nextPot.rawValue
        seatDepositDestination = SeatDepositDestination(rawValue: destRaw) ?? .nextPot
        memberDrowningOptIn = try c.decodeIfPresent(Bool.self, forKey: .memberDrowningOptIn) ?? false
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
        overlapCount = try c.decodeIfPresent(Int.self, forKey: .overlapCount) ?? 0
        overlapNames = try c.decodeIfPresent([String].self, forKey: .overlapNames) ?? []
        autoCloseHours = try c.decodeIfPresent(Int.self, forKey: .autoCloseHours) ?? 8
    }

    /// V0.85 — encode always writes the renamed seat_deposit_* keys
    /// (never the legacy no_show_tax_* raws). The legacy CodingKeys
    /// exist only for decode fallback, so a custom encoder is
    /// required — synthesized Encodable would choke on the
    /// property-less legacy cases.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(mascotName, forKey: .mascotName)
        try c.encode(mascotPersonality, forKey: .mascotPersonality)
        try c.encode(mascotPoliticalIdeology, forKey: .mascotPoliticalIdeology)
        try c.encodeIfPresent(mascotApiKey, forKey: .mascotApiKey)
        try c.encode(createdBy, forKey: .createdBy)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(isLive, forKey: .isLive)
        try c.encodeIfPresent(nextEventDescription, forKey: .nextEventDescription)
        try c.encode(joinStartingBonus, forKey: .joinStartingBonus)
        try c.encode(userRole, forKey: .userRole)
        try c.encode(briefing48hEnabled, forKey: .briefing48hEnabled)
        try c.encode(calendarAutoAddHost, forKey: .calendarAutoAddHost)
        try c.encode(socialPreferencesEnabled, forKey: .socialPreferencesEnabled)
        try c.encode(socialNarrationEnabled, forKey: .socialNarrationEnabled)
        try c.encode(maxSeats, forKey: .maxSeats)
        try c.encode(memberInviteQuota, forKey: .memberInviteQuota)
        try c.encodeIfPresent(hostJournal, forKey: .hostJournal)
        try c.encodeIfPresent(installedPackSlugs, forKey: .installedPackSlugs)
        try c.encode(seatDepositAmount, forKey: .seatDepositAmount)
        try c.encode(seatDepositTrigger, forKey: .seatDepositTrigger)
        try c.encode(seatDepositGraceMinutes, forKey: .seatDepositGraceMinutes)
        try c.encode(seatDepositDestination, forKey: .seatDepositDestination)
        try c.encode(memberDrowningOptIn, forKey: .memberDrowningOptIn)
        try c.encode(notificationsEnabled, forKey: .notificationsEnabled)
        try c.encode(overlapCount, forKey: .overlapCount)
        try c.encode(overlapNames, forKey: .overlapNames)
        try c.encode(autoCloseHours, forKey: .autoCloseHours)
    }
}