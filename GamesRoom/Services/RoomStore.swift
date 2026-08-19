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

struct SetNotificationsEnabledParams: Encodable, Sendable {
    let p_room_id: String
    let p_enabled: Bool
}

struct SetEventNotificationsMutedParams: Encodable, Sendable {
    let p_event_id: String
    let p_muted: Bool
}

struct GenerateInviteCodeParams: Encodable, Sendable {
    let p_room_id: String
}

struct ScopeJoinCodeParams: Encodable, Sendable {
    let p_code: String
    let p_invitee_user_id: String
}

struct ApproveTierTwoJoinParams: Encodable, Sendable {
    let p_room_id: String
    let p_user_id: String
    let p_remove: Bool
}

struct UpsertCasinoConfigParams: Encodable, Sendable {
    let p_room_id: String
    let p_enabled: Bool
    let p_chip_color_map: [String: Int]
    let p_standard_presets: Bool
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
        let id: UUID = try await SupabaseClientProvider.shared
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
        return id
    }

    /// The live RPC is `generate_join_code(p_room_id)` (migration
    /// 004 + V0.3 host-check extension). Returns the freshly-minted
    /// six-character code. Throws on non-host writes.
    func generateJoinCode(roomId: UUID) async throws -> String {
        let code: String = try await SupabaseClientProvider.shared
            .rpc("generate_join_code", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        guard !code.isEmpty else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "generate_join_code returned no code"]
            )
        }
        return code
    }

    /// V0.55 — mints a join code, then scopes it to the invitee when
    /// one is given (tier 3). The live RPCs are `generate_join_code`
    /// (migration 004) + `scope_join_code` (migration 068). When
    /// `inviteeUserId` is nil the code stays open (tier 1 host or
    /// tier 2 member, per the caller's role). Throws on non-member
    /// writes or a scope rejection.
    func generateInviteCode(roomId: UUID, inviteeUserId: UUID?) async throws -> String {
        let code: String = try await SupabaseClientProvider.shared
            .rpc("generate_join_code", params: GenerateInviteCodeParams(
                p_room_id: roomId.uuidString
            ))
            .execute()
            .value
        guard !code.isEmpty else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "generate_join_code returned no code"]
            )
        }
        if let inviteeUserId {
            _ = try await SupabaseClientProvider.shared
                .rpc("scope_join_code", params: ScopeJoinCodeParams(
                    p_code: code,
                    p_invitee_user_id: inviteeUserId.uuidString
                ))
                .execute()
                .value as Void
        }
        return code
    }

    /// V0.55 — host-only. Removes (or restores) a tier-2 join from
    /// the roster. The live RPC is `approve_tier_two_join` (migration
    /// 068): `remove: true` deletes the membership row, `false` is a
    /// no-op that leaves it. Throws on non-host calls.
    func approveTierTwoJoin(roomId: UUID, userId: UUID, remove: Bool) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("approve_tier_two_join", params: ApproveTierTwoJoinParams(
                p_room_id: roomId.uuidString,
                p_user_id: userId.uuidString,
                p_remove: remove
            ))
            .execute()
            .value as Void
    }

    /// The live RPC is `redeem_join_code(p_code)` (migration 004 +
    /// V0.18 bonus extension; param renamed `code` → `p_code` in
    /// migration 068). Server is idempotent — re-redeeming
    /// for an existing member returns the room row without
    /// mutating points.
    func redeemJoinCode(code: String) async throws -> RedeemedRoom {
        let rows: [RedeemedRoom] = try await SupabaseClientProvider.shared
            .rpc("redeem_join_code", params: [
                "p_code": code
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

    /// V0.76 — the caller's invite rewards in a room. Mirrors
    /// `get_my_invite_rewards(p_room_id)` (migration 076). Returns
    /// zeroed values when the caller has no rewards yet.
    func fetchMyInviteRewards(roomId: UUID) async throws -> InviteRewards {
        let rows: [InviteRewards] = try await SupabaseClientProvider.shared
            .rpc("get_my_invite_rewards", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows.first ?? InviteRewards(friendsJoined: 0, totalReward: 0)
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

    /// The live RPC `set_member_team(p_room_id, p_member_id, p_team)`
    /// (migration 049) assigns a member's team label. Empty string
    /// clears the assignment.
    func setMemberTeam(roomId: UUID, memberId: UUID, team: String?) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_member_team", params: [
                "p_room_id": roomId.uuidString,
                "p_member_id": memberId.uuidString,
                "p_team": team ?? ""
            ])
            .execute()
            .value
    }

    /// The live RPC `get_event_rounds(p_event_id)` (migration 049)
    /// returns the per-round submissions for one event, oldest round
    /// first. Room scope derives from the event (F-IDENT-01).
    func fetchEventRounds(eventId: UUID) async throws -> [EventRound] {
        let rows: [EventRound] = try await SupabaseClientProvider.shared
            .rpc("get_event_rounds", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    // MARK: Active event

    /// The live RPC is `get_active_event(p_room_id)` (migration 060,
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

    /// V0.82 — lazy auto-close (migration 080). The RPC returns the
    /// count of events closed; the client only needs success/failure.
    func autoCloseStaleEvents(roomId: UUID) async throws -> Int {
        let rows: [Int] = try await SupabaseClientProvider.shared
            .rpc("auto_close_stale_events", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows.first ?? 0
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

    /// The live RPC `close_season(p_room_id)` (migration 048)
    /// closes the room's active season, computes the four awards,
    /// resets season scores, opens the next season, and emits a
    /// `season_closed` system event. Returns the closed season.
    func closeSeason(roomId: UUID) async throws -> Season {
        let rows: [Season] = try await SupabaseClientProvider.shared
            .rpc("close_season", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        guard let closed = rows.first else {
            throw NSError(
                domain: "LiveRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "close_season returned no season"]
            )
        }
        return closed
    }

    /// The live RPC `get_season_history(p_room_id)` (migration
    /// 053) returns the room's ended seasons with the caller's
    /// total + rank in each, most recent first. Empty for rooms
    /// with no ended seasons or for non-members (membership guard
    /// is enforced server-side). Powers the US-10
    /// previous-seasons comparison surface.
    func fetchSeasonHistory(roomId: UUID) async throws -> [SeasonHistoryEntry] {
        let rows: [SeasonHistoryEntry] = try await SupabaseClientProvider.shared
            .rpc("get_season_history", params: [
                "p_room_id": roomId.uuidString
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

    // MARK: Quiet-by-default notifications (V0.54)

    /// The live RPC is `set_notifications_enabled(p_room_id,
    /// p_enabled)` (migration 066). Updates the caller's own
    /// `room_memberships.notifications_enabled` row; security-
    /// definer + the row-level RLS keep the update scoped to the
    /// caller. Returns nothing on success.
    func setNotificationsEnabled(roomId: UUID, enabled: Bool) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_notifications_enabled", params: SetNotificationsEnabledParams(
                p_room_id: roomId.uuidString,
                p_enabled: enabled
            ))
            .execute()
            .value as Void
    }

    /// The live RPC is `set_event_notifications_muted(p_event_id,
    /// p_muted)` (migration 066). Upserts the caller's
    /// `event_rsvps` row for the event with the given muted flag
    /// (insert with `state='unclaimed'` if absent, else update in
    /// place). Room scope derives from the event server-side
    /// (F-IDENT-01).
    func setEventNotificationsMuted(eventId: UUID, muted: Bool) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_event_notifications_muted", params: SetEventNotificationsMutedParams(
                p_event_id: eventId.uuidString,
                p_muted: muted
            ))
            .execute()
            .value as Void
    }

    // MARK: Seat-grid RSVP read (2026-08-10 feedback round)

    /// The live RPC is `get_event_rsvps(p_event_id)` (migration
    /// 047). Returns one row per room member with their RSVP state
    /// joined to the member's display name, host first then
    /// alphabetical. Throws on non-member reads.
    func fetchEventRSVPs(eventId: UUID) async throws -> [EventRSVP] {
        let rows: [EventRSVP] = try await SupabaseClientProvider.shared
            .rpc("get_event_rsvps", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    // MARK: Per-room pack payouts (2026-08-10 feedback round)

    /// The live RPC is `get_room_pack_configs(p_room_id)` (migration
    /// 047). Returns the room's payout overrides; packs without a
    /// row fall back to the pack's static `winPoints` default.
    func fetchRoomPackConfigs(roomId: UUID) async throws -> [RoomPackConfig] {
        let rows: [RoomPackConfig] = try await SupabaseClientProvider.shared
            .rpc("get_room_pack_configs", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    /// The live RPC is `set_room_pack_config(p_room_id, p_pack_slug,
    /// p_win_points)` (migration 047). Host-only; throws on
    /// non-host writes or unknown slugs.
    func setRoomPackConfig(roomId: UUID, packSlug: String, winPoints: Int) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_room_pack_config", params: [
                "p_room_id": roomId.uuidString,
                "p_pack_slug": packSlug,
                "p_win_points": String(winPoints)
            ])
            .execute()
            .value as Void
    }

    // MARK: Casino config (W-06, US-26)

    /// The live RPC is `get_casino_config(p_room_id)` (migration
    /// 014). Returns the room's casino config, or nil when the
    /// room has never been configured. The decoder's defensive
    /// fallbacks keep older rows alive (missing vision_* columns
    /// decode as defaults).
    func fetchCasinoConfig(roomId: UUID) async throws -> CasinoConfig? {
        let rows: [CasinoConfig] = try await SupabaseClientProvider.shared
            .rpc("get_casino_config", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    /// The live RPC is `upsert_casino_config(p_room_id, p_enabled,
    /// p_chip_color_map, p_standard_presets)` (migration 014).
    /// Host-only; throws on non-host writes (42501). The color map
    /// is encoded as the JSONB `{ "red": 7, ... }` object the
    /// `casino_room_config.chip_color_map` column stores.
    func updateCasinoConfig(
        roomId: UUID,
        enabled: Bool,
        chipColorMap: [ChipColor: Int],
        standardPresets: Bool
    ) async throws {
        let map = Dictionary(uniqueKeysWithValues: chipColorMap.map {
            ($0.key.rawValue, $0.value)
        })
        _ = try await SupabaseClientProvider.shared
            .rpc("upsert_casino_config", params: UpsertCasinoConfigParams(
                p_room_id: roomId.uuidString,
                p_enabled: enabled,
                p_chip_color_map: map,
                p_standard_presets: standardPresets
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
        let raw: String? = try await SupabaseClientProvider.shared
            .rpc("get_my_event_rsvp", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return raw.flatMap(MemberRSVPState.init(rawValue:)) ?? .unclaimed
    }

    // MARK: RSVP — write

    /// The live RPC is `upsert_event_rsvp(p_event_id, p_state)` per
    /// migration 033 (the `event_rsvps` table + its self-write RLS
    /// policies). Idempotent — re-issuing with the same state is a
    /// no-op; re-issuing with a different state overwrites in place.
    /// Throws on RLS rejection (non-member write attempt).
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP {
        // The RPC returns void — no row to decode. We construct a
        // MemberRSVP locally so the service layer's cache update
        // (rsvpByEvent[eventId] = row.state) still works. The real
        // RSVP row is fetched by the post-upsert loadEventRSVPs +
        // loadBriefing refresh in RoomService.
        _ = try await SupabaseClientProvider.shared
            .rpc("upsert_event_rsvp", params: [
                "p_event_id": eventId.uuidString,
                "p_state": state.rawValue
            ])
            .execute()
            .value as Void

        let callerId = try? await SupabaseClientProvider.shared.auth.session.user.id
        return MemberRSVP(
            id: UUID(),
            eventId: eventId,
            roomId: UUID(),
            memberId: callerId ?? UUID(),
            state: state,
            respondedAt: Date()
        )
    }

    // MARK: Event create

    /// The live RPC is `create_event(p_room_id, p_name, p_played_at,
    /// p_pack_slug)` (migration 006 + V0.8 pack-slug extension). The
    /// server creates the event row and returns the new id.
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let id: UUID = try await SupabaseClientProvider.shared
            .rpc("create_event", params: [
                "p_room_id": roomId.uuidString,
                "p_name": name,
                "p_played_at": formatter.string(from: playedAt),
                "p_pack_slug": packSlug
            ])
            .execute()
            .value
        return id
    }

    /// The live RPC `update_event_member_fields(p_event_id, p_note,
    /// p_venue)` (migration 050) lets any room member edit the
    /// event's pre-play note + venue. Empty strings clear the field.
    func updateEventMemberFields(eventId: UUID, note: String?, venue: String?) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("update_event_member_fields", params: [
                "p_event_id": eventId.uuidString,
                "p_note": note ?? "",
                "p_venue": venue ?? ""
            ])
            .execute()
            .value
    }

    /// The live RPC `write_chapter_line(p_event_id, p_title,
    /// p_call_forward)` (migration 051) writes the chapter line
    /// for a settled event. Upserts on unique(event_id).
    func writeChapterLine(eventId: UUID, title: String, callForward: String?) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("write_chapter_line", params: [
                "p_event_id": eventId.uuidString,
                "p_title": title,
                "p_call_forward": callForward ?? ""
            ])
            .execute()
            .value
    }

    /// The live RPC `get_event_chapter_line(p_event_id)` (migration
    /// 051) returns the chapter line for one event, or nil.
    func fetchEventChapterLine(eventId: UUID) async throws -> ChapterLine? {
        let rows: [ChapterLine] = try await SupabaseClientProvider.shared
            .rpc("get_event_chapter_line", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    /// The live RPC `set_season_subtitle(p_room_id, p_subtitle)`
    /// (migration 051) sets the active season's subtitle (host-only).
    func setSeasonSubtitle(roomId: UUID, subtitle: String?) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_season_subtitle", params: [
                "p_room_id": roomId.uuidString,
                "p_subtitle": subtitle ?? ""
            ])
            .execute()
            .value
    }

    // MARK: Room settings

    /// The live RPC is `delete_room(p_room_id)` (migration 052).
    /// Host-only; soft-deletes the room and expires open join
    /// codes. Throws on non-host calls (42501).
    func deleteRoom(roomId: UUID) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("delete_room", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value as Void
    }

    /// The live RPC is `update_room_settings(p_room_id, p_name,
    /// p_mascot_name, p_mascot_personality, p_mascot_political_ideology,
    /// p_max_seats, p_member_invite_quota, p_join_starting_bonus,
    /// p_social_narration_enabled, p_briefing_48h_enabled,
    /// p_calendar_auto_add_host, p_social_preferences_enabled,
    /// p_auto_close_hours)` (migration 020 + V0.8 extensions +
    /// V0.83 auto-close window). The server resolves the
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
        socialPreferencesEnabled: Bool,
        autoCloseHours: Int
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
                "p_social_preferences_enabled": String(socialPreferencesEnabled),
                "p_auto_close_hours": String(autoCloseHours)
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

    // MARK: - Tonight's Star + member notes (V0.84 C2 + C5)

    /// The live RPC is `get_tonight_star_card(p_event_id)`
    /// (migration 083). Returns the host pick when one exists;
    /// else the 067 chip-swing fallback with
    /// `override_category == nil`. Empty when neither has a
    /// winner.
    func fetchTonightStarCard(eventId: UUID) async throws -> TonightStarCard? {
        let rows: [TonightStarCard] = try await SupabaseClientProvider.shared
            .rpc("get_tonight_star_card", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value
        return rows.first
    }

    /// The live RPC is `set_tonight_star_pick(p_event_id,
    /// p_member_id, p_override_category, p_custom_text)` (migration
    /// 083). Host-only; upserts on `tonight_star_picks.unique(event_id)`.
    func setTonightStarPick(
        eventId: UUID,
        memberId: UUID,
        category: TonightStarOverrideCategory,
        customText: String?
    ) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("set_tonight_star_pick", params: [
                "p_event_id": eventId.uuidString,
                "p_member_id": memberId.uuidString,
                "p_override_category": category.rawValue,
                "p_custom_text": customText ?? ""
            ])
            .execute()
            .value as Void
    }

    /// The live RPC is `get_unconsumed_member_notes(p_room_id)`
    /// (migration 083). Host-only; oldest first.
    func fetchUnconsumedMemberNotes(roomId: UUID) async throws -> [RoomMemberNote] {
        let rows: [RoomMemberNote] = try await SupabaseClientProvider.shared
            .rpc("get_unconsumed_member_notes", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value
        return rows
    }

    /// The live RPC is `submit_member_note(p_room_id, p_note_text)`
    /// (migration 083). Server enforces trim-non-empty, ≤500 chars,
    /// at most one per calendar day per member.
    func submitMemberNote(roomId: UUID, noteText: String) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("submit_member_note", params: [
                "p_room_id": roomId.uuidString,
                "p_note_text": noteText
            ])
            .execute()
            .value as Void
    }

    /// The live RPC is `mark_member_notes_consumed(p_room_id,
    /// p_note_ids uuid[])` (migration 083). Host-only; stamps
    /// `consumed_by_host_at = now()` on the listed unconsumed notes.
    func markMemberNotesConsumed(roomId: UUID, noteIds: [UUID]) async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("mark_member_notes_consumed", params: [
                "p_room_id": roomId.uuidString,
                "p_note_ids": noteIds.map(\.uuidString)
            ])
            .execute()
            .value as Void
    }
}
