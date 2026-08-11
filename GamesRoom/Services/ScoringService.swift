//
//  ScoringService.swift
//  GamesRoom
//
//  Track P0.4 — host-side round scoring.
//
//  The host-side scoring dashboard's single entry point. One
//  `recordRound(...)` call submits every per-member `ScoreEntry`
//  for a single round as one atomic server-side write via the
//  `record_round_score(p_room_id, p_event_id, p_pack_slug,
//  p_round_index, p_entries jsonb)` RPC (migration 035).
//
//  Why one service for all packs
//  -----------------------------
//  The host-side dashboard is one SwiftUI screen with pack-specific
//  input forms (one per scoring-type). All forms funnel into this
//  single service so the network contract is uniform: one RPC,
//  one idempotency key, one optimistic in-memory write. Adding a
//  new pack means adding a new input form view; the service stays
//  unchanged.
//
//  Why a separate scoring service
//  -------------------------------
//  `RoomService` owns room + event + RSVP state. Scoring is a
//  distinct domain — it owns the `ScoreEntry` payload and the
//  per-round ledger writes — so it lives in its own service. The
//  in-memory preview path mirrors `RoomService`'s pattern:
//  `ScoringService(store:)` takes a `ScoringStore` protocol so
//  the host-side dashboard works against an in-memory fake
//  without Supabase being reachable.
//
//

import Foundation
import Supabase
import SwiftUI

// MARK: - ScoringStore

/// Abstraction over the `record_round_score` RPC surface.
/// Implemented by `LiveScoringStore` (Supabase) and
/// `InMemoryScoringStore` (default for previews).
protocol ScoringStore: Sendable {
    /// Submit one round's worth of score entries for a host-scored
    /// session. Mirrors `record_round_score(p_room_id, p_event_id,
    /// p_pack_slug, p_round_index, p_entries jsonb, p_correction_of?)`
    /// from migration 042. Throws on RLS rejection (non-host writes)
    /// or invalid entries (e.g. unknown member id).
    func recordRound(
        roomId: UUID,
        eventId: UUID,
        packSlug: String,
        roundIndex: Int,
        entries: [ScoreEntry],
        correctionOf: UUID?
    ) async throws -> ScoreSubmission

    /// Reverse a previously-recorded round: subtracts each entry's
    /// delta from `room_memberships.season_score`, deletes the
    /// round's transactions, and removes the `round_submissions`
    /// row. Mirrors `delete_round_score(p_room_id, p_event_id,
    /// p_round_index)` from migration 054. Host-only; idempotent
    /// (no row for the round → no-op). Throws on non-host calls.
    func deleteRound(
        roomId: UUID,
        eventId: UUID,
        roundIndex: Int
    ) async throws
}

/// The result of a successful round submission. Mirrors the
/// `(id uuid, room_id uuid, event_id uuid, round_index int,
/// pack_slug text, created_at timestamptz, correction_of uuid?)`
/// shape returned by `record_round_score`. Carried by the host-side
/// dashboard so the in-flight round card collapses to a settled state.
struct ScoreSubmission: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID
    let eventId: UUID
    let roundIndex: Int
    let packSlug: String
    let createdAt: Date
    let correctionOf: UUID?

    enum CodingKeys: String, CodingKey {
        case id
        case roomId = "room_id"
        case eventId = "event_id"
        case roundIndex = "round_index"
        case packSlug = "pack_slug"
        case createdAt = "created_at"
        case correctionOf = "correction_of"
    }

    init(
        id: UUID,
        roomId: UUID,
        eventId: UUID,
        roundIndex: Int,
        packSlug: String,
        createdAt: Date,
        correctionOf: UUID? = nil
    ) {
        self.id = id
        self.roomId = roomId
        self.eventId = eventId
        self.roundIndex = roundIndex
        self.packSlug = packSlug
        self.createdAt = createdAt
        self.correctionOf = correctionOf
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        eventId = try c.decode(UUID.self, forKey: .eventId)
        roundIndex = try c.decodeIfPresent(Int.self, forKey: .roundIndex) ?? 0
        packSlug = try c.decodeIfPresent(String.self, forKey: .packSlug) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        correctionOf = try c.decodeIfPresent(UUID.self, forKey: .correctionOf)
    }
}

// MARK: - LiveScoringStore

/// Supabase-backed scoring store. Routes every round through the
/// `record_round_score` RPC. Constructor is `init()` with no
/// arguments; the shared client lives on `SupabaseClientProvider`.
final class LiveScoringStore: ScoringStore, @unchecked Sendable {
    static let shared = LiveScoringStore()
    private init() {}

    func recordRound(
        roomId: UUID,
        eventId: UUID,
        packSlug: String,
        roundIndex: Int,
        entries: [ScoreEntry],
        correctionOf: UUID?
    ) async throws -> ScoreSubmission {
        // Encode the entries as JSON. The server jsonb decoder
        // expects `[{member_id, points_delta, meta}, …]`.
        let encoder = JSONEncoder()
        let entriesData = try encoder.encode(entries)
        let entriesJSON = String(data: entriesData, encoding: .utf8) ?? "[]"

        var params: [String: String] = [
            "p_room_id": roomId.uuidString,
            "p_event_id": eventId.uuidString,
            "p_pack_slug": packSlug,
            "p_round_index": String(roundIndex),
            "p_entries": entriesJSON
        ]
        if let correctionOf {
            params["p_correction_of"] = correctionOf.uuidString
        }

        let rows: [ScoreSubmission] = try await SupabaseClientProvider.shared
            .rpc("record_round_score", params: params)
            .execute()
            .value
        guard let row = rows.first else {
            throw NSError(
                domain: "LiveScoringStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "record_round_score returned no row"]
            )
        }
        return row
    }

