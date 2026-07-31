//
//  ChapterLine.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// One line of the room's persistent chapter strip — the
/// "previously on..." surface carried on the Quiet slot and as the
/// `↳ Next:` call-forward at the foot of the Ceremonial Card.
///
/// Per V0.8 brief §"What's Still Open" #1: every session gets a
/// chapter title and call-forward. The title is the ceremonial line;
/// the `nextEpisodeTeaser` (if present) becomes the `↳ Next: …`
/// line on the Ceremonial Card.
struct ChapterLine: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID

    /// Session this chapter line belongs to. One session → one
    /// chapter line. Drives the Quiet slot's "last 3 past events"
    /// cap.
    let sessionId: UUID

    /// 28pt serif title on the Ceremonial Card. Host-curated for
    /// v0.8 (`session.name` falls back here when the host hasn't
    /// written one).
    let title: String

    /// Optional `↳ Next: …` teaser at the foot of the Ceremonial
    /// Card. Drives the Quiet slot's ambient chapter strip tail.
    let nextEpisodeTeaser: String?

    /// When this chapter line was authored. Renders the chapter
    /// strip in chronological order.
    let writtenAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case sessionId = "session_id"
        case title
        case nextEpisodeTeaser = "next_episode_teaser"
        case writtenAt = "written_at"
    }

    init(
        id: UUID,
        roomId: UUID,
        sessionId: UUID,
        title: String,
        nextEpisodeTeaser: String? = nil,
        writtenAt: Date
    ) {
        self.id = id
        self.roomId = roomId
        self.sessionId = sessionId
        self.title = title
        self.nextEpisodeTeaser = nextEpisodeTeaser
        self.writtenAt = writtenAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        title = try c.decode(String.self, forKey: .title)
        nextEpisodeTeaser = try c.decodeIfPresent(String.self, forKey: .nextEpisodeTeaser)
        writtenAt = try c.decode(Date.self, forKey: .writtenAt)
    }
}
