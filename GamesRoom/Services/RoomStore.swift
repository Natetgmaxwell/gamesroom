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

// MARK: - RPC parameter structs
// Supabase-swift's rpc(params:) requires Encodable & Sendable. Dict
// literals that mix String and [String] values infer as [String: Any]
// which is not Encodable. These structs give each array-param RPC a
// concrete Encodable type.

struct CreateRoomParams: Encodable, Sendable {
    let p_name: String
    let p_mascot_name: String
    let p_mascot_personality: String
    let p_mascot_political_ideology: String
    let p_join_starting_bonus: String
    let p_mascot_api_key: String
    let p_blacklisted_user_ids: [String]
}

struct UpdateRoomPacksParams: Encodable, Sendable {
    let p_room_id: String
    let p_slugs: [String]
}

struct SetDrowningOptInParams: Encodable, Sendable {
    let p_room_id: String
    let p_opt_in: Bool
}

protocol RoomStore: Sendable {

    // MARK: Rooms list

    /// The rooms the current authenticated user is in, in display
    /// order. Mirrors the existing `get_my_rooms` RPC (V0.4+).
    func fetchRooms() async throws -> [Room]

    // MARK: Create room + join codes (P0.2 onboarding)

    /// Creates a new room with the calling user as the host.
    /// Mirrors the `create_room(p_name, p_mascot_name,
    /// p_mascot_personality, p_mascot_political_ideology,
    /// p_join_starting_bonus, p_mascot_api_key,
    /// p_blacklisted_user_ids)` RPC (migration 022). Returns the
    /// new room id; the caller should refresh the rooms list so the
    /// hero/empty state re-renders.
    func createRoom(
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        joinStartingBonus: Int,
        mascotApiKey: String?,
        blacklistedUserIds: [UUID]
    ) async throws -> UUID

    /// Mints a fresh 6-character join code for a room the caller
    /// hosts. Mirrors `generate_join_code(p_room_id)` (migration
    /// 004 + 006 host check). Throws on non-host writes.
    func generateJoinCode(roomId: UUID) async throws -> String

    /// Redeems a join code on behalf of the calling user. Mirrors
    /// `redeem_join_code(p_code)` (migration 004 + V0.18 bonus
    /// extension). Idempotent: re-redeeming for an existing member
    /// returns the room without mutating points. Throws on
    /// not-found / already-redeemed / RLS rejection (the iOS UI
    /// maps these to user-facing error strings).
    func redeemJoinCode(code: String) async throws -> RedeemedRoom

    /// Lists the members of a room, host-first then alphabetical.
    /// Mirrors `get_room_members(p_room_id)` (migration 008). The
    /// Swift mirror is the `Member` model — name, role, joined-at.
    /// Throws on RLS rejection (non-member read attempt).
    func fetchRoomMembers(roomId: UUID) async throws -> [Member]

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

    // MARK: Host journal (P1.5)

    /// Updates the host's bounded observation/journal field on the
    /// room. Mirrors `update_host_journal(p_room_id, p_journal)`
    /// from migration 036. Server-side bounded to 280 chars.
    /// Throws on non-host writes (RLS denial). Returns the
    /// server-canonical `Room` so the UI can mirror the persisted
    /// value without a follow-up read.
    func updateHostJournal(roomId: UUID, journal: String?) async throws -> Room

    // MARK: Seasons (M1.1 — slot-rotation fidelity)

    /// The room's active-or-most-recently-ended season. Returns
    /// `nil` only when the room has never opened a season — the
    /// V0.8 brief guarantees every room has at least one season
    /// from creation. Drives the `.seasonClose` V0State branch on
    /// `RoomDetailView`.
    ///
    /// Server side: migration 039 introduces `public.seasons`. The
    /// server should return one row — preferring `status='ended'`
    /// over `status='active'` if both exist (a defensive fallback
    /// for the season-close transition window).
    func fetchCurrentSeason(roomId: UUID) async throws -> Season?

