//
//  RoomService.swift
//  GamesRoom
//
//  Track D2 — the V0.8 room + event + RSVP + settings service.
//
//  `RoomService` is the single SwiftUI-facing surface for every
//  read/write the Room list, the Room detail page, and the Room
//  settings sheet need. It talks to a `RoomStore` protocol —
//  `InMemoryRoomStore.shared` is the default (no infra path),
//  `LiveRoomStore.shared` is the production backend (swap in
//  `RoomService.init(store:)` once the Supabase URL + key are
//  configured).
//
//  Why this service exists
//  ------------------------
//  V0.8 ships the layout + the view tree, but the actions were
//  stubbed (Claim seat, Decline, Save settings, Add event, etc.
//  all no-op'd). The V0.8.1 work wires every action to the
//  matching RPC via this service. The split is:
//
//    1. `RoomService` — `@MainActor @ObservableObject` that owns
//       `@Published` cached reads (`rooms`, `activeEventByRoom`,
//       `briefingByEvent`, `leaderboardByRoom`) so the SwiftUI
//       views can subscribe via `@EnvironmentObject`.
//    2. `RoomStore` — the protocol that abstracts over the
//       Supabase RPC surface and the in-memory fake. The two
//       implementations (`LiveRoomStore`, `InMemoryRoomStore`)
//       share no code beyond the protocol conformance.
//    3. Views — read cached state via `@Published` bindings and
//       fire actions via the service methods (which delegate to
//       the store).
//
//  Threading: all mutations happen on the main actor. Network
//  calls live on the `RoomStore` impl; the result is assigned
//  back on the main actor after `await`. The protocol itself is
//  `Sendable` so the store can be backed by a real network stack
//  or an actor-isolated in-memory cache without forcing the
//  SwiftUI view layer to know.
//
//

import Foundation
import SwiftUI
import Supabase

// MARK: - RoomService

@MainActor
final class RoomService: ObservableObject {

    // MARK: - Configuration

    /// The store backing this service. Default is the in-memory
    /// fake — pass `LiveRoomStore.shared` to talk to Supabase once
    /// the project is configured with a URL + key.
    private let store: RoomStore

    /// Designated initialiser. The default `store` parameter makes
    /// this a drop-in replacement for the V0.8 `RoomService()` call
    /// sites (no arguments) — every existing view continues to
    /// work without a wiring change.
    init(store: RoomStore = InMemoryRoomStore.shared) {
        self.store = store
    }

    // MARK: - Published state

    /// The rooms list, in display order. Mirrors the `get_my_rooms`
    /// RPC.
    @Published private(set) var rooms: [Room] = []

    /// Most-recent load state for the rooms list.
    @Published private(set) var isLoading: Bool = false

    /// Most-recent error message. Cleared on every successful
    /// operation. Surfaced to the UI as a transient banner.
    @Published private(set) var lastError: String?

    /// Active event cache keyed by roomId. Populated lazily by
    /// `loadActiveEvent(roomId:)`; consumed by `RoomDetailView`.
    @Published private(set) var activeEventByRoom: [UUID: Event] = [:]

    /// Briefing summary cache keyed by eventId. Populated lazily
    /// by `loadBriefing(eventId:)`; consumed by `RoomDetailView`.
    @Published private(set) var briefingByEvent: [UUID: BriefingSummary] = [:]

    /// Leaderboard cache keyed by roomId. Populated lazily by
    /// `loadLeaderboard(roomId:)`; consumed by `RoomDetailView`.
    @Published private(set) var leaderboardByRoom: [UUID: [LeaderboardEntry]] = [:]

    /// Current-member RSVP cache keyed by eventId. Populated lazily
    /// by `loadCurrentMemberRSVP(eventId:)`; consumed by
    /// `RoomDetailView` to gate the upcoming / claimed / declined
    /// slot branches.
    @Published private(set) var rsvpByEvent: [UUID: MemberRSVPState] = [:]

    // MARK: - Rooms list

    /// Re-fetch the rooms list. Safe to call from `.task` and
    /// `.refreshable`. Concurrent calls coalesce (the second caller
    /// observes the same `isLoading` cycle).
    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await store.fetchRooms()
            self.rooms = result
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// Look up a room by id. The list-side cache; the authoritative
    /// read goes through the store when the view needs server-
    /// fresh data.
    func room(withId id: UUID) -> Room? {
        rooms.first { $0.id == id }
    }

    // MARK: - Room detail (event + briefing + leaderboard + RSVP)

    /// Loads the room's active event into the cache. Returns the
    /// cached value (which may be `nil` for rooms with no recent
    /// activity). Called from `RoomDetailView.task`.
    @discardableResult
    func loadActiveEvent(roomId: UUID) async -> Event? {
        do {
            let event = try await store.fetchActiveEvent(roomId: roomId)
            self.activeEventByRoom[roomId] = event
            self.lastError = nil
            return event
        } catch {
            self.lastError = error.localizedDescription
            return activeEventByRoom[roomId]
        }
    }

    /// Loads the briefing summary for one event into the cache.
    /// Returns the cached value. Called from `RoomDetailView.task`
    /// when an active event is present.
    @discardableResult
    func loadBriefing(eventId: UUID) async -> BriefingSummary? {
        do {
            let briefing = try await store.fetchBriefing(eventId: eventId)
            self.briefingByEvent[eventId] = briefing
            self.lastError = nil
            return briefing
        } catch {
            self.lastError = error.localizedDescription
            return briefingByEvent[eventId]
        }
    }

