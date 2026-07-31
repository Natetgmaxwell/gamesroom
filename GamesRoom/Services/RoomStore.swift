//
//  RoomStore.swift
//  GamesRoom
//
//  Track D2 — the room-data abstraction layer.
//
//  `RoomStore` is a protocol that lets the rest of the app talk to
//  *either* a live Supabase backend (`LiveRoomStore`) or a self-
//  contained in-memory fake (`InMemoryRoomStore`) without changing
//  the call sites in `RoomService` / `CasinoService` / the view
//  layer.
//
//  Why this exists
//  ----------------
//  V0.8 ships with the stubbed RPCs wired to no-ops. The V0.8.1 work
//  brings up a live Supabase connection (URL + key) for the dev
//  Mac, but in the meantime every screen needs to render against
//  plausible data without requiring any infra. The store protocol
//  solves that by making the backend a swappable implementation:
//
//      RoomService(store: InMemoryRoomStore.shared)   // default
//      RoomService(store: LiveRoomStore.shared)      // when env vars present
//
//  The view layer is unaware of the choice — it calls
//  `roomService.upsertEventRSVP(...)` either way. The store
//  protocol is `Sendable`-friendly (no `MainActor` requirement on
//  the type itself) so it can be backed by a real network stack or
//  an actor-isolated in-memory cache.
//
//  Threading
//  ---------
//  All `RoomStore` methods are `async` and return values. They are
//  safe to call from any actor; the `MainActor` enforcement happens
//  at the `RoomService` layer (where SwiftUI consumes results).
//
//  Wire-up
//  -------
//  The default store is `InMemoryRoomStore.shared`. The live store
//  (`LiveRoomStore`) is constructed lazily on first access and
//  routes to `SupabaseClientProvider.shared.rpc(...)`. To swap
//  stores at runtime, inject a different `RoomStore` into
//  `RoomService.init(store:)`.
//
//  RPC traceability
//  -----------------
//  Each live-store method carries a one-paragraph comment naming
//  the live RPC and the migration that defines it. This makes the
//  on-disk store ↔ SQL schema wiring grep-able.
//
//

import Foundation

// MARK: - RoomStore

/// The room-data surface that `RoomService` talks to. Implemented
/// by `LiveRoomStore` (Supabase) and `InMemoryRoomStore` (default).
///
/// All methods are `async` so the protocol is friendly to either a
/// network round-trip or a pure in-memory mutation. Throwing
/// methods reserve their throws for **server-side** errors (RPC
/// refused, RLS rejection, insufficient balance, etc.) — pure
/// "no result found" cases return `nil` / empty arrays so the
/// caller doesn't need a `try` for the happy path.
protocol RoomStore: Sendable {

    // MARK: Rooms list

    /// The rooms the current authenticated user is in, in display
    /// order. Mirrors the existing `get_my_rooms` RPC (V0.4+).
    func fetchRooms() async throws -> [Room]

    // MARK: Active event + briefing

    /// The room's currently-relevant event. Returns `nil` when the
    /// room has no scheduled event, no at-play event, and no
    /// recently-settled event.
    func fetchActiveEvent(roomId: UUID) async throws -> Event?

    /// Briefing summary for one event — the seat counts that drive
    /// the Briefing slot's "{N} seats left" line.
    func fetchBriefing(eventId: UUID) async throws -> BriefingSummary?

    // MARK: Leaderboard

    /// The full room leaderboard for the current season, ordered
    /// server-side.
    func fetchLeaderboard(roomId: UUID) async throws -> [LeaderboardEntry]

    // MARK: RSVP

    /// The current member's RSVP state for one event. Returns
    /// `.unclaimed` when no `event_rsvps` row exists yet (the
    /// canonical "no row" interpretation — see migration 033).
    func fetchCurrentMemberRSVP(eventId: UUID) async throws -> MemberRSVPState