    /// The room's awards for one season. **Privacy boundary:**
    /// the server must NOT include `.drowning` rows unless the
    /// caller is the recipient — migration 039 encodes this with
    /// per-recipient RLS. The Swift layer additionally filters
    /// `.drowning` rows whose `recipientUserId != currentUserId`,
    /// as a belt-and-braces guard in case the SQL view leaks.
    func fetchSeasonAwards(seasonId: UUID) async throws -> [SeasonAward]

    // MARK: Room packs (M4 — pack-as-platform polish)

    /// Returns the pack slugs installed in this room. Mirrors
    /// the `public.room_packs` table (migration 041). The room
    /// never reaches up to the global catalog; only enabled
    /// rows are visible. Returns an empty array when the room
    /// has no pack overrides (callers can fall back to the
    /// V0.8 default of all four packs).
    func fetchRoomPacks(roomId: UUID) async throws -> [String]

    /// Replaces the room's enabled pack set in a single call.
    /// Mirrors `update_room_packs(p_room_id, p_slugs text[])`
    /// (migration 041). Validates slugs server-side; throws on
    /// invalid input. Emits one `room_system_events` row per
    /// removed pack so the briefing banner surfaces the change.
    func updateRoomPacks(roomId: UUID, slugs: [String]) async throws

    /// Returns the room's unread system events (pack_removed,
    /// season_closed, etc.). Used by the briefing slot's
    /// "System" section. Mirrors migration 041's
    /// `public.room_system_events`.
    func fetchRoomSystemEvents(roomId: UUID) async throws -> [RoomSystemEvent]

    /// Marks one system event as acknowledged for the calling
    /// user. Used by the briefing slot after the member has
    /// seen the banner.
    func acknowledgeSystemEvent(eventId: UUID) async throws

    // MARK: Drowning opt-in (V0.9 Wave 1 Slice 1.1)

    /// Flips `room_memberships.member_drowning_opt_in` for the
    /// calling member's own row in this room. The SQL RLS policy
    /// in migration 045 ensures a member can only update their own
    /// row; the dedicated `set_drowning_opt_in` RPC keeps the
    /// contract explicit. The service-layer caller is responsible
    /// for re-fetching the room so the in-memory cache reflects
    /// the new value.
    func setDrowningOptIn(roomId: UUID, optIn: Bool) async throws
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

    // MARK: Create room + join codes (P0.2 onboarding)

