//
//  GladStore.swift
//  GamesRoom
//
//  1.2.5 Task 4 — "Glad you came" data surface. Kept apart from the
//  50-method `RoomStore` (same call `QuestionBoxStore` made) so the
//  feature lands without widening it.
//
//  Two calls, and on purpose no third: there is no "how many", no list
//  for anyone but the caller. The server (migration 119, RLS) returns
//  only rows the caller sent or rows addressed to the caller; the
//  in-memory store below mirrors that filter so previews and the sweep
//  behave the same way.
//
//  Foundation only: the in-memory store is compiled into the unit
//  runner because the sweep seeds call it. `LiveGladStore` lives in
//  GladLiveStore.swift.
//

import Foundation

protocol GladStore: Sendable {
    /// The caller's own sent rows and the rows addressed to the caller,
    /// for one night. Server side: `select` on `public.glad_you_came`,
    /// filtered by RLS.
    func fetchNotes(eventId: UUID, viewerId: UUID) async throws -> [GladNote]

    /// Tell these people. Duplicates do nothing (unique key + ignore
    /// duplicates). Server side: insert into `public.glad_you_came`,
    /// gated by `glad_can_send` in the insert policy.
    func send(eventId: UUID, from viewerId: UUID, to recipients: [UUID]) async throws
}

/// In-memory twin for previews and the screenshot sweep. Mirrors the
/// server's read filter and its "twice does nothing" rule.
final class InMemoryGladStore: GladStore, @unchecked Sendable {
    static let shared = InMemoryGladStore()

    private let lock = NSLock()
    private var notes: [GladNote] = []

    func fetchNotes(eventId: UUID, viewerId: UUID) async throws -> [GladNote] {
        lock.lock(); defer { lock.unlock() }
        return notes.filter {
            $0.eventId == eventId && ($0.fromUser == viewerId || $0.toUser == viewerId)
        }
    }

    func send(eventId: UUID, from viewerId: UUID, to recipients: [UUID]) async throws {
        lock.lock(); defer { lock.unlock() }
        insert(recipients.map { GladNote(eventId: eventId, fromUser: viewerId, toUser: $0, createdAt: Date()) })
    }

    /// Sweep seam: rows written as if other people had sent them.
    func seed(_ seeded: [GladNote]) {
        lock.lock(); defer { lock.unlock() }
        insert(seeded)
    }

    private func insert(_ rows: [GladNote]) {
        for row in rows where row.fromUser != row.toUser {
            let dup = notes.contains {
                $0.eventId == row.eventId && $0.fromUser == row.fromUser && $0.toUser == row.toUser
            }
            if !dup { notes.append(row) }
        }
    }
}