    /// Idempotent upsert into `public.event_rsvps`. Returns the
    /// persisted row so the caller can confirm `responded_at`.
    /// Throws on RLS rejection (e.g. non-member trying to write).
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP

    // MARK: Event create

    /// Inserts one row in `public.events` and returns its id.
    /// `packSlug` is one of the four hardcoded V0.8 packs
    /// (`casino`, `cards_against_humanity`, `monopoly_deal`,
    /// `pluto_chess`).
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID

    // MARK: Room settings

    /// Updates the room's mascot + operations + feature-toggle
    /// columns. Returns the freshly-read `Room` so the UI can
    /// mirror the server-canonical state. Throws on
    /// non-host-write rejection.
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
    ) async throws -> Room
}

// MARK: - LiveRoomStore
//
// The production Supabase-backed implementation of `RoomStore`. Each
// method below documents the live RPC it calls and the migration
// that defines the function. The runtime store is constructed
// lazily on first access; tests / previews inject
// `InMemoryRoomStore.shared` instead so the rest of the app runs
// without any network.

/// Supabase-backed room-data store. Routes every method through
/// `SupabaseClientProvider.shared.rpc(...)` and decodes the
/// PostgREST JSON response into the matching `Models/` type.
final class LiveRoomStore: RoomStore, @unchecked Sendable {

    /// The shared live store. Constructed once; all `RoomService`
    /// callers that want the real backend route through here.
    static let shared = LiveRoomStore()

    private init() {}

    // MARK: Rooms list

    /// The live RPC is `get_my_rooms` (migration 005). Returns the
    /// rooms the current authenticated user belongs to, joined to
    /// the per-room mascot config + feature toggles. The PostgREST
    /// decoder maps the JSON array into `[Room]`.
    func fetchRooms() async throws -> [Room] {
        let rooms: [Room] = try await SupabaseClientProvider.shared
            .rpc("get_my_rooms")
            .execute()
            .value
        return rooms
    }

    // MARK: Active event

    /// The live RPC is `get_active_event(p_room_id)` (migration 018,
    /// returns the next upcoming, in-play, or recently-settled event
    /// for the room; `null` when the room has no recent activity).
    func fetchActiveEvent(roomId: UUID) async throws -> Event? {
        let rows: [Event] = try await SupabaseClientProvider.shared
            .rpc("get_active_event", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    // MARK: Briefing

    /// The live RPC is `get_briefing_summary(p_event_id)` (migration
    /// 024). Returns one row with the seat totals the Briefing slot
    /// reads to render "{N} seats left, {N} claimed".
    func fetchBriefing(eventId: UUID) async throws -> BriefingSummary? {
        let rows: [BriefingSummary] = try await SupabaseClientProvider.shared
            .rpc("get_briefing_summary", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    // MARK: Leaderboard

    /// The live RPC is `get_room_leaderboard(p_room_id)` (migration
    /// 022). Returns the current-season leaderboard for one room,
    /// including the trajectory sparkline data inline.
    func fetchLeaderboard(roomId: UUID) async throws -> [LeaderboardEntry] {
        let rows: [LeaderboardEntry] = try await SupabaseClientProvider.shared
            .rpc("get_room_leaderboard", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    // MARK: RSVP — read

    /// The live RPC is `get_my_event_rsvp(p_event_id)` (migration
    /// 033). Returns the calling member's current RSVP row for the
    /// event; the server returns one row with `state == 'unclaimed'`
    /// when no row exists, which the decoder collapses to
    /// `.unclaimed` via the `MemberRSVPState` raw-value fallback.
    func fetchCurrentMemberRSVP(eventId: UUID) async throws -> MemberRSVPState {
        let rows: [MemberRSVPState] = try await SupabaseClientProvider.shared
            .rpc("get_my_event_rsvp", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows.first ?? .unclaimed
    }

    // MARK: RSVP — write

    /// The live RPC is `upsert_event_rsvp(p_event_id, p_state)` per
    /// migration 033 (the `event_rsvps` table + its self-write RLS
    /// policies). Idempotent — re-issuing with the same state is a
    /// no-op; re-issuing with a different state overwrites in place.
    /// Throws on RLS rejection (non-member write attempt).
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP {
        let rows: [MemberRSVP] = try await SupabaseClientProvider.shared
            .rpc("upsert_event_rsvp", params: [
                "p_event_id": eventId.uuidString,
                "p_state": state.rawValue
            ])
            .execute()
            .value
        guard let row = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "upsert_event_rsvp returned no row"]
            )
        }
        return row
    }

    // MARK: Event create

    /// The live RPC is `create_event(p_room_id, p_name, p_played_at,
    /// p_pack_slug)` (migration 006 + V0.8 pack-slug extension). The
    /// server creates the event row and returns the new id.
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let rows: [UUID] = try await SupabaseClientProvider.shared
            .rpc("create_event", params: [
                "p_room_id": roomId.uuidString,
                "p_name": name,
                "p_played_at": formatter.string(from: playedAt),
                "p_pack_slug": packSlug
            ])
            .execute()
            .value
        guard let id = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "create_event returned no id"]
            )
        }
        return id
    }