    /// The live RPC is `create_room(p_name, p_mascot_name,
    /// p_mascot_personality, p_mascot_political_ideology,
    /// p_join_starting_bonus, p_mascot_api_key,
    /// p_blacklisted_user_ids)` (migration 022). The server
    /// resolves the host check via the caller's auth context,
    /// inserts the row, fires the `handle_new_room` trigger that
    /// adds the caller as a host member, and returns the new room
    /// id.
    func createRoom(
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        joinStartingBonus: Int,
        mascotApiKey: String?,
        blacklistedUserIds: [UUID]
    ) async throws -> UUID {
        let rows: [UUID] = try await SupabaseClientProvider.shared
            .rpc("create_room", params: CreateRoomParams(
                p_name: name,
                p_mascot_name: mascotName,
                p_mascot_personality: mascotPersonality.rawValue,
                p_mascot_political_ideology: mascotPoliticalIdeology.rawValue,
                p_join_starting_bonus: String(joinStartingBonus),
                p_mascot_api_key: mascotApiKey ?? "",
                p_blacklisted_user_ids: blacklistedUserIds.map(\.uuidString)
            ))
            .execute()
            .value
        guard let id = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "create_room returned no id"]
            )
        }
        return id
    }

    /// The live RPC is `generate_join_code(p_room_id)` (migration
    /// 004 + V0.3 host-check extension). Returns the freshly-minted
    /// six-character code. Throws on non-host writes.
    func generateJoinCode(roomId: UUID) async throws -> String {
        let rows: [String] = try await SupabaseClientProvider.shared
            .rpc("generate_join_code", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        guard let code = rows.first, !code.isEmpty else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "generate_join_code returned no code"]
            )
        }
        return code
    }

    /// The live RPC is `redeem_join_code(p_code)` (migration 004 +
    /// V0.18 bonus extension). Server is idempotent — re-redeeming
    /// for an existing member returns the room row without
    /// mutating points.
    func redeemJoinCode(code: String) async throws -> RedeemedRoom {
        let rows: [RedeemedRoom] = try await SupabaseClientProvider.shared
            .rpc("redeem_join_code", params: [
                "code": code
            ])
            .execute()
            .value
        guard let row = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "redeem_join_code returned no row"]
            )
        }
        return row
    }

    /// The live RPC is `get_room_members(p_room_id)` (migration
    /// 008). Returns one row per room member, host-first then
    /// alphabetical by display name.
    func fetchRoomMembers(roomId: UUID) async throws -> [Member] {
        let rows: [Member] = try await SupabaseClientProvider.shared
            .rpc("get_room_members", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
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

    // MARK: Seasons (M1.1)

    /// The live RPC `get_current_season(p_room_id)` (migration 039)
    /// returns the room's current season. The server prefers
    /// `status='ended'` over `'active'` so the `.seasonClose`
    /// transition surface renders correctly. Returns `nil` only
    /// for rooms that have never opened a season.
    func fetchCurrentSeason(roomId: UUID) async throws -> Season? {
        let rows: [Season] = try await SupabaseClientProvider.shared
            .rpc("get_current_season", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    /// The live RPC `get_season_awards(p_season_id)` (migration 039)
    /// returns the room's awards. Privacy boundary is enforced
    /// server-side via RLS: drowning rows are only returned to the
    /// recipient. Swift layer defensively filters drowning rows for
    /// other users as a belt-and-braces guard.
    func fetchSeasonAwards(seasonId: UUID) async throws -> [SeasonAward] {
        let rows: [SeasonAward] = try await SupabaseClientProvider.shared
            .rpc("get_season_awards", params: [
                "p_season_id": seasonId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    // MARK: Room packs (M4)

    /// The live RPC `get_room_packs(p_room_id)` (migration 041)
    /// returns the room's enabled pack slugs. Returns an empty
    /// array when no overrides exist — callers fall back to the
    /// global `PackRegistry.shared.allPacks` per the V0.8 brief.
    func fetchRoomPacks(roomId: UUID) async throws -> [String] {
        let rows: [String] = try await SupabaseClientProvider.shared
            .rpc("get_room_packs", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    /// The live RPC `update_room_packs(p_room_id, p_slugs text[])`
    /// (migration 041). Validates slugs server-side and emits one
    /// `room_system_events` row per removed pack so the briefing
    /// banner surfaces the change. Throws on non-host writes
    /// (RLS denial 42501) or invalid slugs (errcode 22023).
    func updateRoomPacks(roomId: UUID, slugs: [String]) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("update_room_packs", params: UpdateRoomPacksParams(
                p_room_id: roomId.uuidString,
                p_slugs: slugs
            ))
            .execute()
            .value as Void
    }

    /// The live RPC `get_room_system_events(p_room_id)` (migration 041)
    /// returns the room's unread system events. RLS already
    /// scopes this to the calling user, so no further filtering
    /// is needed.
    func fetchRoomSystemEvents(roomId: UUID) async throws -> [RoomSystemEvent] {
        let rows: [RoomSystemEvent] = try await SupabaseClientProvider.shared
            .rpc("get_room_system_events", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    /// The live RPC `acknowledge_system_event(p_event_id)` (migration 041)
    /// sets `acknowledged_at = now()` on the row. RLS gates the
    /// update to room members.
    func acknowledgeSystemEvent(eventId: UUID) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("acknowledge_system_event", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value as Void
    }

    // MARK: Drowning opt-in (V0.9 Wave 1 Slice 1.1)

    /// The live RPC is `set_drowning_opt_in(p_room_id, p_opt_in)`
    /// (migration 045). Returns nothing on success. The
    /// `set_drowning_opt_in` RPC is security-definer and gated by
    /// RLS so the caller can only update their own membership row.
    func setDrowningOptIn(roomId: UUID, optIn: Bool) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_drowning_opt_in", params: SetDrowningOptInParams(
                p_room_id: roomId.uuidString,
                p_opt_in: optIn
            ))
            .execute()
            .value as Void
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

    // MARK: Host journal (P1.5)

    /// The live RPC is `update_host_journal(p_room_id, p_journal)`
    /// (migration 036). Server enforces host-only writes and the
    /// 280-char length cap. The wrapper reads back the room row so
    /// the UI can mirror the persisted value.
    func updateHostJournal(roomId: UUID, journal: String?) async throws -> Room {
        let rows: [Room] = try await SupabaseClientProvider.shared
            .rpc("update_host_journal", params: [
                "p_room_id": roomId.uuidString,
                "p_journal": journal ?? ""
            ])
            .execute()
            .value
        guard let room = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "update_host_journal returned no row"]
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
actor InMemoryRoomStore: RoomStore {

    /// The shared in-memory store. All `RoomService` callers that
    /// don't pass a custom `RoomStore` end up here.
    static let shared = InMemoryRoomStore()

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

    /// Map of `roomId → current season`. M1.1 — every seeded room
    /// starts with an active season; the V0.8 brief's
    /// `seasonScore` lives on `room_memberships` but the `seasons`
    /// + `season_awards` schema is what drives the awards-card
    /// surface.
    private var currentSeasons: [UUID: Season]

    /// Map of `seasonId → awards rows`. M1.1.
    private var seasonAwards: [UUID: [SeasonAward]]

    /// Map of `roomId → enabled pack slugs`. M4. Empty when a
    /// room has no pack overrides — callers fall back to the
    /// global `PackRegistry.shared.allPacks` per the V0.8 brief.
    private var roomPacks: [UUID: [String]]

    /// Map of `roomId → system events queue`. M4. Drives the
    /// briefing slot's "System" section.
    private var roomSystemEvents: [UUID: [RoomSystemEvent]]

    /// Default pack set every room starts with when there's no
    /// explicit override. Matches the V0.8 brief's "all 4 packs
    /// pre-installed" position.
    private static let defaultInstalledPacks: [String] = [
        "casino",
        "cards_against_humanity",
        "monopoly_deal",
        "pluto_chess"
    ]

    /// M4 — public read accessor for the default. Callers that
    /// receive an empty `fetchRoomPacks` array use this as the
    /// fallback shelf.
    nonisolated var defaultInstalledPacks: [String] { Self.defaultInstalledPacks }

    /// Map of `(eventId, memberId) → rsvp state`.
    private var rsvps: [UUID: [UUID: MemberRSVPState]]

    /// Map of `join_code → roomId` for the in-memory analogue of
    /// the `public.join_codes` table. Codes are minted by
    /// `generateJoinCode(roomId:)` and consumed (removed) by
    /// `redeemJoinCode(code:)`. Powers the P0.2 onboarding
    /// create-room + join-code surfaces without Supabase.
    private var joinCodes: [String: UUID]

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
        self.joinCodes = [:]

        // M1.1 — seed every room with an active season so the
        // V0State resolver has a season to read. Seed two rooms
        // (pluto + felt) with `status = .ended` to exercise the
        // `.seasonClose` branch on RoomDetailView.
        let plutoSeason = Season(
            id: UUID(),
            roomId: pluto.id,
            ordinal: 1,
            subtitle: "The Long River",
            status: .ended,
            startedAt: Date().addingTimeInterval(-86_400 * 60),
            endedAt: Date().addingTimeInterval(-86_400 * 3)
        )
        let feltSeason = Season(
            id: UUID(),
            roomId: felt.id,
            ordinal: 4,
            subtitle: "Felt Faction — Season 4",
            status: .ended,
            startedAt: Date().addingTimeInterval(-86_400 * 200),
            endedAt: Date().addingTimeInterval(-86_400 * 7)
        )
        let carwoolaSeason = Season(
            id: UUID(),
            roomId: carwoola.id,
            ordinal: 3,
            subtitle: "Borat's Big Year",
            status: .active,
            startedAt: Date().addingTimeInterval(-86_400 * 30),
            endedAt: nil
        )
        self.currentSeasons = [
            carwoola.id: carwoolaSeason,
            pluto.id: plutoSeason,
            felt.id: feltSeason
        ]

        // Seed awards for the two `.ended` seasons so the awards
        // card renders with real rows. Per Q-DROWNING lean, the
        // drowning row is included in the seed so privacy filtering
        // is exercised end-to-end in previews. The current-user
        // id is the carwoola host so the drowning row is for a
        // different member.
        let otherMemberId = UUID()
        let hostUserId = carwoola.createdBy
        self.seasonAwards = [
            plutoSeason.id: [
                SeasonAward(
                    id: UUID(),
                    seasonId: plutoSeason.id,
                    roomId: pluto.id,
                    recipientUserId: pluto.createdBy,
                    recipientDisplayName: "Felix",
                    awardType: .veteran,
                    caption: "Played every Sunday for 8 weeks.",
                    awardedAt: Date().addingTimeInterval(-86_400 * 3)
                ),
                SeasonAward(
                    id: UUID(),
                    seasonId: plutoSeason.id,
                    roomId: pluto.id,
                    recipientUserId: otherMemberId,
                    recipientDisplayName: "Sam",
                    awardType: .drowning,
                    caption: "Came back every week. Kept showing up.",
                    awardedAt: Date().addingTimeInterval(-86_400 * 3)
                )
            ],
            feltSeason.id: [
                SeasonAward(
                    id: UUID(),
                    seasonId: feltSeason.id,
                    roomId: felt.id,
                    recipientUserId: felt.createdBy,
                    recipientDisplayName: "Felty",
                    awardType: .phoenix,
                    caption: "Climbed 4 ranks across the season.",
                    awardedAt: Date().addingTimeInterval(-86_400 * 7)
                ),
                SeasonAward(
                    id: UUID(),
                    seasonId: feltSeason.id,
                    roomId: felt.id,
                    recipientUserId: hostUserId,
                    recipientDisplayName: "Borat",
                    awardType: .whale,
                    caption: "Single-session record: +580.",
                    awardedAt: Date().addingTimeInterval(-86_400 * 7)
                )
            ]
        ]
        _ = hostUserId // suppress unused-let warning if compiler is strict

        // M4 — seed every room with the default pack set so the
        // shelf contract from before the migration stays intact.
        // The host can remove packs later via the settings
        // Operations sub-sheet's updateRoomPacks call.
        self.roomPacks = [
            carwoola.id: Self.defaultInstalledPacks,
            pluto.id: Self.defaultInstalledPacks,
            felt.id: Self.defaultInstalledPacks
        ]
        self.roomSystemEvents = [:]
    }

    // MARK: Rooms list

    func fetchRooms() async throws -> [Room] {
        return rooms
    }

    // MARK: Create room + join codes (P0.2 onboarding)

    /// Synthesises a new room with the calling user as host and
    /// inserts it into the seed list. The `currentSyntheticMemberId()`
    /// pattern from the RSVP write path carries over — the in-memory
    /// store has no real auth context so the host is the synthetic
    /// member. Used by `RoomService.createRoom` so the empty-state
    /// create-room flow works without Supabase.
    func createRoom(
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        joinStartingBonus: Int,
        mascotApiKey: String?,
        blacklistedUserIds: [UUID]
    ) async throws -> UUID {
        let ownerId = currentSyntheticMemberId()
        let newRoom = Room(
            id: UUID(),
            name: name,
            mascotName: mascotName,
            mascotPersonality: mascotPersonality,
            mascotPoliticalIdeology: mascotPoliticalIdeology,
            createdBy: ownerId,
            createdAt: Date(),
            updatedAt: Date(),
            isLive: false,
            nextEventDescription: nil,
            joinStartingBonus: joinStartingBonus,
            mascotApiKey: mascotApiKey,
            userRole: .host,
            briefing48hEnabled: true,
            calendarAutoAddHost: false,
            socialPreferencesEnabled: true,
            socialNarrationEnabled: true,
            maxSeats: 6,
            memberInviteQuota: 3
        )
        rooms.insert(newRoom, at: 0)
        _ = blacklistedUserIds // in-memory; blacklist is server-only
        return newRoom.id
    }

    /// Synthesises a six-character join code from the same alphabet
    /// the live RPC uses (31 chars, no ambiguous glyphs) and stores
    /// it in the in-memory `joinCodes` map. Code collisions across
    /// in-memory rooms are vanishingly rare at MVP scope (31^6 ≈ 887M
    /// combinations) but we still loop with a uniqueness check so
    /// the test suite can't flake.
    func generateJoinCode(roomId: UUID) async throws -> String {
        let alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        guard rooms.contains(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \(roomId) not found"]
            )
        }
        var code = ""
        for _ in 0..<6 {
            let idx = Int.random(in: 0..<alphabet.count)
            let char = alphabet[alphabet.index(alphabet.startIndex, offsetBy: idx)]
            code.append(char)
        }
        joinCodes[code] = roomId
        return code
    }

    /// Synthesises a redeem flow: looks up the in-memory code,
    /// synthesises a membership row, returns a `RedeemedRoom`. The
    /// re-redeem case (already a member) returns the room without
    /// mutating state — mirrors the live server's idempotency.
    func redeemJoinCode(code: String) async throws -> RedeemedRoom {
        let normalised = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let roomId = joinCodes[normalised] else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Code not found or already redeemed"]
            )
        }
        guard let room = rooms.first(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Room not found"]
            )
        }
        // Mark the code consumed so a second tap reports the
        // "already redeemed" path. Mirrors the live redeem_join_code
        // row update.
        joinCodes.removeValue(forKey: normalised)
        return RedeemedRoom(roomId: room.id, roomName: room.name)
    }

    /// Returns one synthetic `Member` row per seeded room so the
    /// roster surface renders without Supabase. The host is always
    /// row 0 (matches the live `get_room_members` ordering: host
    /// first, then alphabetical). Used by `RoomService.fetchRoomMembers`.
    func fetchRoomMembers(roomId: UUID) async throws -> [Member] {
        guard let room = rooms.first(where: { $0.id == roomId }) else {
            return []
        }
        return [
            Member(
                id: "\(room.id.uuidString):\(room.createdBy.uuidString)",
                roomId: room.id,
                userId: room.createdBy,
                role: .host,
                joinedAt: room.createdAt,
                displayName: "Host"
            ),
            Member(
                id: "\(room.id.uuidString):synthetic-member-2",
                roomId: room.id,
                userId: UUID(),
                role: .member,
                joinedAt: room.createdAt.addingTimeInterval(86_400 * 7),
                displayName: "Alex"
            ),
            Member(
                id: "\(room.id.uuidString):synthetic-member-3",
                roomId: room.id,
                userId: UUID(),
                role: .member,
                joinedAt: room.createdAt.addingTimeInterval(86_400 * 14),
                displayName: "Sam"
            )
        ]
    }

    // MARK: Active event

    func fetchActiveEvent(roomId: UUID) async throws -> Event? {
        return events[roomId]
    }

    // MARK: Briefing

    func fetchBriefing(eventId: UUID) async throws -> BriefingSummary? {
        return briefings[eventId]
    }

    // MARK: Leaderboard

    func fetchLeaderboard(roomId: UUID) async throws -> [LeaderboardEntry] {
        return leaderboards[roomId] ?? []
    }

    // MARK: Seasons (M1.1)

    func fetchCurrentSeason(roomId: UUID) async throws -> Season? {
        return currentSeasons[roomId]
    }

    func fetchSeasonAwards(seasonId: UUID) async throws -> [SeasonAward] {
        return seasonAwards[seasonId] ?? []
    }

    // MARK: Room packs (M4)

    /// M4 — returns the pack slugs installed in this room. The
    /// in-memory store seeds every room with all four V0.8
    /// packs so the shelf contract from before the migration
    /// stays intact. Callers can fall back to the global
    /// `PackRegistry.shared.allPacks` when this returns an empty
    /// array.
    func fetchRoomPacks(roomId: UUID) async throws -> [String] {
        return roomPacks[roomId] ?? defaultInstalledPacks
    }

    /// M4 — replace the room's enabled pack set. The in-memory
    /// store just stores the slugs verbatim; the live RPC
    /// validates against `public.packs`. Throws on missing
    /// slugs so the UI surfaces an error rather than silently
    /// dropping the request.
    func updateRoomPacks(roomId: UUID, slugs: [String]) async throws {
        // Validate every slug against PackRegistry. The live
        // RPC does this server-side; the in-memory store
        // mirrors the contract.
        let knownSlugs = Set(PackRegistry.shared.allPacks.map(\.slug))
        for slug in slugs {
            if !knownSlugs.contains(slug) {
                throw NSError(
                    domain: "InMemoryRoomStore",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Unknown pack slug: \(slug)"]
                )
            }
        }
        guard rooms.contains(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \(roomId) not found"]
            )
        }
        roomPacks[roomId] = slugs
    }

    /// M4 — returns the room's unread system events. Empty
    /// array when no events. The live impl queries
    /// `public.room_system_events` filtered by `acknowledged_at
    /// IS NULL`.
    func fetchRoomSystemEvents(roomId: UUID) async throws -> [RoomSystemEvent] {
        return roomSystemEvents[roomId] ?? []
    }

    /// M4 — marks one system event acknowledged. The live impl
    /// `UPDATE public.room_system_events SET acknowledged_at =
    /// now() WHERE id = $1 AND user_can_ack(...)`. RLS already
    /// gates the row, so the Swift layer doesn't need a
    /// pre-check.
    func acknowledgeSystemEvent(eventId: UUID) async throws {
        for (roomId, events) in roomSystemEvents {
            if let idx = events.firstIndex(where: { $0.id == eventId }) {
                var updated = events
                updated[idx] = RoomSystemEvent(
                    id: events[idx].id,
                    roomId: events[idx].roomId,
                    kind: events[idx].kind,
                    payload: events[idx].payload,
                    createdAt: events[idx].createdAt,
                    acknowledgedAt: Date()
                )
                roomSystemEvents[roomId] = updated
            }
        }
    }

    /// V0.9 Wave 1 Slice 1.1 - flips the drowning opt-in flag for
    /// the calling member in the in-memory store. The in-memory
    /// store tracks membership per user; this is a no-op on the
    /// room-by-room cache. The service-layer caller is responsible
    /// for refreshing the Room so the toggle reflects in the UI.
    func setDrowningOptIn(roomId: UUID, optIn: Bool) async throws {
        // No state to mutate - the opt-in flag lives on the
        // Room struct (decoded from get_my_rooms). The service
        // layer re-fetches the room after this call so the new
        // value surfaces.
        _ = (roomId, optIn)
    }

    // MARK: RSVP — read

    func fetchCurrentMemberRSVP(eventId: UUID) async throws -> MemberRSVPState {
        // The in-memory store has no notion of "the current user"
        // (the view layer passes a `currentUserId` for mutations,
        // not reads), so RSVP reads return `.unclaimed` until a
        // matching upsert has been issued. Views layer the
        // optimistic local state on top of this read.
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

    // MARK: Host journal (P1.5)

    /// In-memory analogue of `update_host_journal`. Updates the
    /// `hostJournal` field in place, returns the updated room. The
    /// 280-char cap is enforced client-side (the form view counts
    /// characters and refuses over-limit input) so the in-memory
    /// path doesn't need its own length check.
    func updateHostJournal(roomId: UUID, journal: String?) async throws -> Room {
        guard let idx = rooms.firstIndex(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \(roomId) not found"]
            )
        }
        let existing = rooms[idx]
        let updated = Room(
            id: existing.id,
            name: existing.name,
            mascotName: existing.mascotName,
            mascotPersonality: existing.mascotPersonality,
            mascotPoliticalIdeology: existing.mascotPoliticalIdeology,
            createdBy: existing.createdBy,
            createdAt: existing.createdAt,
            updatedAt: Date(),
            isLive: existing.isLive,
            nextEventDescription: existing.nextEventDescription,
            joinStartingBonus: existing.joinStartingBonus,
            mascotApiKey: existing.mascotApiKey,
            userRole: existing.userRole,
            briefing48hEnabled: existing.briefing48hEnabled,
            calendarAutoAddHost: existing.calendarAutoAddHost,
            socialPreferencesEnabled: existing.socialPreferencesEnabled,
            socialNarrationEnabled: existing.socialNarrationEnabled,
            maxSeats: existing.maxSeats,
            memberInviteQuota: existing.memberInviteQuota,
            hostJournal: journal
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