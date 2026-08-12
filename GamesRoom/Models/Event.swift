//
//  Event.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One scheduled games-night event. The central entity in V0.8's
/// three-slot layout (Briefing / Witness Screen / Ceremonial Card).
///
/// Lifecycle in V0.8:
/// 1. **Pre-play Briefing** — `event.createdAt → playedAt`. Three
///    notification cadences (on-create / T-48h / morning-of) branch
///    on the recipient's RSVP state. Briefing renders *always*, even
///    when push permission is denied.
/// 2. **At-play Witness Screen** — `playedAt → settledAt`. The host
///    finalizes at the table; members receive the chip-scan CTA only
///    after finalization.
/// 3. **Post-play Ceremonial Card** — `settledAt → +24h`. Chapter
///    title (28pt serif) + ledger delta (monospaced) + 64pt gap + a
///    single call-forward line. Renders the ambient chapter strip's
///    tail.
struct Event: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID

    /// Human-readable event name shown on the Briefing card and the
    /// Ceremonial Card chapter title (e.g. "Friday Night Hold'em").
    let name: String

    /// When the host scheduled play to begin. Drives the T-48h /
    /// morning-of notification schedule and the slot rotation.
    let playedAt: Date

    /// When the row was inserted. Drives the on-create push. Always
    /// ≤ `playedAt`.
    let createdAt: Date

    /// Optional venue string. Goes on the Briefing card and the
    /// morning-of body.
    let venue: String?

    /// Optional ≤280-char host note. Goes on the Briefing card and
    /// the morning-of push body.
    let hostNote: String?

    /// Total seats at the table. Defaults to the room's
    /// `joinStartingBonus`-friendly default of 6.
    let maxSeats: Int

    /// When the host pressed "Start Play" — i.e. flipped the room
    /// from pre-play to at-play. `nil` until then.
    let startedAt: Date?

    /// When the host pressed "Finalize" at the settle step. `nil`
    /// until settle.
    let settledAt: Date?

    /// When a Session row opened for this event. Sessions are the
    /// unit the ledger / withdrawals / attestations hang off.
    let sessionId: UUID?

    /// The pack this event uses (V0.8). Legacy events created before
    /// the pack-slug extension decode to the default "casino" pack.
    let packSlug: String

    /// `true` once the host has finalized. Drives the `Scan your
    /// chips` CTA visibility on the Witness Screen.
    let hostFinalized: Bool

    /// Sentinel UUID used when the active-event RPC omits `room_id`
    /// (migration 012) — `gen_random_uuid()` never produces all-zeros,
    /// so this cannot collide with a real room. Migration 060 returns
    /// `room_id` natively; this fallback only fires against the old
    /// remote shape.
    static let unknownRoomId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    enum CodingKeys: String, CodingKey {
        case id
        case eventId = "event_id"
        case roomId = "room_id"
        case name
        case playedAt = "played_at"
        case createdAt = "created_at"
        case venue
        case hostNote = "host_note"
        case maxSeats = "max_seats"
        case startedAt = "started_at"
        case settledAt = "settled_at"
        case sessionId = "session_id"
        case packSlug = "pack_slug"
        case hostFinalized = "host_finalized"
    }

    init(
        id: UUID,
        roomId: UUID,
        name: String,
        playedAt: Date,
        createdAt: Date,
        venue: String? = nil,
        hostNote: String? = nil,
        maxSeats: Int = 6,
        startedAt: Date? = nil,
        settledAt: Date? = nil,
        sessionId: UUID? = nil,
        packSlug: String = "casino",
        hostFinalized: Bool = false
    ) {
        self.id = id
        self.roomId = roomId
        self.name = name
        self.playedAt = playedAt
        self.createdAt = createdAt
        self.venue = venue
        self.hostNote = hostNote
        self.maxSeats = maxSeats
        self.startedAt = startedAt
        self.settledAt = settledAt
        self.sessionId = sessionId
        self.packSlug = packSlug
        self.hostFinalized = hostFinalized
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let decodedEventId = try c.decodeIfPresent(UUID.self, forKey: .id) {
            id = decodedEventId
        } else {
            id = try c.decode(UUID.self, forKey: .eventId)
        }
        roomId = try c.decodeIfPresent(UUID.self, forKey: .roomId) ?? Event.unknownRoomId
        name = try c.decode(String.self, forKey: .name)
        playedAt = try c.decode(Date.self, forKey: .playedAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? playedAt
        venue = try c.decodeIfPresent(String.self, forKey: .venue)
        hostNote = try c.decodeIfPresent(String.self, forKey: .hostNote)
        maxSeats = try c.decodeIfPresent(Int.self, forKey: .maxSeats) ?? 6
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        settledAt = try c.decodeIfPresent(Date.self, forKey: .settledAt)
        sessionId = try c.decodeIfPresent(UUID.self, forKey: .sessionId)
        packSlug = try c.decodeIfPresent(String.self, forKey: .packSlug) ?? "casino"
        hostFinalized = try c.decodeIfPresent(Bool.self, forKey: .hostFinalized) ?? false
    }

    func encode(to encoder: Encoder) throws {
        // Override the synthesized encoder so the decode-only
        // `event_id` key is not emitted. The active-event RPC
        // (migration 060) returns `id` natively; `event_id` exists
        // purely as a decode fallback for the legacy 6-column shape.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(roomId, forKey: .roomId)
        try c.encode(name, forKey: .name)
        try c.encode(playedAt, forKey: .playedAt)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(venue, forKey: .venue)
        try c.encodeIfPresent(hostNote, forKey: .hostNote)
        try c.encode(maxSeats, forKey: .maxSeats)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(settledAt, forKey: .settledAt)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encode(packSlug, forKey: .packSlug)
        try c.encode(hostFinalized, forKey: .hostFinalized)
    }
}