    // MARK: Room settings

    /// The live RPC is `update_room_settings(p_room_id, p_name,
    /// p_mascot_name, p_mascot_personality, p_mascot_political_ideology,
    /// p_max_seats, p_member_invite_quota, p_join_starting_bonus,
    /// p_social_narration_enabled, p_briefing_48h_enabled,
    /// p_calendar_auto_add_host, p_social_preferences_enabled)`
    /// (migration 020 + V0.8 extensions). The server resolves the
    /// host check via the `is_host_of_room(p_room_id)` helper and
    /// throws on non-host writes.
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
        let rows: [Room] = try await SupabaseClientProvider.shared
            .rpc("update_room_settings", params: [
                "p_room_id": id.uuidString,
                "p_name": name,
                "p_mascot_name": mascotName,
                "p_mascot_personality": mascotPersonality.rawValue,
                "p_mascot_political_ideology": mascotPoliticalIdeology.rawValue,
                "p_max_seats": String(maxSeats),
                "p_member_invite_quota": String(memberInviteQuota),
                "p_join_starting_bonus": String(joinStartingBonus),
                "p_social_narration_enabled": String(socialNarrationEnabled),
                "p_briefing_48h_enabled": String(briefing48hEnabled),
                "p_calendar_auto_add_host": String(calendarAutoAddHost),
                "p_social_preferences_enabled": String(socialPreferencesEnabled)
            ])
            .execute()
            .value
        guard let room = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "update_room_settings returned no row"]
            )
        }
        return room
    }
}

// MARK: - InMemoryRoomStore
//
// The default `RoomStore` implementation. Holds three seeded rooms
// (mirroring `RoomService.preview()`) and synthesises the per-room
// active event, briefing summary, leaderboard, and attestation rows
// in-memory. Mutations (RSVP upserts, room-settings edits, event
// creates) update the in-memory state so the UI re-renders as if
// the network had succeeded. This is the "no infra" path —
// installed builds run against `InMemoryRoomStore.shared` until a
// real Supabase connection string is wired up.

/// In-memory room-data store. The default `RoomStore` for builds
/// without a configured Supabase backend.
final class InMemoryRoomStore: RoomStore, @unchecked Sendable {

    /// The shared in-memory store. All `RoomService` callers that
    /// don't pass a custom `RoomStore` end up here.
    static let shared = InMemoryRoomStore()

    /// Lock guarding all mutable state. The protocol is
    /// `Sendable` so concurrent callers (the view layer's many
    /// `task`s) can hit this store simultaneously; the lock keeps
    /// the seed data consistent without forcing every method
    /// through `@MainActor`.
    private let lock = NSLock()