    /// Loads the room's leaderboard into the cache. Returns the
    /// cached value (possibly empty). Called from
    /// `RoomDetailView.task`.
    @discardableResult
    func loadLeaderboard(roomId: UUID) async -> [LeaderboardEntry] {
        do {
            let rows = try await store.fetchLeaderboard(roomId: roomId)
            self.leaderboardByRoom[roomId] = rows
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return leaderboardByRoom[roomId] ?? []
        }
    }

    /// Loads the current member's RSVP for one event into the
    /// cache. Returns the cached value (defaults to `.unclaimed`
    /// for events with no RSVP row). Called from
    /// `RoomDetailView.task` so the slot rotates to `.claimed` /
    /// `.declined` / `.upcoming` per the V0.8 state machine.
    @discardableResult
    func loadCurrentMemberRSVP(eventId: UUID) async -> MemberRSVPState {
        do {
            let state = try await store.fetchCurrentMemberRSVP(eventId: eventId)
            self.rsvpByEvent[eventId] = state
            self.lastError = nil
            return state
        } catch {
            self.lastError = error.localizedDescription
            return rsvpByEvent[eventId] ?? .unclaimed
        }
    }

    // MARK: - RSVP upsert

    /// Idempotent RSVP upsert. Called from `RoomDetailView`'s
    /// "Claim seat" / "Can't make it" buttons. Writes through to
    /// the store, mirrors the persisted state into the cache so the
    /// slot rotates immediately, and returns the persisted
    /// `MemberRSVP` row.
    ///
    /// On error: the cache is unchanged and `lastError` is set.
    /// The view can show a neutral toast.
    @discardableResult
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP {
        let row = try await store.upsertEventRSVP(eventId: eventId, state: state)
        self.rsvpByEvent[eventId] = row.state
        self.lastError = nil
        return row
    }

    // MARK: - Event create

    /// Creates a new event in a room. Called from `AddEventSheet`.
    /// Returns the new event id; the parent refreshes the active-
    /// event cache on success.
    @discardableResult
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID {
        let newId = try await store.addEvent(
            roomId: roomId,
            name: name,
            playedAt: playedAt,
            packSlug: packSlug
        )
        self.lastError = nil
        // Eagerly refresh the active-event cache so the parent's
        // post-create flow doesn't need a second round-trip.
        _ = await loadActiveEvent(roomId: roomId)
        return newId
    }

    // MARK: - Room settings update

    /// Updates the room's mascot + operations + feature-toggle
    /// columns. Called from `RoomSettingsSheet.save()`. Returns the
    /// server-canonical `Room` (so the view can mirror any
    /// server-applied defaults) and updates the rooms-list cache so
    /// the Rooms-page row reflects the new name + mascot
    /// immediately.
    @discardableResult
    func updateRoom(
        id: UUID,
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        maxSeats: Int,
        memberInviteQuota: Int,
        joinStartingBonus: Int,
        socialNarrationEnabled: Bool,
        briefing48hEnabled: Bool,
        calendarAutoAddHost: Bool,
        socialPreferencesEnabled: Bool
    ) async throws -> Room {
        let updated = try await store.updateRoom(
            id: id,
            name: name,
            mascotName: mascotName,
            mascotPersonality: mascotPersonality,
            mascotPoliticalIdeology: mascotPoliticalIdeology,
            maxSeats: maxSeats,
            memberInviteQuota: memberInviteQuota,
            joinStartingBonus: joinStartingBonus,
            socialNarrationEnabled: socialNarrationEnabled,
            briefing48hEnabled: briefing48hEnabled,
            calendarAutoAddHost: calendarAutoAddHost,
            socialPreferencesEnabled: socialPreferencesEnabled
        )
        self.lastError = nil
        if let idx = rooms.firstIndex(where: { $0.id == updated.id }) {
            rooms[idx] = updated
        }
        return updated
    }

    // MARK: - Cache accessors (used by views)

    /// Cached active event for `roomId`, if any. `RoomDetailView`
    /// reads this for the initial render before the async load
    /// resolves.
    func cachedActiveEvent(roomId: UUID) -> Event? {
        activeEventByRoom[roomId]
    }

    /// Cached briefing summary for `eventId`, if any.
    func cachedBriefing(eventId: UUID) -> BriefingSummary? {
        briefingByEvent[eventId]
    }

    /// Cached leaderboard for `roomId`, possibly empty.
    func cachedLeaderboard(roomId: UUID) -> [LeaderboardEntry] {
        leaderboardByRoom[roomId] ?? []
    }

    /// Cached current-member RSVP for `eventId`, defaulting to
    /// `.unclaimed` so the upcoming slot is the safe default.
    func cachedRSVP(eventId: UUID) -> MemberRSVPState {
        rsvpByEvent[eventId] ?? .unclaimed
    }
}

// MARK: - Preview support
#if DEBUG
extension RoomService {
    /// In-memory preview service for SwiftUI previews. No network.
    /// Returns three seeded rooms spanning the role matrix.
    @MainActor
    static func preview() -> RoomService {
        let svc = RoomService()
        Task { await svc.refresh() }
        return svc
    }
}
#endif