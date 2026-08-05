//
//  RoomSystemEvent.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//
//  One row per room-scoped system event (pack_removed,
//  season_closed, pack_installed). The Briefing slot reads
//  unread rows from this table and renders the appropriate
//  banner. Mirrors migration 041's `public.room_system_events`.
//

import Foundation

struct RoomSystemEvent: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID
    let kind: Kind
    let payload: [String: AnyCodable]
    let createdAt: Date
    let acknowledgedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case kind
        case payload
        case createdAt = "created_at"
        case acknowledgedAt = "acknowledged_at"
    }

    init(
        id: UUID,
        roomId: UUID,
        kind: Kind,
        payload: [String: AnyCodable] = [:],
        createdAt: Date,
        acknowledgedAt: Date? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.acknowledgedAt = acknowledgedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        let rawKind = try c.decode(String.self, forKey: .kind)
        kind = Kind(rawValue: rawKind) ?? .packRemoved
        // Decode the JSON payload loosely into AnyCodable. If the
        // server returns a different shape we collapse to an
        // empty dict rather than throwing — the banner just
        // surfaces a generic message.
        if let raw = try? c.decode([String: AnyCodable].self, forKey: .payload) {
            payload = raw
        } else {
            payload = [:]
        }
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        acknowledgedAt = try c.decodeIfPresent(Date.self, forKey: .acknowledgedAt)
    }

    /// One of the supported system event kinds. Strings match
    /// the SQL `check` constraint in migration 041 so the Swift
    /// decoder never collapses to `unknown`.
    enum Kind: String, Codable, CaseIterable, Hashable {
        case packRemoved = "pack_removed"
        case packInstalled = "pack_installed"
        case seasonClosed = "season_closed"

        /// Display label for the briefing banner.
        var displayName: String {
            switch self {
            case .packRemoved:   return "Pack removed"
            case .packInstalled: return "Pack installed"
            case .seasonClosed:  return "Season closed"
            }
        }
    }
}

/// Minimal JSON-codable wrapper for the system-event payload
/// (which can contain strings, numbers, booleans, and nested
/// arrays/dicts). Lives next to the model since no other view
/// needs it today; promote to a shared file if a second caller
/// appears.
struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Int64.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if c.decodeNil() { value = NSNull(); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:    try c.encode(v)
        case let v as Int:     try c.encode(v)
        case let v as Int64:   try c.encode(v)
        case let v as Double:  try c.encode(v)
        case let v as String:  try c.encode(v)
        case is NSNull:        try c.encodeNil()
        default:               try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}