    func deleteRound(
        roomId: UUID,
        eventId: UUID,
        roundIndex: Int
    ) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("delete_round_score", params: [
                "p_room_id": roomId.uuidString,
                "p_event_id": eventId.uuidString,
                "p_round_index": String(roundIndex)
            ])
            .execute()
            .value as Void
    }
}

// MARK: - InMemoryScoringStore

/// Default `ScoringStore` for previews and dev-without-network
/// builds. Echoes back a synthetic `ScoreSubmission`; doesn't
/// accumulate state (the room store already holds the seed
/// rooms). Used so the host-side scoring dashboard renders
/// against a fake without requiring any infra.
final class InMemoryScoringStore: ScoringStore, @unchecked Sendable {
    static let shared = InMemoryScoringStore()
    private init() {}

    func recordRound(
        roomId: UUID,
        eventId: UUID,
        packSlug: String,
        roundIndex: Int,
        entries: [ScoreEntry],
        correctionOf: UUID?
    ) async throws -> ScoreSubmission {
        _ = entries
        return ScoreSubmission(
            id: UUID(),
            roomId: roomId,
            eventId: eventId,
            roundIndex: roundIndex,
            packSlug: packSlug,
            createdAt: Date(),
            correctionOf: correctionOf
        )
    }

    func deleteRound(
        roomId: UUID,
        eventId: UUID,
        roundIndex: Int
    ) async throws {
        _ = (roomId, eventId, roundIndex)
    }
}

// MARK: - ScoringService

@MainActor
final class ScoringService: ObservableObject {

    /// Most-recent error message. Cleared on every successful
    /// submission. Surfaced to the UI as a transient banner.
    @Published private(set) var lastError: String?

    /// Most-recent successful submission. The host-side
    /// dashboard observes this so it can collapse the in-flight
    /// round card to a settled state without a re-fetch.
    @Published private(set) var lastSubmission: ScoreSubmission?

    /// Backing store. Default is `LiveScoringStore.shared` —
    /// callers can inject `InMemoryScoringStore.shared` for
    /// previews or for builds without a Supabase URL.
    private let store: ScoringStore

    init(store: ScoringStore = LiveScoringStore.shared) {
        self.store = store
    }

    /// Submit one round's score entries for a host-scored session.
    /// Throws on RLS rejection or invalid entries; on success the
    /// `lastSubmission` published value updates so the dashboard
    /// can clear the in-flight round card.
    @discardableResult
    func recordRound(
        roomId: UUID,
        eventId: UUID,
        packSlug: String,
        roundIndex: Int,
        entries: [ScoreEntry],
        correctionOf: UUID? = nil
    ) async throws -> ScoreSubmission {
        guard !entries.isEmpty else {
            throw NSError(
                domain: "ScoringService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot record a round with no entries"]
            )
        }
        let submission = try await store.recordRound(
            roomId: roomId,
            eventId: eventId,
            packSlug: packSlug,
            roundIndex: roundIndex,
            entries: entries,
            correctionOf: correctionOf
        )
        self.lastSubmission = submission
        self.lastError = nil
        return submission
    }

    /// Reverse a previously-recorded round: subtracts the deltas,
    /// deletes the round's transactions, and removes the row.
    /// Clears `lastError` on success; throws on non-host calls.
    /// Mirrors the `delete_round_score` RPC from migration 054.
    func deleteRound(
        roomId: UUID,
        eventId: UUID,
        roundIndex: Int
    ) async throws {
        try await store.deleteRound(
            roomId: roomId,
            eventId: eventId,
            roundIndex: roundIndex
        )
        self.lastError = nil
    }

    /// Convenience wrapper that takes the raw host-side
    /// `PackScoringInput` and resolves it through the
    /// `PackScoringResolver` before submitting. Mirrors the
    /// dashboard's user flow: pack-specific form → input →
    /// resolved entries → server write.
    @discardableResult
    func recordRoundInput(
        roomId: UUID,
        eventId: UUID,
        packSlug: String,
        input: PackScoringInput,
        correctionOf: UUID? = nil
    ) async throws -> ScoreSubmission {
        let entries = PackScoringResolver.resolve(input, packSlug: packSlug)
        let roundIndex: Int = {
            switch input {
            case .singleWinner(let roundIndex, _, _): return roundIndex
            case .multiWinner(let roundIndex, _, _):  return roundIndex
            case .withdrawReturn(let roundIndex, _):  return roundIndex
            }
        }()
        return try await recordRound(
            roomId: roomId,
            eventId: eventId,
            packSlug: packSlug,
            roundIndex: roundIndex,
            entries: entries,
            correctionOf: correctionOf
        )
    }
}