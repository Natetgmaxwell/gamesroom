//
//  CallForward.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// A forward-looking teaser surfaced at the bottom of the
/// Ceremonial Card. Structurally distinct from
/// `ChapterLine.nextEpisodeTeaser` because a single event can carry
/// multiple call-forwards (a primary line + a "snack duty" line +
/// etc.). All string-list values are pre-formatted by the service
/// layer; this type is a freight car, not a generator.
struct CallForward: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID
    let eventId: UUID?

    /// ≤140 chars. Primary `↳ Next:` line on the Ceremonial Card.
    /// Required — without a primary teaser, there's no call-forward.
    let primaryTeaser: String

    /// ≤280 chars. Optional secondary line. Used sparingly
    /// ("snacks?", "host's note reminder", etc.).
    let secondaryTeaser: String?

    /// ≤140 chars. Names a person (for "Alex is host next" style
    /// teasers). Optional.
    let subjectDisplayName: String?

    let scheduledFor: Date

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case eventId = "event_id"
        case primaryTeaser = "primary_teaser"
        case secondaryTeaser = "secondary_teaser"
        case subjectDisplayName = "subject_display_name"
        case scheduledFor = "scheduled_for"
    }

    init(
        id: UUID,
        roomId: UUID,
        eventId: UUID? = nil,
        primaryTeaser: String,
        secondaryTeaser: String? = nil,
        subjectDisplayName: String? = nil,
        scheduledFor: Date
    ) {
        self.id = id
        self.roomId = roomId
        self.eventId = eventId
        self.primaryTeaser = primaryTeaser
        self.secondaryTeaser = secondaryTeaser
        self.subjectDisplayName = subjectDisplayName
        self.scheduledFor = scheduledFor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        eventId = try c.decodeIfPresent(UUID.self, forKey: .eventId)
        primaryTeaser = try c.decode(String.self, forKey: .primaryTeaser)
        secondaryTeaser = try c.decodeIfPresent(String.self, forKey: .secondaryTeaser)
        subjectDisplayName = try c.decodeIfPresent(String.self, forKey: .subjectDisplayName)
        scheduledFor = try c.decode(Date.self, forKey: .scheduledFor)
    }
}