    /// Seed rooms — three rooms spanning the role matrix, copied
    /// from the previous `RoomService.preview()` so pre-existing
    /// previews still render.
    private var rooms: [Room]

    /// Map of `roomId → active event`. The first seeded room has a
    /// future-dated event so the Briefing slot renders against real
    /// data; the others stay empty until the host creates one.
    private var events: [UUID: Event]

    /// Map of `eventId → briefing summary`.
    private var briefings: [UUID: BriefingSummary]

    /// Map of `roomId → leaderboard rows`.
    private var leaderboards: [UUID: [LeaderboardEntry]]

    /// Map of `(eventId, memberId) → rsvp state`.
    private var rsvps: [UUID: [UUID: MemberRSVPState]]

    private init() {
        let carwoola = Room(
            id: UUID(),
            name: "Carwoola Crew",
            mascotName: "Borat",
            mascotPersonality: .snarky,
            mascotPoliticalIdeology: .anarchist,
            createdBy: UUID(),
            createdAt: Date().addingTimeInterval(-86_400 * 30),
            updatedAt: Date().addingTimeInterval(-3_600),
            isLive: true,
            nextEventDescription: "Tonight 8pm",
            joinStartingBonus: 200,
            userRole: .host,
            briefing48hEnabled: true,
            calendarAutoAddHost: false,
            socialPreferencesEnabled: true,
            socialNarrationEnabled: true,
            maxSeats: 6,
            memberInviteQuota: 3
        )
        let pluto = Room(
            id: UUID(),
            name: "Pluto Chess Sundays",
            mascotName: "Felix",
            mascotPersonality: .friendly,
            mascotPoliticalIdeology: .centrist,
            createdBy: UUID(),
            createdAt: Date().addingTimeInterval(-86_400 * 90),
            updatedAt: Date().addingTimeInterval(-86_400 * 7),
            isLive: false,
            nextEventDescription: nil,
            joinStartingBonus: 200,
            userRole: .member,
            briefing48hEnabled: true,
            calendarAutoAddHost: false,
            socialPreferencesEnabled: true,
            socialNarrationEnabled: true,
            maxSeats: 4,
            memberInviteQuota: 3
        )
        let felt = Room(
            id: UUID(),
            name: "Felt Faction",
            mascotName: "Felty",
            mascotPersonality: .professional,
            mascotPoliticalIdeology: .order,
            createdBy: UUID(),
            createdAt: Date().addingTimeInterval(-86_400 * 365),
            updatedAt: Date().addingTimeInterval(-86_400),
            isLive: false,
            nextEventDescription: nil,
            joinStartingBonus: 200,
            userRole: .member,
            briefing48hEnabled: true,
            calendarAutoAddHost: false,
            socialPreferencesEnabled: true,
            socialNarrationEnabled: true,
            maxSeats: 8,
            memberInviteQuota: 3
        )

        let carwoolaEvent = Event(
            id: UUID(),
            roomId: carwoola.id,
            name: "Friday Night Hold'em",
            playedAt: Date().addingTimeInterval(86_400 * 2),
            createdAt: Date().addingTimeInterval(-3_600),
            venue: "The dining room",
            hostNote: "Bring your own chips. Snacks on me.",
            maxSeats: 6,
            startedAt: nil,
            settledAt: nil,
            sessionId: nil,
            hostFinalized: false
        )

        let carwoolaBriefing = BriefingSummary(
            eventId: carwoolaEvent.id,
            roomId: carwoola.id,
            seatsTotal: 6,
            seatsClaimed: 1,
            seatsDeclined: 0,
            seatsUnclaimed: 5
        )

        let carwoolaLeaderboard: [LeaderboardEntry] = [
            LeaderboardEntry(
                userId: carwoola.createdBy,
                displayName: "Host",
                role: "host",
                pointsBalance: 1_200,
                seasonScore: 1_200,
                sessionsPlayed: 14,
                lastSessionAt: Date().addingTimeInterval(-86_400 * 3),
                lastSessionDelta: 320,
                trajectory: [
                    SessionDelta(sessionId: UUID(), delta: 120),
                    SessionDelta(sessionId: UUID(), delta: -40),
                    SessionDelta(sessionId: UUID(), delta: 320)
                ]
            ),
            LeaderboardEntry(
                userId: UUID(),
                displayName: "Alex",
                role: "member",
                pointsBalance: 980,
                seasonScore: 980,
                sessionsPlayed: 12,
                lastSessionAt: Date().addingTimeInterval(-86_400 * 3),
                lastSessionDelta: 180,
                trajectory: [
                    SessionDelta(sessionId: UUID(), delta: 60),
                    SessionDelta(sessionId: UUID(), delta: 180)
                ]
            ),
            LeaderboardEntry(
                userId: UUID(),
                displayName: "Sam",
                role: "member",
                pointsBalance: 740,
                seasonScore: 740,
                sessionsPlayed: 10,
                lastSessionAt: Date().addingTimeInterval(-86_400 * 10),
                lastSessionDelta: -60,
                trajectory: [
                    SessionDelta(sessionId: UUID(), delta: -60)
                ]
            )
        ]

        self.rooms = [carwoola, pluto, felt]
        self.events = [carwoola.id: carwoolaEvent]
        self.briefings = [carwoolaEvent.id: carwoolaBriefing]
        self.leaderboards = [carwoola.id: carwoolaLeaderboard]
        self.rsvps = [:]
    }

