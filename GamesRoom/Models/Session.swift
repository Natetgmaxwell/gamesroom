//
//  Session.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One play session. Backs the Witness Screen and the per-session
/// ledger row. Sessions are 1:1 with an `Event` row in V0.8, but the
/// `Event.sessionId` link is optional (per-event creation flow vs.
/// per-session play). Withdrawals and Settlements hang off this id.
struct Session: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID

    /// Back-reference to the event this session belongs to. May be
    /// `nil` for legacy or session-first rows.
    let eventId: UUID?

    /// When play started. Drives `startedAt` mirror on the Event
    /// row.
    let startedAt: Date

    /// When the host pressed `Finalize`. `nil` while the Witness
    /// Screen is still live.
    let finalizedAt: Date?

    /// When the host wrote the chapter line. Drives the Ceremonial
    /// Card window. `nil` until the host writes one.
    let chapterLineWrittenAt: Date?

    /// Number of withdrawals recorded so far this session. Counted
    /// cheaply at the database; exposed here so the Brief slot can
    /// gate the `Scan your chips` CTA on `withdrawals > 0`.
    let withdrawalsCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case eventId = "event_id"
        case startedAt = "started_at"
        case finalizedAt = "finalized_at"
        case chapterLineWrittenAt = "chapter_line_written_at"
        case withdrawalsCount = "withdrawals_count"
    }

    init(
        id: UUID,
        roomId: UUID,
        eventId: UUID? = nil,
        startedAt: Date,
        finalizedAt: Date? = nil,
        chapterLineWrittenAt: Date? = nil,
        withdrawalsCount: Int = 0
    ) {
        self.id = id
        self.roomId = roomId
        self.eventId = eventId
        self.startedAt = startedAt
        self.finalizedAt = finalizedAt
        self.chapterLineWrittenAt = chapterLineWrittenAt
        self.withdrawalsCount = withdrawalsCount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        eventId = try c.decodeIfPresent(UUID.self, forKey: .eventId)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        finalizedAt = try c.decodeIfPresent(Date.self, forKey: .finalizedAt)
        chapterLineWrittenAt = try c.decodeIfPresent(Date.self, forKey: .chapterLineWrittenAt)
        withdrawalsCount = try c.decodeIfPresent(Int.self, forKey: .withdrawalsCount) ?? 0
    }

    /// `true` once `finalizedAt` is non-nil. Drives the
    /// `Scan your chips` CTA visibility on the Witness Screen.
    var isFinalized: Bool {
        finalizedAt != nil
    }
}
