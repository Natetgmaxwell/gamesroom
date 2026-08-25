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
    /// p_join_starting_bonus, p_mascot_api_key)` RPC (migration
    /// 022, simplified in V0.94 — the per-room blacklist parameter
    /// was removed in V0.94; per-event hidden members is the new
    /// mechanism, on the events table).
    /// Returns the new room id; the caller should refresh the
    /// rooms list so the hero/empty state re-renders.
    func createRoom(
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        joinStartingBonus: Int,
        mascotApiKey: String?
    ) async throws -> UUID

    /// Mints a fresh 6-character join code for a room the caller
    /// hosts. Mirrors `generate_join_code(p_room_id)` (migration
    /// 004 + 006 host check). Throws on non-host writes.
    func generateJoinCode(roomId: UUID) async throws -> String

    /// V0.55 — mints a join code for a room, optionally scoped to a
    /// specific invitee. Mirrors `generate_join_code(p_room_id)`
    /// (migration 004) + the migration-068 invitee scope. When
    /// `inviteeUserId` is non-nil the code is tier 3 (usable only by
    /// that user); when nil it is a host (tier 1) or member (tier 2)
    /// code depending on the caller's role. Throws on non-member
    /// writes.
    func generateInviteCode(roomId: UUID, inviteeUserId: UUID?) async throws -> String

    /// V0.55 — host-only. Removes (or restores) a tier-2 join from
    /// the roster. Because tier-2 joins are live immediately (low
    /// friction, substrate 1.3), the "approval" is a host one-tap
    /// remove: `remove: true` deletes the membership row, `false`
    /// leaves it. Mirrors the host-remove path on
    /// `room_memberships` (migration 004 host-can-remove policy).
    /// Throws on non-host calls.
    func approveTierTwoJoin(roomId: UUID, userId: UUID, remove: Bool) async throws

    /// Redeems a join code on behalf of the calling user. Mirrors
    /// `redeem_join_code(p_code)` (migration 004 + V0.18 bonus
    /// extension). Idempotent: re-redeeming for an existing member
    /// returns the room without mutating points. Throws on
    /// not-found / already-redeemed / RLS rejection (the iOS UI
    /// maps these to user-facing error strings).
    func redeemJoinCode(code: String) async throws -> RedeemedRoom

    /// V0.76 — the caller's invite rewards in a room: how many
    /// friends joined via their codes and the total points earned.
    /// Mirrors `get_my_invite_rewards(p_room_id)` (migration 076).
    /// Returns zeroed values when the caller has no rewards yet.
    func fetchMyInviteRewards(roomId: UUID) async throws -> InviteRewards

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

    /// V0.91 — host-only. Promotes a member to host or demotes a
    /// host back to member. Multi-host is allowed; a room must
    /// always have at least one host, so demoting the last host
    /// fails server-side with `last_host`.
    ///
    /// `action` is one of `.promote` / `.demote`. The caller must
    /// already be a host in `roomId`; otherwise the RPC raises
    /// `not_authorized`. The target must already be a member of
    /// `roomId`; otherwise the RPC raises `not_found`.
    ///
    /// Returns the full room roster so the iOS client can rebuild
    /// the members cache from a single round-trip.
    ///
    /// Server side: `transfer_host_role(p_room_id, p_target_user_id,
    /// p_action)` (migration 091).
    func transferHostRole(
        roomId: UUID,
        targetUserId: UUID,
        action: HostRoleAction
    ) async throws -> [Member]

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

    /// V0.82 — lazy auto-close. Stamps `settled_at` on the room's
    /// events whose night passed 24h ago and were never settled.
    /// Idempotent; member-gated. Returns the number of events
    /// closed. Server side: `auto_close_stale_events(p_room_id)`
    /// (migration 080).
    func autoCloseStaleEvents(roomId: UUID) async throws -> Int

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
    /// `hiddenFromUserIds` is the V0.94 per-event hidden-members
    /// list — members on it don't see the event or receive its
    /// briefing push. Empty by default.
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String, hiddenFromUserIds: [UUID]) async throws -> UUID

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
    /// nonhost-write rejection.
    ///
    /// V0.86 — dropped `calendarAutoAddHost` (per-room toggle is
    /// gone; the calendar mirror moved to a per-user surface
    /// handled by `setMemberCalendarAutoAdd`).
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
        socialPreferencesEnabled: Bool,
        autoCloseHours: Int,
        seatDepositAmount: Int,
        seatDepositTrigger: SeatDepositTrigger,
        seatDepositGraceMinutes: Int
    ) async throws -> Room

    // MARK: Calendar (V0.86 — per-member toggle + server-side identifier)

    /// V0.86 — flips the caller's own
    /// `room_memberships.calendar_auto_add` across EVERY room they
    /// belong to (per-user toggle, NOT per-room). Mirrors migration
    /// 087's `set_member_calendar_auto_add(p_enabled boolean)` RPC.
    /// Idempotent. Throws on auth failure (42501).
    func setMemberCalendarAutoAdd(enabled: Bool) async throws

    /// V0.86 — caller's EventKit row identifier for one of their
    /// room's events so the server can map back to the EKEvent on
    /// update/delete. Persisted into
    /// `events.event_calendar_identifier`. Idempotent (a second
    /// call overwrites with the latest identifier). Mirrors
    /// migration 087's `report_calendar_identifier(p_event_id,
    /// p_identifier)` RPC.
    func reportCalendarIdentifier(eventId: UUID, identifier: String) async throws

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

    // MARK: Quiet-by-default notifications (V0.54)

    /// Flips `room_memberships.notifications_enabled` for the
    /// calling member's own row in this room. Mirrors the
    /// `set_drowning_opt_in` pattern (migration 045): SQL RLS keeps
    /// the update scoped to the caller's own row; the dedicated
    /// `set_notifications_enabled` RPC keeps the contract explicit.
    /// The service-layer caller mirrors the update into the
    /// `rooms` cache so the toggle re-renders immediately.
    func setNotificationsEnabled(roomId: UUID, enabled: Bool) async throws

    /// Flips `event_rsvps.notifications_muted` for the calling
    /// member's own row on this event. Mirrors the upsert shape of
    /// the migration-066 `set_event_notifications_muted` RPC —
    /// inserts the caller's row with `state='unclaimed'` and the
    /// given muted flag if absent, else updates in place. Room
    /// scope derives from the event (F-IDENT-01).
    func setEventNotificationsMuted(eventId: UUID, muted: Bool) async throws

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

    // MARK: Seat deposit escrow (V0.85 — migration 085)

    /// V0.85 — member. Claims the seat and moves the room's seat
    /// deposit from points_balance into escrow (held
    /// seat_deposits row + RSVP claim in one transaction).
    /// Mirrors `claim_seat_with_deposit(p_event_id)` (migration
    /// 085). Fails 42501 when balance < amount. Idempotent per
    /// (event, member).
    func claimSeatWithDeposit(eventId: UUID) async throws

    /// V0.85 — host-only broke-member path. Claims the seat with
    /// a zero-amount held deposit row so the arrival card still
    /// tracks the seat. Mirrors `claim_seat_waived(p_event_id,
    /// p_member_id)` (migration 085). Idempotent.
    func claimSeatWaived(eventId: UUID, memberId: UUID) async throws

    /// V0.85 — member. The "I'm here" tap: the held deposit
    /// returns to points_balance instantly. The reclaim IS the
    /// attendance check-in. Mirrors `check_in_seat(p_event_id)`
    /// (migration 085). Idempotent.
    func checkInSeat(eventId: UUID) async throws

    /// V0.85 — host-only. Returns one row per held deposit
    /// (claimed, no check-in, no play transaction) at session
    /// start — the arrival card source. Mirrors
    /// `list_arrival_candidates(p_event_id)` (migration 085).
    /// Throws on non-host reads.
    func loadArrivalCandidates(eventId: UUID) async throws -> [SeatDepositCandidate]

    /// V0.85 — host-only. The confirmed no-show call: the held
    /// deposit stays out, status forfeited, ledger row carries
    /// the destination meta. Mirrors `forfeit_seat_deposit(
    /// p_event_id, p_member_id)` (migration 085). Idempotent.
    func forfeitSeatDeposit(eventId: UUID, memberId: UUID) async throws

    /// V0.85 — host-only. Returns a held deposit without the
    /// member's tap (texted / away / arrived-unscanned). Mirrors
    /// `waive_seat_deposit(p_event_id, p_member_id)` (migration
    /// 085). Idempotent.
    func waiveSeatDeposit(eventId: UUID, memberId: UUID) async throws

    /// V0.85 — the caller's seat deposit for an event, or nil
    /// when none exists. Mirrors `get_my_seat_deposit_status(
    /// p_event_id)` (migration 085 — replaces 043's dropped
    /// variant). Read-only; drives the chair card's held state.
    func fetchMySeatDeposit(eventId: UUID) async throws -> SeatDeposit?

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

    // MARK: - Tonight's Star + member notes (V0.84 C2 + C5)

    /// Reads Tonight's Star card for one event. Returns the host
    /// pick when one exists; else the 067 chip-swing default with
    /// `overrideCategory == nil`. Empty (`nil`) when neither path
    /// has a winner.
    ///
    /// Server side: `get_tonight_star_card(p_event_id)` (migration 083).
    func fetchTonightStarCard(eventId: UUID) async throws -> TonightStarCard?

    /// Host-only. Upserts the host's Tonight's Star pick for an
    /// event. Validates `custom ⇒ customText` non-empty; nulls it
    /// otherwise. Throws on non-host calls or unknown members.
    ///
    /// Server side: `set_tonight_star_pick(p_event_id, p_member_id,
    /// p_override_category, p_custom_text)` (migration 083).
    func setTonightStarPick(
        eventId: UUID,
        memberId: UUID,
        category: TonightStarOverrideCategory,
        customText: String?
    ) async throws

    /// Host-only. Reads the room's unconsumed member notes,
    /// oldest first. Empty when the host has read everything
    /// or when there are no notes yet.
    ///
    /// Server side: `get_unconsumed_member_notes(p_room_id)` (migration 083).
    func fetchUnconsumedMemberNotes(roomId: UUID) async throws -> [RoomMemberNote]

    /// Member writes one's own room_member_notes row. Server
    /// enforces trim-non-empty, ≤500 chars, at most one per
    /// calendar day.
    ///
    /// Server side: `submit_member_note(p_room_id, p_note_text)` (migration 083).
    func submitMemberNote(roomId: UUID, noteText: String) async throws

    /// Host-only. Stamps `consumed_by_host_at = now()` on the
    /// listed notes belonging to the room.
    ///
    /// Server side: `mark_member_notes_consumed(p_room_id,
    /// p_note_ids uuid[])` (migration 083).
    func markMemberNotesConsumed(roomId: UUID, noteIds: [UUID]) async throws
}

/// V0.91 — the role-change action the host applies to a room
/// member via `transferHostRole(roomId:targetUserId:action:)`.
/// `rawValue` is the `p_action` string passed to the
/// `transfer_host_role` RPC (migration 091).
enum HostRoleAction: String {
    case promote
    case demote
}

/// V0.91 — synthetic errors the in-memory store raises so the
/// iOS UI can exercise the same error paths in previews as in
/// production. Live errors come through as `NSError` from the
/// Supabase client (Postgres raises `RAISE EXCEPTION ... USING
/// ERRCODE = ...`; the client surfaces them with the message in
/// `localizedDescription`). The service-side mapping in
/// `RoomService.transferHostRole` parses those strings; this enum
/// is the in-memory-only counterpart that throws typed errors
/// directly so callers can pattern-match on them.
enum HostRoleTransferError: Error, LocalizedError, Equatable {
    case lastHost
    case notAuthorized
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .lastHost:
            return "A room must always have at least one host."
        case .notAuthorized:
            return "You're not a host in this room."
        case .notFound(let detail):
            return detail
        }
    }
}