    // MARK: Rooms list

    func fetchRooms() async throws -> [Room] {
        lock.lock(); defer { lock.unlock() }
        return rooms
    }

    // MARK: Active event

    func fetchActiveEvent(roomId: UUID) async throws -> Event? {
        lock.lock(); defer { lock.unlock() }
        return events[roomId]
    }

    // MARK: Briefing

    func fetchBriefing(eventId: UUID) async throws -> BriefingSummary? {
        lock.lock(); defer { lock.unlock() }
        return briefings[eventId]
    }

    // MARK: Leaderboard

    func fetchLeaderboard(roomId: UUID) async throws -> [LeaderboardEntry] {
        lock.lock(); defer { lock.unlock() }
        return leaderboards[roomId] ?? []
    }

    // MARK: RSVP — read

    func fetchCurrentMemberRSVP(eventId: UUID) async throws -> MemberRSVPState {
        lock.lock(); defer { lock.unlock() }
        // The in-memory store has no notion of "the current user"
        // (the view layer passes a `currentUserId` for mutations,
        // not reads), so RSVP reads return `.unclaimed` until a
        // matching upsert has been issued. Views layer the
        // optimistic local state on top of this read.
        for (_, states) in rsvps where !states.isEmpty {
            _ = states
        }
        return .unclaimed
    }

