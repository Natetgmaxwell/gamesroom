import Foundation

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

    /// Host-only. Assigns (or clears, with an empty string) a
    /// member's team label for the season.
    ///
    /// Server side: `set_member_team(p_room_id, p_member_id, p_team)`
    /// (migration 049).
    func setMemberTeam(roomId: UUID, memberId: UUID, team: String?) async throws

    /// The per-round submissions for one event, oldest round first.
    /// Room scope derives from the event (F-IDENT-01).
    ///
    /// Server side: `get_event_rounds(p_event_id)` (migration 049).
    func fetchEventRounds(eventId: UUID) async throws -> [EventRound]

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

    /// Any room member may edit the event's pre-play note + venue
    /// while the event is still in the future. Empty strings clear
    /// the field. Room scope derives from the event (F-IDENT-01).
    ///
    /// Server side: `update_event_member_fields(p_event_id, p_note,
    /// p_venue)` (migration 050).
    func updateEventMemberFields(eventId: UUID, note: String?, venue: String?) async throws

    /// Any room member may write the chapter line for a settled
    /// event. Upserts on the event's unique chapter line.
    ///
    /// Server side: `write_chapter_line(p_event_id, p_title,
    /// p_call_forward)` (migration 051).
    func writeChapterLine(eventId: UUID, title: String, callForward: String?) async throws

    /// The chapter line for one event, or `nil` when none has been
    /// written. Room scope derives from the event (F-IDENT-01).
    ///
    /// Server side: `get_event_chapter_line(p_event_id)` (migration 051).
    func fetchEventChapterLine(eventId: UUID) async throws -> ChapterLine?

    /// Host-only. Sets the active season's subtitle — the
    /// host-approval beat for the mascot's proposed subtitle.
    /// Empty string clears it.
    ///
    /// Server side: `set_season_subtitle(p_room_id, p_subtitle)`
    /// (migration 051).
    func setSeasonSubtitle(roomId: UUID, subtitle: String?) async throws

    // MARK: Room settings

    /// Host-only. Soft-deletes the room (rooms.deleted_at) so the
    /// ledger survives for disputes, and expires all open join
    /// codes. Throws on non-host calls.
    ///
    /// Server side: `delete_room(p_room_id)` (migration 052).
    func deleteRoom(roomId: UUID) async throws

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

    /// Host-only. Closes the room's active season: computes the
    /// four season awards, resets season scores, opens the next
    /// season, and emits a `season_closed` system event. Returns
    /// the closed season.
    ///
    /// Server side: `close_season(p_room_id)` (migration 048).
    func closeSeason(roomId: UUID) async throws -> Season

    // MARK: Season history (W-05, US-10)

    /// The room's ended seasons with the caller's total and rank
    /// in each, most recent first. Drives the previous-seasons
    /// comparison ("improving over time"). Empty when the room
    /// has no ended seasons or when the caller is not a member.
    ///
    /// Server side: `get_season_history(p_room_id)` (migration 053).
    func fetchSeasonHistory(roomId: UUID) async throws -> [SeasonHistoryEntry]

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

    // MARK: Seat-grid RSVP read (2026-08-10 feedback round)

    /// One row per room member with their RSVP state for the
    /// event, joined to the member's display name. Mirrors
    /// `get_event_rsvps(p_event_id)` (migration 047). Powers the
    /// briefing slot's seat grid — which chairs are claimed, by
    /// whom, and which are open. Throws on non-member reads.
    func fetchEventRSVPs(eventId: UUID) async throws -> [EventRSVP]

    // MARK: Per-room pack payouts (2026-08-10 feedback round)

    /// Returns the room's payout overrides for every pack that has
    /// one. Mirrors `get_room_pack_configs(p_room_id)` (migration
    /// 047). Packs without a row fall back to the pack's static
    /// `winPoints` default.
    func fetchRoomPackConfigs(roomId: UUID) async throws -> [RoomPackConfig]

    /// Host-only upsert of one pack's payout for a room. Mirrors
    /// `set_room_pack_config(p_room_id, p_pack_slug, p_win_points)`
    /// (migration 047). Throws on non-host writes or unknown slugs.
    func setRoomPackConfig(roomId: UUID, packSlug: String, winPoints: Int) async throws

    // MARK: Casino config (W-06, US-26)

    /// The room's casino config, or `nil` when the room has never
    /// been configured (callers fall back to standard presets).
    ///
    /// Server side: `get_casino_config(p_room_id)` (migration 014).
    func fetchCasinoConfig(roomId: UUID) async throws -> CasinoConfig?

    /// Host-only upsert of the room's casino config. Mirrors
    /// `upsert_casino_config(p_room_id, p_enabled, p_chip_color_map,
    /// p_standard_presets)` (migration 014). Throws on non-host
    /// writes.
    func updateCasinoConfig(
        roomId: UUID,
        enabled: Bool,
        chipColorMap: [ChipColor: Int],
        standardPresets: Bool
    ) async throws
}