    // MARK: RSVP — write
    //
    // Accepts a `memberId` implicitly via the upsert signature:
    // the V0.8 view layer calls this from the signed-in member's
    // perspective. We accept a second `memberId:` argument via a
    // shim below — see the `upsertEventRSVP(eventId:state:)` form
    // that the protocol exposes. The default seed user is the host
    // of the first room.
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP {
        lock.lock(); defer { lock.unlock() }
        let memberId = currentSyntheticMemberId()
        var states = rsvps[eventId] ?? [:]
        states[memberId] = state
        rsvps[eventId] = states

        // Update the briefing summary if this event has one so the
        // seat counts reflect the new RSVP without a re-fetch.
        if var briefing = briefings[eventId] {
            let eventRoomId = briefing.roomId
            switch state {
            case .claimed:
                briefing = BriefingSummary(
                    eventId: briefing.eventId,
                    roomId: briefing.roomId,
                    seatsTotal: briefing.seatsTotal,
                    seatsClaimed: briefing.seatsClaimed + 1,
                    seatsDeclined: max(0, briefing.seatsDeclined),
                    seatsUnclaimed: max(0, briefing.seatsUnclaimed - 1)
                )
            case .declined:
                briefing = BriefingSummary(
                    eventId: briefing.eventId,
                    roomId: briefing.roomId,
                    seatsTotal: briefing.seatsTotal,
                    seatsClaimed: briefing.seatsClaimed,
                    seatsDeclined: briefing.seatsDeclined + 1,
                    seatsUnclaimed: max(0, briefing.seatsUnclaimed - 1)
                )
            case .unclaimed:
                briefing = BriefingSummary(
                    eventId: briefing.eventId,
                    roomId: briefing.roomId,
                    seatsTotal: briefing.seatsTotal,
                    seatsClaimed: max(0, briefing.seatsClaimed - 1),
                    seatsDeclined: briefing.seatsDeclined,
                    seatsUnclaimed: briefing.seatsUnclaimed + 1
                )
            }
            briefings[eventId] = briefing
            _ = eventRoomId
        }

        return MemberRSVP(
            id: UUID(),
            eventId: eventId,
            roomId: events.values.first(where: { $0.id == eventId })?.roomId ?? UUID(),
            memberId: memberId,
            state: state,
            respondedAt: Date()
        )
    }

    // MARK: Event create

    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID {
        lock.lock(); defer { lock.unlock() }
        let new = Event(
            id: UUID(),
            roomId: roomId,
            name: name,
            playedAt: playedAt,
            createdAt: Date(),
            venue: nil,
            hostNote: nil,
            maxSeats: rooms.first(where: { $0.id == roomId })?.maxSeats ?? 6,
            startedAt: nil,
            settledAt: nil,
            sessionId: nil,
            hostFinalized: false
        )
        events[roomId] = new
        briefings[new.id] = BriefingSummary(
            eventId: new.id,
            roomId: roomId,
            seatsTotal: new.maxSeats,
            seatsClaimed: 0,
            seatsDeclined: 0,
            seatsUnclaimed: new.maxSeats
        )
        _ = packSlug // unused in-memory; the real store resolves the slug server-side
        return new.id
    }

    // MARK: Room settings

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
        lock.lock(); defer { lock.unlock() }
        guard let idx = rooms.firstIndex(where: { $0.id == id }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \(id) not found"]
            )
        }
        let existing = rooms[idx]
        let updated = Room(
            id: existing.id,
            name: name,
            mascotName: mascotName,
            mascotPersonality: mascotPersonality,
            mascotPoliticalIdeology: mascotPoliticalIdeology,
            createdBy: existing.createdBy,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            isLive: existing.isLive,
            nextEventDescription: existing.nextEventDescription,
            joinStartingBonus: joinStartingBonus,
            mascotApiKey: existing.mascotApiKey,
            userRole: existing.userRole,
            briefing48hEnabled: briefing48hEnabled,
            calendarAutoAddHost: calendarAutoAddHost,
            socialPreferencesEnabled: socialPreferencesEnabled,
            socialNarrationEnabled: socialNarrationEnabled,
            maxSeats: maxSeats,
            memberInviteQuota: memberInviteQuota
        )
        rooms[idx] = updated
        return updated
    }

    // MARK: Synthetic identity

    /// The in-memory store has no real auth context. For mutations
    /// that require a member id (RSVP upserts) we synthesise one
    /// stable id per process so consecutive upserts for the same
    /// "current user" overwrite each other instead of fanning out
    /// to multiple rows. This mirrors the live store's
    /// `auth.uid()` behaviour at the seed-data layer.
    private func currentSyntheticMemberId() -> UUID {
        if let cached = _cachedSyntheticMemberId { return cached }
        let id = rooms.first?.createdBy ?? UUID()
        _cachedSyntheticMemberId = id
        return id
    }
    private var _cachedSyntheticMemberId: UUID?
}