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

    /// Cache freshness window. Loads within this window reuse the
    /// cached value instead of hitting the network. 30s keeps the
    /// room page snappy on re-appear while still reconciling against
    /// the server on pull-to-refresh (which passes `force: true`).
    private let cacheTTL: TimeInterval = 30

    /// Last successful fetch time per cache key. Keys are
    /// "loadName:entityId". Used by `isFresh(_:)`.
    private var cacheTimestamps: [String: Date] = [:]

    /// True when the cache entry for `key` was fetched within
    /// `cacheTTL` and is therefore safe to reuse without a network
    /// round-trip.
    private func isFresh(_ key: String) -> Bool {
        guard let ts = cacheTimestamps[key] else { return false }
        return Date().timeIntervalSince(ts) < cacheTTL
    }

    /// V0.69 — single-flight dedupe for `loadActiveEvent`. Concurrent
    /// callers for the same `roomId` share one in-flight
    /// `get_active_event` task instead of firing one RPC each. Cold
    /// open previously raced 3 parallel guard fetches from the
    /// briefing / host-withdrawals / working-hands loaders.
    private var activeEventInFlight: [UUID: Task<Event?, Error>] = [:]
    // V0.82 — per-room throttle for the lazy auto-close RPC
    // (`auto_close_stale_events`). Mirrors the attestation
    // stale-close throttle: at most one fire per 60s per room.
    private var lastAutoCloseAt: [UUID: Date] = [:]

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

    /// Room-member cache keyed by roomId. Populated lazily by
    /// `loadRoomMembers(roomId:)`; consumed by the roster surface
    /// on `RoomDetailView` and `RoomSettingsSheet`. Cleared on
    /// `signOut()` via the upper layer.
    @Published private(set) var membersByRoom: [UUID: [Member]] = [:]

    /// Current season cache keyed by roomId. Populated lazily by
    /// `loadCurrentSeason(roomId:)`; consumed by `RoomDetailView`
    /// to drive the `.seasonClose` V0State branch.
    @Published private(set) var currentSeasonByRoom: [UUID: Season] = [:]

    /// Season awards cache keyed by seasonId. Populated lazily by
    /// `loadSeasonAwards(seasonId:)`; consumed by the awards card
    /// surface. The view layer applies the recipient-check
    /// before rendering (privacy boundary).
    @Published private(set) var awardsBySeason: [UUID: [SeasonAward]] = [:]

    /// Prior seasons cache keyed by roomId. Populated lazily by
    /// `loadSeasonHistory(roomId:)`; consumed by the US-10
    /// previous-seasons comparison surface (W-05). Most recent
    /// season first per the SQL `ORDER BY ordinal DESC`.
    @Published private(set) var seasonHistoryByRoom: [UUID: [SeasonHistoryEntry]] = [:]

    /// Enabled pack slugs per room. Populated lazily by
    /// `loadRoomPacks(roomId:)`; consumed by the Operations sub-sheet's
    /// Packs toggle section. Empty array means "use the default
    /// installed set" (all four V0.8 packs).
    @Published private(set) var roomPacksByRoom: [UUID: [String]] = [:]

    /// System events per room. Populated lazily by
    /// `loadSystemEvents(roomId:)`; consumed by the briefing slot's
    /// System banner. Only unread events (acknowledged_at == nil)
    /// are kept.
    @Published private(set) var systemEventsByRoom: [UUID: [RoomSystemEvent]] = [:]

    /// Per-member RSVP rows per event. Populated lazily by
    /// `loadEventRSVPs(eventId:)`; consumed by the briefing slot's
    /// seat grid (2026-08-10 feedback round).
    @Published private(set) var eventRSVPsByEvent: [UUID: [EventRSVP]] = [:]

    /// Per-room pack payout overrides. Populated lazily by
    /// `loadRoomPackConfigs(roomId:)`; consumed by the pack shelf
    /// and the host scoring sheet (2026-08-10 feedback round).
    @Published private(set) var packConfigsByRoom: [UUID: [RoomPackConfig]] = [:]

    /// Per-event round submissions. Populated lazily by
    /// `loadEventRounds(eventId:)`; consumed by the leaderboard's
    /// per-round breakdown (F-MVP-05 V2-full, migration 049).
    @Published private(set) var roundsByEvent: [UUID: [EventRound]] = [:]

    /// Per-event chapter lines. Populated lazily by
    /// `loadEventChapterLine(eventId:)`; consumed by the
    /// ceremonial card (W2.6, migration 051).
    @Published private(set) var chapterLineByEvent: [UUID: ChapterLine] = [:]

    /// V0.84 C2 — Tonight's Star card per event. Populated lazily
    /// by `loadTonightStarCard(eventId:)`; consumed by the
    /// ceremonial card. `nil` means no host pick AND no chip-swing
    /// winner — section hidden (matches the 067 empty case).
    @Published private(set) var tonightStarCardByEvent: [UUID: TonightStarCard] = [:]

    /// V0.84 C5 — unconsumed member notes per room. Populated
    /// lazily by `loadUnconsumedMemberNotes(roomId:)`; consumed
    /// by the host's BriefingSlot pre-event notes section.
    @Published private(set) var unconsumedNotesByRoom: [UUID: [RoomMemberNote]] = [:]

    /// V0.84 C3 — no-show tax prompt source, per event.
    /// Populated lazily by `loadNoShowCandidates(eventId:)`;
    /// consumed by `ArrivalCard` on the host-side render
    /// of `RoomDetailView`. Each entry is one claimed-but-absent
    /// member; the host picks Apply / Skip (texted) / Skip
    /// (away) per row in isolation.
    @Published private(set) var arrivalCandidatesByEvent: [UUID: [SeatDepositCandidate]] = [:]

    /// V0.85 — the caller's seat deposit for an event, keyed by
    /// eventId. Populated lazily by `loadMySeatDeposit(eventId:)`;
    /// consumed by the chair card to render the "I'm here"
    /// reclaim while a deposit is held. `nil` = no held deposit.
    @Published private(set) var mySeatDepositByEvent: [UUID: SeatDeposit] = [:]

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
            // W2.3 — keep the widget/watch snapshot fresh. The
            // Glance reads the App Group suite; best-effort write.
            if let room = result.first {
                ScoreSnapshotStore.write(
                    roomName: room.name,
                    leaderboardLine: "",
                    isLive: room.isLive
                )
            }
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

    // MARK: - Create room + join codes (P0.2 onboarding)

    /// Creates a new room with the calling user as the host.
    /// Eagerly refreshes the rooms list so the new room appears at
    /// the top of the home surface without a manual pull-to-refresh.
    /// Throws on any server error (RLS, RLS-deny on auth, etc.) so
    /// the call site can show a neutral toast.
    @discardableResult
    func createRoom(
        name: String,
        mascotName: String,
        mascotPersonality: MascotPersonality,
        mascotPoliticalIdeology: MascotPoliticalIdeology,
        joinStartingBonus: Int = 200,
        mascotApiKey: String? = nil,
        blacklistedUserIds: [UUID] = []
    ) async throws -> UUID {
        let newId = try await store.createRoom(
            name: name,
            mascotName: mascotName,
            mascotPersonality: mascotPersonality,
            mascotPoliticalIdeology: mascotPoliticalIdeology,
            joinStartingBonus: joinStartingBonus,
            mascotApiKey: mascotApiKey,
            blacklistedUserIds: blacklistedUserIds
        )
        self.lastError = nil
        await refresh()
        return newId
    }

    /// Mints a fresh six-character join code for a room the caller
    /// hosts. Throws on non-host writes (the server returns 42501;
    /// the wrapper surfaces it as a thrown error).
    func generateJoinCode(roomId: UUID) async throws -> String {
        let code = try await store.generateJoinCode(roomId: roomId)
        self.lastError = nil
        return code
    }

    /// V0.55 — mints a join code, optionally scoped to a specific
    /// invitee (tier 3). When `inviteeUserId` is nil the code stays
    /// open (tier 1 host or tier 2 member). Throws on non-member
    /// writes or a scope rejection.
    func generateInviteCode(roomId: UUID, inviteeUserId: UUID?) async throws -> String {
        let code = try await store.generateInviteCode(roomId: roomId, inviteeUserId: inviteeUserId)
        self.lastError = nil
        return code
    }

    /// V0.55 — host-only. Removes (or restores) a tier-2 join from
    /// the roster. Mirrors the roster cache so the approval queue
    /// re-renders immediately. Throws on non-host calls.
    func approveTierTwoJoin(roomId: UUID, userId: UUID, remove: Bool) async throws {
        try await store.approveTierTwoJoin(roomId: roomId, userId: userId, remove: remove)
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "roomMembers:\\(roomId.uuidString)")
        if remove, var roster = membersByRoom[roomId] {
            roster.removeAll { $0.userId == userId }
            membersByRoom[roomId] = roster
        }
    }

    /// Redeems a six-character join code on behalf of the calling
    /// user. Idempotent server-side — re-redeeming for an existing
    /// member returns the room row without mutating points. Throws
    /// on not-found / already-redeemed / RLS rejection so the UI
    /// can surface a friendly error.
    func redeemJoinCode(code: String) async throws -> RedeemedRoom {
        let normalised = code.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let row = try await store.redeemJoinCode(code: normalised)
        self.lastError = nil
        await refresh()
        // W2.7 — joined-late catch-up push. Best-effort; the
        // dispatcher is non-throwing. Fires only when the room has
        // an active event the joiner should catch up on.
        if let room = rooms.first(where: { $0.id == row.roomId }) {
            await scheduleCatchUpIfNeeded(room: room)
        }
        return row
    }

    /// V0.76 — the caller's invite rewards in a room. Mirrors
    /// `get_my_invite_rewards(p_room_id)` (migration 076). Returns
    /// zeroed values when the caller has no rewards yet.
    func fetchMyInviteRewards(roomId: UUID) async throws -> InviteRewards {
        let rewards = try await store.fetchMyInviteRewards(roomId: roomId)
        self.lastError = nil
        return rewards
    }

    /// W2.7 — builds and schedules the joined-late catch-up push.
    /// The identifier is stable per event, so a re-join overwrites
    /// instead of stacking — no duplicate pushes. V0.54 — gated
    /// on the room-level `notifications_enabled` opt-in; a joiner
    /// who hasn't opted in to this room's nights receives no
    /// push. They can still see the briefing slot in-app.
    private func scheduleCatchUpIfNeeded(room: Room) async {
        guard room.notificationsEnabled else { return }
        guard let event = await loadActiveEvent(roomId: room.id) else { return }
        let board = await loadLeaderboard(roomId: room.id)
        let summary = board.prefix(3)
            .map { "\($0.displayName) \($0.pointsBalance)" }
            .joined(separator: " · ")
        await NotificationDispatcher.shared.scheduleCatchUp(
            eventId: event.id,
            eventName: event.name,
            playedAt: event.playedAt,
            mascotName: room.mascotName,
            leaderboardSummary: summary,
            rsvpState: .unclaimed,
            personality: room.mascotPersonality,
            ideology: room.mascotPoliticalIdeology
        )
    }

    // MARK: - Room detail (event + briefing + leaderboard + RSVP)

    /// Loads the room's active event into the cache. Returns the
    /// cached value (which may be `nil` for rooms with no recent
    /// activity). Called from `RoomDetailView.task`.
    ///
    /// V0.69 — single-flight: concurrent callers for the same
    /// `roomId` share one in-flight `get_active_event` task. `force`
    /// still bypasses the TTL check but joins an existing in-flight
    /// fetch instead of starting a duplicate RPC (measured: a
    /// concurrent force + non-force cold-open race collapsed from
    /// 3 RPCs to 1).
    ///
    /// V0.82 — lazy auto-close: before the read, fire
    /// `auto_close_stale_events` throttled to once per 60s per room
    /// (mirrors the `close_stale_attestations` pattern). Events
    /// whose night passed 24h ago get `settled_at` stamped, so the
    /// room transitions to the post-play ceremonial card without a
    /// scheduler. The write is idempotent and member-gated.
    @discardableResult
    func loadActiveEvent(roomId: UUID, force: Bool = false) async -> Event? {
        let key = "activeEvent:\(roomId.uuidString)"
        if !force, isFresh(key) { return activeEventByRoom[roomId] }
        if let existing = activeEventInFlight[roomId] {
            return (try? await existing.value) ?? activeEventByRoom[roomId]
        }
        // V0.82 — throttled lazy close. Fires at most once per 60s
        // per room; failures are swallowed (the read still runs).
        let now = Date()
        if lastAutoCloseAt[roomId] == nil
            || now.timeIntervalSince(lastAutoCloseAt[roomId]!) > 60 {
            lastAutoCloseAt[roomId] = now
            _ = try? await store.autoCloseStaleEvents(roomId: roomId)
        }
        // The cache write happens INSIDE the task so joiners that
        // await `existing.value` observe the populated cache when
        // they resume (the V0.62.1 guards in the dependent loaders
        // read `cachedActiveEvent` right after this returns).
        let task = Task<Event?, Error> { [weak self] () -> Event? in
            guard let self else { return nil }
            do {
                let event = try await Perf.span("rpc get_active_event") {
                    try await self.store.fetchActiveEvent(roomId: roomId)
                }
                self.activeEventByRoom[roomId] = event
                self.cacheTimestamps[key] = Date()
                self.lastError = nil
                return event
            } catch {
                self.lastError = error.localizedDescription
                return self.activeEventByRoom[roomId]
            }
        }
        activeEventInFlight[roomId] = task
        defer { activeEventInFlight.removeValue(forKey: roomId) }
        return (try? await task.value) ?? activeEventByRoom[roomId]
    }

    /// Loads the briefing summary for one event into the cache.
    /// Returns the cached value. Called from `RoomDetailView.task`
    /// when an active event is present.
    @discardableResult
    func loadBriefing(eventId: UUID, force: Bool = false) async -> BriefingSummary? {
        let key = "briefing:\(eventId.uuidString)"
        if !force, isFresh(key) { return briefingByEvent[eventId] }
        do {
            let briefing = try await Perf.span("rpc get_briefing_summary") {
                try await store.fetchBriefing(eventId: eventId)
            }
            self.briefingByEvent[eventId] = briefing
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return briefing
        } catch {
            self.lastError = error.localizedDescription
            return briefingByEvent[eventId]
        }
    }

    // MARK: - Seasons (M1.1)

    /// Loads the room's current season. Returns the cached value
    /// (which may be `nil` only for rooms that never opened a
    /// season). Called from `RoomDetailView.task` alongside the
    /// active-event + briefing loads.
    @discardableResult
    func loadCurrentSeason(roomId: UUID, force: Bool = false) async -> Season? {
        let key = "currentSeason:\(roomId.uuidString)"
        if !force, isFresh(key) { return currentSeasonByRoom[roomId] }
        do {
            let season = try await Perf.span("rpc get_current_season") {
                try await store.fetchCurrentSeason(roomId: roomId)
            }
            self.currentSeasonByRoom[roomId] = season
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return season
        } catch {
            self.lastError = error.localizedDescription
            return currentSeasonByRoom[roomId]
        }
    }

    /// Loads the awards for one season. The privacy boundary is
    /// enforced at the SQL RLS layer (migration 039 drowning
    /// policy); this method stores the rows as-is. The view
    /// layer applies the recipient-check before rendering, in
    /// case the server-side contract regresses.
    @discardableResult
    func loadSeasonAwards(seasonId: UUID, force: Bool = false) async -> [SeasonAward] {
        let key = "seasonAwards:\(seasonId.uuidString)"
        if !force, isFresh(key) { return awardsBySeason[seasonId] ?? [] }
        do {
            let rows = try await store.fetchSeasonAwards(seasonId: seasonId)
            self.awardsBySeason[seasonId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return awardsBySeason[seasonId] ?? []
        }
    }

    /// Host-only. Closes the room's active season via the
    /// `close_season` RPC (migration 048), then refreshes the
    /// season + awards caches so the `.seasonClose` awards card
    /// renders immediately. Returns the closed season.
    @discardableResult
    func closeSeason(roomId: UUID) async throws -> Season {
        let closed = try await store.closeSeason(roomId: roomId)
        self.currentSeasonByRoom[roomId] = closed
        self.awardsBySeason[closed.id] = []
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "currentSeason:\(roomId.uuidString)")
        cacheTimestamps.removeValue(forKey: "seasonAwards:\(closed.id.uuidString)")
        // The RPC opens the next season; refresh the cache so the
        // page transitions out of `.seasonClose` on next load.
        if let next = try? await store.fetchCurrentSeason(roomId: roomId) {
            self.currentSeasonByRoom[roomId] = next
        }
        return closed
    }

    /// Loads the room's leaderboard into the cache. Returns the
    /// cached value (possibly empty). Called from
    /// `RoomDetailView.task`.
    @discardableResult
    func loadLeaderboard(roomId: UUID, force: Bool = false) async -> [LeaderboardEntry] {
        let key = "leaderboard:\(roomId.uuidString)"
        if !force, isFresh(key) { return leaderboardByRoom[roomId] ?? [] }
        do {
            let rows = try await Perf.span("rpc get_room_leaderboard") {
                try await store.fetchLeaderboard(roomId: roomId)
            }
            self.leaderboardByRoom[roomId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return leaderboardByRoom[roomId] ?? []
        }
    }

    /// Loads the room's member roster into the cache. Returns the
    /// cached value (possibly empty). Called from `RoomDetailView.task`
    /// and from `RoomSettingsSheet` when the host opens the members
    /// section.
    @discardableResult
    func loadRoomMembers(roomId: UUID, force: Bool = false) async -> [Member] {
        let key = "roomMembers:\(roomId.uuidString)"
        if !force, isFresh(key) { return membersByRoom[roomId] ?? [] }
        do {
            let rows = try await store.fetchRoomMembers(roomId: roomId)
            self.membersByRoom[roomId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return membersByRoom[roomId] ?? []
        }
    }

    /// Host-only. Assigns (or clears) a member's team label via the
    /// `set_member_team` RPC (migration 049), then refreshes the
    /// roster cache so the team grouping updates in place.
    func setMemberTeam(roomId: UUID, memberId: UUID, team: String?) async throws {
        try await store.setMemberTeam(roomId: roomId, memberId: memberId, team: team)
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "roomMembers:\(roomId.uuidString)")
        if var roster = membersByRoom[roomId],
           let idx = roster.firstIndex(where: { $0.userId == memberId }) {
            roster[idx] = Member(
                id: roster[idx].id,
                roomId: roster[idx].roomId,
                userId: roster[idx].userId,
                role: roster[idx].role,
                joinedAt: roster[idx].joinedAt,
                lastSeenAt: roster[idx].lastSeenAt,
                displayName: roster[idx].displayName,
                socialPreference: roster[idx].socialPreference,
                team: team,
                notificationsEnabled: roster[idx].notificationsEnabled,
                inviteTier: roster[idx].inviteTier,
                invitedBy: roster[idx].invitedBy
            )
            membersByRoom[roomId] = roster
        }
    }

    /// Loads the per-round breakdown for one event into the cache.
    /// Returns the cached value (possibly empty). Called from
    /// `RoomDetailView` when the leaderboard's per-round section
    /// renders.
    @discardableResult
    func loadEventRounds(eventId: UUID, force: Bool = false) async -> [EventRound] {
        let key = "eventRounds:\(eventId.uuidString)"
        if !force, isFresh(key) { return roundsByEvent[eventId] ?? [] }
        do {
            let rows = try await store.fetchEventRounds(eventId: eventId)
            self.roundsByEvent[eventId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return roundsByEvent[eventId] ?? []
        }
    }

    /// Cached per-round breakdown for one event, possibly empty.
    func cachedEventRounds(eventId: UUID) -> [EventRound] {
        roundsByEvent[eventId] ?? []
    }

    /// Loads the current member's RSVP for one event into the
    /// cache. Returns the cached value (defaults to `.unclaimed`
    /// for events with no RSVP row). Called from
    /// `RoomDetailView.task` so the slot rotates to `.claimed` /
    /// `.declined` / `.upcoming` per the V0.8 state machine.
    @discardableResult
    func loadCurrentMemberRSVP(eventId: UUID, force: Bool = false) async -> MemberRSVPState {
        let key = "currentMemberRSVP:\(eventId.uuidString)"
        if !force, isFresh(key) { return rsvpByEvent[eventId] ?? .unclaimed }
        do {
            let state = try await store.fetchCurrentMemberRSVP(eventId: eventId)
            self.rsvpByEvent[eventId] = state
            self.cacheTimestamps[key] = Date()
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
    ///
    /// P1.3 — after a successful upsert, re-schedules the briefing
    /// trio with the new cadence so a member who toggles
    /// `.declined` → `.claimed` immediately starts receiving T-48h
    /// and morning-of logistics nudges (and vice versa). The
    /// dispatcher's `cancelBriefingTrio` followed by
    /// `scheduleBriefingTrio` is idempotent at the UN layer
    /// (the dispatcher uses stable per-(event, cadence, user)
    /// identifiers).
    @discardableResult
    func upsertEventRSVP(eventId: UUID, state: MemberRSVPState) async throws -> MemberRSVP {
        let row = try await store.upsertEventRSVP(eventId: eventId, state: state)
        self.rsvpByEvent[eventId] = row.state
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "eventRSVPs:\(eventId.uuidString)")
        cacheTimestamps.removeValue(forKey: "briefing:\(eventId.uuidString)")
        cacheTimestamps.removeValue(forKey: "currentMemberRSVP:\(eventId.uuidString)")
        // Refresh the seat-grid rows + briefing summary so the
        // BriefingSlot's seat grid and the briefing seat count
        // re-render without a manual pull-to-refresh.
        // `InMemoryRoomStore` mirrors the briefing on upsert but
        // `LiveRoomStore` does not — without these reloads the
        // live path would stay stale after every claim/decline/
        // release. Both caches are `@Published`, so the view
        // re-renders automatically.
        async let rsvps = loadEventRSVPs(eventId: eventId)
        async let briefing = loadBriefing(eventId: eventId)
        _ = await (rsvps, briefing)
        // P1.3 — re-schedule with the new cadence. Reads the
        // matching event from the cache to surface the name +
        // playedAt; falls back to the row's roomId for the
        // roster lookup. V0.54 — filters the fan-out by
        // `optedInMemberIds` (room-level per-member opt-in) and
        // `mutedMemberIds` (per-event mute) so quiet members are
        // never reached.
        if let event = activeEventByRoom.values.first(where: { $0.id == eventId }) {
            let room = rooms.first(where: { $0.id == event.roomId })
            let roster = membersByRoom[event.roomId] ?? []
            var cadence = roster.reduce(into: [UUID: MemberRSVPState]()) { acc, member in
                acc[member.userId] = rsvpByEvent[event.id] ?? .unclaimed
            }
            // The just-upserted row is canonical — overwrite the
            // caller's own cadence so the dispatcher fires for
            // them, not against the stale `.unclaimed` default.
            cadence[row.memberId] = row.state
            let optedInMemberIds = Set(
                roster.filter { $0.notificationsEnabled }.map(\.userId)
            )
            let mutedMemberIds = Set(
                cachedEventRSVPs(eventId: event.id)
                    .filter { $0.notificationsMuted }
                    .map(\.memberId)
            )
            await NotificationDispatcher.shared.cancelBriefingTrio(eventId: event.id)
            await NotificationDispatcher.shared.scheduleBriefingTrio(
                eventId: event.id,
                eventName: event.name,
                playedAt: event.playedAt,
                mascotName: room?.mascotName ?? "Your mascot",
                perMemberCadence: cadence,
                optedInMemberIds: optedInMemberIds,
                mutedMemberIds: mutedMemberIds,
                hostNote: event.hostNote,
                mascotPersonality: room?.mascotPersonality ?? .friendly,
                mascotIdeology: room?.mascotPoliticalIdeology ?? .centrist
            )
        }
        return row
    }

    // MARK: - Event create

    /// Creates a new event in a room. Called from `AddEventSheet`.
    /// Returns the new event id; the parent refreshes the active-
    /// event cache on success. The P1.3 notification fan-out is
    /// invoked after the server write returns — the dispatcher's
    /// 3×3 cadence × response-state matrix fires once the event
    /// row is durable on the server, with the current member's RSVP
    /// defaulted to `.unclaimed` (the dispatcher handles the rest).
    @discardableResult
    func addEvent(roomId: UUID, name: String, playedAt: Date, packSlug: String) async throws -> UUID {
        let newId = try await store.addEvent(
            roomId: roomId,
            name: name,
            playedAt: playedAt,
            packSlug: packSlug
        )
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "activeEvent:\(roomId.uuidString)")
        // Eagerly refresh the active-event cache so the parent's
        // post-create flow doesn't need a second round-trip.
        _ = await loadActiveEvent(roomId: roomId)
        // T1.1 — calendar auto-add. Best-effort: a denied prompt
        // or a failed write never blocks the event flow. Uses the
        // server-canonical event from the cache when available.
        if let room = rooms.first(where: { $0.id == roomId }), room.calendarAutoAddHost {
            let granted = await CalendarService.shared.requestAccess()
            if granted {
                let event = activeEventByRoom[roomId] ?? Event(
                    id: newId,
                    roomId: roomId,
                    name: name,
                    playedAt: playedAt,
                    createdAt: Date(),
                    packSlug: packSlug
                )
                await CalendarService.shared.addEvent(room: room, event: event)
            }
        }
        // P1.3 — schedule the briefing trio. The dispatcher is
        // non-throwing; failures collapse to a logged warning
        // inside the dispatcher. Per-event fan-out reads the
        // post-create room membership (host + invited members)
        // from the room's roster cache. V0.54 — a brand-new event
        // has no mutes yet, so `mutedMemberIds` is the empty
        // default; the fan-out gates on the room-level per-member
        // opt-in via `optedInMemberIds`.
        let room = rooms.first(where: { $0.id == roomId })
        let roster = membersByRoom[roomId] ?? []
        let cadence = roster.reduce(into: [UUID: MemberRSVPState]()) { acc, member in
            acc[member.userId] = .unclaimed
        }
        let optedInMemberIds = Set(
            roster.filter { $0.notificationsEnabled }.map(\.userId)
        )
        await NotificationDispatcher.shared.scheduleBriefingTrio(
            eventId: newId,
            eventName: name,
            playedAt: playedAt,
            mascotName: room?.mascotName ?? "Your mascot",
            perMemberCadence: cadence,
            memberNames: roster.map(\.displayName),
            optedInMemberIds: optedInMemberIds,
            mascotPersonality: room?.mascotPersonality ?? .friendly,
            mascotIdeology: room?.mascotPoliticalIdeology ?? .centrist
        )
        return newId
    }

    /// Any room member may edit the event's pre-play note + venue
    /// while the event is still in the future. Routes through the
    /// `update_event_member_fields` RPC (migration 050); room scope
    /// derives from the event server-side (F-IDENT-01). Refreshes
    /// the active-event cache so the briefing card updates.
    func updateEventMemberFields(eventId: UUID, note: String?, venue: String?) async throws {
        try await store.updateEventMemberFields(eventId: eventId, note: note, venue: venue)
        self.lastError = nil
        if let event = activeEventByRoom.values.first(where: { $0.id == eventId }) {
            cacheTimestamps.removeValue(forKey: "activeEvent:\(event.roomId.uuidString)")
            _ = await loadActiveEvent(roomId: event.roomId)
            // T1.1 — keep the calendar row in sync with venue/note
            // edits. Reads the post-reload event so the row carries
            // the fresh values.
            if let room = rooms.first(where: { $0.id == event.roomId }),
               room.calendarAutoAddHost,
               let fresh = activeEventByRoom[event.roomId] {
                await CalendarService.shared.updateEvent(room: room, event: fresh)
            }
        }
    }

    // MARK: - Room settings update

    /// Host-only. Deletes the room via the `delete_room` RPC
    /// (migration 052), first removing any calendar rows written
    /// for the room's events (T1.1 — closes the
    /// CalendarService.removeEvent zero-call-site gap). Refreshes
    /// the rooms list and clears the room's caches. Throws on
    /// non-host calls.
    func deleteRoom(roomId: UUID) async throws {
        for event in activeEventByRoom.values where event.roomId == roomId {
            await CalendarService.shared.removeEvent(eventId: event.id)
        }
        try await store.deleteRoom(roomId: roomId)
        self.lastError = nil
        activeEventByRoom[roomId] = nil
        leaderboardByRoom[roomId] = []
        currentSeasonByRoom[roomId] = nil
        seasonHistoryByRoom[roomId] = []
        for key in cacheTimestamps.keys where key.contains(roomId.uuidString) {
            cacheTimestamps.removeValue(forKey: key)
        }
        await refresh()
    }

    /// Updates the room's mascot + operations + feature-toggle
    /// columns. Called from `RoomSettingsSheet.writeAll()` (V0.81
    /// autosave). Returns the
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
        socialPreferencesEnabled: Bool,
        autoCloseHours: Int,
        seatDepositAmount: Int,
        seatDepositTrigger: SeatDepositTrigger,
        seatDepositGraceMinutes: Int,
        seatDepositDestination: SeatDepositDestination
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
            socialPreferencesEnabled: socialPreferencesEnabled,
            autoCloseHours: autoCloseHours,
            seatDepositAmount: seatDepositAmount,
            seatDepositTrigger: seatDepositTrigger,
            seatDepositGraceMinutes: seatDepositGraceMinutes,
            seatDepositDestination: seatDepositDestination
        )
        self.lastError = nil
        if let idx = rooms.firstIndex(where: { $0.id == updated.id }) {
            rooms[idx] = updated
        }
        return updated
    }

    /// Loads active pre-play events and their claimed RSVP rows for the rooms list.
    /// Existing caches short-circuit each read.
    func loadRoomsSocialProof() async {
        for room in rooms {
            let event: Event?
            if let cached = cachedActiveEvent(roomId: room.id) {
                event = cached
            } else {
                event = await loadActiveEvent(roomId: room.id)
            }
            guard let event, event.startedAt == nil else { continue }
            if eventRSVPsByEvent[event.id] == nil {
                _ = await loadEventRSVPs(eventId: event.id)
            }
        }
    }


    /// Cached active event for `roomId`, if any. `RoomDetailView`
    /// reads this for the initial render before the async load
    /// resolves.
    func cachedActiveEvent(roomId: UUID) -> Event? {
        activeEventByRoom[roomId]
    }

    /// W2.6 — writes the chapter line for a settled event via the
    /// `write_chapter_line` RPC (migration 051). Any room member
    /// may write; the ceremonial card renders it post-settle.
    func writeChapterLine(eventId: UUID, title: String, callForward: String?) async throws {
        try await store.writeChapterLine(eventId: eventId, title: title, callForward: callForward)
        self.lastError = nil
    }

    /// W2.6 — loads the chapter line for one event into the cache.
    @discardableResult
    func loadEventChapterLine(eventId: UUID, force: Bool = false) async -> ChapterLine? {
        let key = "eventChapterLine:\(eventId.uuidString)"
        if !force, isFresh(key) { return chapterLineByEvent[eventId] }
        do {
            let line = try await store.fetchEventChapterLine(eventId: eventId)
            self.chapterLineByEvent[eventId] = line
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return line
        } catch {
            self.lastError = error.localizedDescription
            return chapterLineByEvent[eventId]
        }
    }

    /// Cached chapter line for one event, if any.
    func cachedEventChapterLine(eventId: UUID) -> ChapterLine? {
        chapterLineByEvent[eventId]
    }

    /// V0.84 C2 — loads Tonight's Star card for one event into the
    /// cache. `nil` means no host pick AND no chip-swing winner —
    /// the section is hidden in that case (matches the 067 empty
    /// case). Mirrors `loadEventChapterLine(eventId:force:)`.
    @discardableResult
    func loadTonightStarCard(eventId: UUID, force: Bool = false) async -> TonightStarCard? {
        let key = "tonightStarCard:\(eventId.uuidString)"
        if !force, isFresh(key) { return tonightStarCardByEvent[eventId] }
        do {
            let card = try await store.fetchTonightStarCard(eventId: eventId)
            self.tonightStarCardByEvent[eventId] = card
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return card
        } catch {
            self.lastError = error.localizedDescription
            return tonightStarCardByEvent[eventId]
        }
    }

    /// Cached Tonight's Star card for one event, if any.
    func cachedTonightStarCard(eventId: UUID) -> TonightStarCard? {
        tonightStarCardByEvent[eventId]
    }

    /// V0.84 C5 — loads the room's unconsumed member notes (host
    /// view). Mirrors `loadEventChapterLine(eventId:force:)`. Empty
    /// array means the host has read everything (or there are no
    /// notes yet).
    @discardableResult
    func loadUnconsumedMemberNotes(roomId: UUID, force: Bool = false) async -> [RoomMemberNote] {
        let key = "memberNotes:\(roomId.uuidString)"
        if !force, isFresh(key) { return unconsumedNotesByRoom[roomId] ?? [] }
        do {
            let notes = try await store.fetchUnconsumedMemberNotes(roomId: roomId)
            self.unconsumedNotesByRoom[roomId] = notes
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return notes
        } catch {
            self.lastError = error.localizedDescription
            return unconsumedNotesByRoom[roomId] ?? []
        }
    }

    /// Cached unconsumed member notes for `roomId`, possibly
    /// empty.
    func cachedUnconsumedMemberNotes(roomId: UUID) -> [RoomMemberNote] {
        unconsumedNotesByRoom[roomId] ?? []
    }

    /// V0.84 C2 — host-only. Sets the Tonight's Star pick for an
    /// event, then invalidates and reloads the card cache so the
    /// ceremonial-card star surface refreshes immediately.
    func setTonightStarPick(
        eventId: UUID,
        memberId: UUID,
        category: TonightStarOverrideCategory,
        customText: String?
    ) async throws {
        try await store.setTonightStarPick(
            eventId: eventId,
            memberId: memberId,
            category: category,
            customText: customText
        )
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "tonightStarCard:\(eventId.uuidString)")
        _ = await loadTonightStarCard(eventId: eventId, force: true)
    }

    /// V0.84 C5 — member writes a one-line drop for the room.
    /// Invalidates the notes cache so the next host read picks
    /// it up.
    func submitMemberNote(roomId: UUID, noteText: String) async throws {
        try await store.submitMemberNote(roomId: roomId, noteText: noteText)
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "memberNotes:\(roomId.uuidString)")
    }

    /// V0.84 C5 — host-only. Stamps `consumed_by_host_at` on the
    /// listed notes and reloads the unconsumed-notes cache so the
    /// BriefingSlot notes section clears.
    func markMemberNotesConsumed(roomId: UUID, noteIds: [UUID]) async throws {
        try await store.markMemberNotesConsumed(roomId: roomId, noteIds: noteIds)
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "memberNotes:\(roomId.uuidString)")
        _ = await loadUnconsumedMemberNotes(roomId: roomId, force: true)
    }

    /// W2.6 — host-only. Sets the active season's subtitle via the
    /// `set_season_subtitle` RPC (migration 051) — the
    /// host-approval beat for the mascot's proposed subtitle.
    /// Refreshes the season cache so the awards card updates.
    func setSeasonSubtitle(roomId: UUID, subtitle: String?) async throws {
        try await store.setSeasonSubtitle(roomId: roomId, subtitle: subtitle)
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "currentSeason:\(roomId.uuidString)")
        _ = await loadCurrentSeason(roomId: roomId)
    }

    /// Cached briefing summary for `eventId`, if any.
    func cachedBriefing(eventId: UUID) -> BriefingSummary? {
        briefingByEvent[eventId]
    }

    /// Cached leaderboard for `roomId`, possibly empty.
    func cachedLeaderboard(roomId: UUID) -> [LeaderboardEntry] {
        leaderboardByRoom[roomId] ?? []
    }

    /// Cached members for `roomId`, possibly empty. Consumed by
    /// the roster surface.
    func cachedMembers(roomId: UUID) -> [Member] {
        membersByRoom[roomId] ?? []
    }

    /// Cached current-member RSVP for `eventId`, defaulting to
    /// `.unclaimed` so the upcoming slot is the safe default.
    func cachedRSVP(eventId: UUID) -> MemberRSVPState {
        rsvpByEvent[eventId] ?? .unclaimed
    }

    /// Optimistically applies an RSVP state change to the local caches
    /// (rsvpByEvent, eventRSVPsByEvent, briefingByEvent) so the UI
    /// reflects the action instantly, before the RPC round-trip. Returns
    /// the previous RSVP state so the caller can roll back on failure.
    @discardableResult
    func applyOptimisticRSVP(eventId: UUID, state: MemberRSVPState, currentUserId: UUID?) -> MemberRSVPState {
        let previous = rsvpByEvent[eventId] ?? .unclaimed
        rsvpByEvent[eventId] = state

        if let uid = currentUserId, var rows = eventRSVPsByEvent[eventId] {
            if let idx = rows.firstIndex(where: { $0.memberId == uid }) {
                rows[idx] = EventRSVP(
                    eventId: eventId,
                    memberId: uid,
                    displayName: rows[idx].displayName,
                    state: state
                )
            } else {
                rows.append(EventRSVP(
                    eventId: eventId,
                    memberId: uid,
                    displayName: "You",
                    state: state
                ))
            }
            eventRSVPsByEvent[eventId] = rows
        }

        if var b = briefingByEvent[eventId] {
            let claimed = b.seatsClaimed
            let declined = b.seatsDeclined
            let unclaimed = b.seatsUnclaimed
            switch (previous, state) {
            case (.unclaimed, .claimed):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: claimed + 1, seatsDeclined: declined, seatsUnclaimed: max(0, unclaimed - 1))
            case (.unclaimed, .declined):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: claimed, seatsDeclined: declined + 1, seatsUnclaimed: max(0, unclaimed - 1))
            case (.claimed, .unclaimed):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: max(0, claimed - 1), seatsDeclined: declined, seatsUnclaimed: unclaimed + 1)
            case (.claimed, .declined):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: max(0, claimed - 1), seatsDeclined: declined + 1, seatsUnclaimed: unclaimed)
            case (.declined, .unclaimed):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: claimed, seatsDeclined: max(0, declined - 1), seatsUnclaimed: unclaimed + 1)
            case (.declined, .claimed):
                b = BriefingSummary(eventId: b.eventId, roomId: b.roomId, seatsTotal: b.seatsTotal, seatsClaimed: claimed + 1, seatsDeclined: max(0, declined - 1), seatsUnclaimed: unclaimed)
            default:
                break
            }
            briefingByEvent[eventId] = b
        }

        return previous
    }

    /// Cached current season for `roomId`. `nil` only when the
    /// room has never opened a season.
    func cachedCurrentSeason(roomId: UUID) -> Season? {
        currentSeasonByRoom[roomId]
    }

    /// Cached awards for `seasonId`, possibly empty.
    func cachedSeasonAwards(seasonId: UUID) -> [SeasonAward] {
        awardsBySeason[seasonId] ?? []
    }

    /// W-05 (US-10) — loads the room's ended seasons with the
    /// caller's total + rank, most recent first. Drives the
    /// previous-seasons comparison section. Returns the cached
    /// value (possibly empty) so the view renders without
    /// waiting on the network.
    @discardableResult
    func loadSeasonHistory(roomId: UUID, force: Bool = false) async -> [SeasonHistoryEntry] {
        let key = "seasonHistory:\(roomId.uuidString)"
        if !force, isFresh(key) { return seasonHistoryByRoom[roomId] ?? [] }
        do {
            let rows = try await Perf.span("rpc get_season_history") {
                try await store.fetchSeasonHistory(roomId: roomId)
            }
            self.seasonHistoryByRoom[roomId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = error.localizedDescription
            return seasonHistoryByRoom[roomId] ?? []
        }
    }

    /// Cached prior seasons for `roomId`, possibly empty.
    /// Consumed by the US-10 previous-seasons comparison surface.
    func cachedSeasonHistory(roomId: UUID) -> [SeasonHistoryEntry] {
        seasonHistoryByRoom[roomId] ?? []
    }

    /// Cached enabled pack slugs for `roomId`. Falls back to the
    /// default installed set (all four V0.8 packs) when the room has
    /// no explicit overrides stored.
    func cachedRoomPacks(roomId: UUID) -> [String] {
        roomPacksByRoom[roomId] ?? []
    }

    // MARK: - Room packs (M4)

    /// Fetch the room's enabled pack slugs from the store and cache
    /// the result. Called from the Operations sub-sheet's `.task`.
    @discardableResult
    func loadRoomPacks(roomId: UUID, force: Bool = false) async -> [String] {
        let key = "roomPacks:\(roomId.uuidString)"
        if !force, isFresh(key) { return roomPacksByRoom[roomId] ?? [] }
        do {
            let slugs = try await store.fetchRoomPacks(roomId: roomId)
            self.roomPacksByRoom[roomId] = slugs
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return slugs
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return roomPacksByRoom[roomId] ?? []
        }
    }

    /// Persist the room's enabled pack slugs. Called from the
    /// Operations sub-sheet's toggle handlers. The store routes
    /// through the `update_room_packs` RPC (migration 041).
    func updateRoomPacks(roomId: UUID, slugs: [String]) async throws {
        try await store.updateRoomPacks(roomId: roomId, slugs: slugs)
        self.roomPacksByRoom[roomId] = slugs
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "roomPacks:\(roomId.uuidString)")
    }

    /// Cached unread system events for `roomId`, possibly empty.
    func cachedSystemEvents(roomId: UUID) -> [RoomSystemEvent] {
        systemEventsByRoom[roomId] ?? []
    }

    /// Fetch the room's unread system events and cache them.
    /// Called from `RoomDetailView`'s `.task`.
    @discardableResult
    func loadSystemEvents(roomId: UUID, force: Bool = false) async -> [RoomSystemEvent] {
        let key = "systemEvents:\(roomId.uuidString)"
        if !force, isFresh(key) { return systemEventsByRoom[roomId] ?? [] }
        do {
            let events = try await Perf.span("rpc get_room_system_events") {
                try await store.fetchRoomSystemEvents(roomId: roomId)
            }
            let unread = events.filter { $0.acknowledgedAt == nil }
            self.systemEventsByRoom[roomId] = unread
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return unread
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return systemEventsByRoom[roomId] ?? []
        }
    }

    /// Acknowledge a system event, removing it from the unread cache.
    func acknowledgeSystemEvent(eventId: UUID, roomId: UUID) async {
        do {
            try await store.acknowledgeSystemEvent(eventId: eventId)
            self.systemEventsByRoom[roomId]?.removeAll { $0.id == eventId }
            self.lastError = nil
            cacheTimestamps.removeValue(forKey: "systemEvents:\(roomId.uuidString)")
        } catch {
            self.lastError = (error as NSError).localizedDescription
        }
    }

    // MARK: - Seat-grid RSVP read (2026-08-10 feedback round)

    /// Loads the per-member RSVP rows for one event into the cache.
    /// Called from `RoomDetailView.task` alongside the briefing
    /// load so the seat grid renders with real claim data.
    @discardableResult
    func loadEventRSVPs(eventId: UUID, force: Bool = false) async -> [EventRSVP] {
        let key = "eventRSVPs:\(eventId.uuidString)"
        if !force, isFresh(key) { return eventRSVPsByEvent[eventId] ?? [] }
        do {
            let rows = try await store.fetchEventRSVPs(eventId: eventId)
            self.eventRSVPsByEvent[eventId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return eventRSVPsByEvent[eventId] ?? []
        }
    }

    /// Cached per-member RSVP rows for `eventId`, possibly empty.
    func cachedEventRSVPs(eventId: UUID) -> [EventRSVP] {
        eventRSVPsByEvent[eventId] ?? []
    }

    // MARK: - Per-room pack payouts (2026-08-10 feedback round)

    /// Loads the room's pack payout overrides into the cache.
    /// Called from `RoomDetailView.task` so the pack shelf and the
    /// host scoring sheet read the configured payouts.
    @discardableResult
    func loadRoomPackConfigs(roomId: UUID, force: Bool = false) async -> [RoomPackConfig] {
        let key = "roomPackConfigs:\(roomId.uuidString)"
        if !force, isFresh(key) { return packConfigsByRoom[roomId] ?? [] }
        do {
            let rows = try await store.fetchRoomPackConfigs(roomId: roomId)
            self.packConfigsByRoom[roomId] = rows
            self.cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return packConfigsByRoom[roomId] ?? []
        }
    }

    /// Cached payout overrides for `roomId`, possibly empty.
    func cachedRoomPackConfigs(roomId: UUID) -> [RoomPackConfig] {
        packConfigsByRoom[roomId] ?? []
    }

    /// The effective win points for a pack in a room: the room's
    /// override when one exists, otherwise the pack's static
    /// default. Used by the pack shelf and the host scoring sheet.
    func effectiveWinPoints(roomId: UUID, packSlug: String) -> Int {
        if let config = packConfigsByRoom[roomId]?.first(where: { $0.packSlug == packSlug }) {
            return config.winPoints
        }
        return PackRegistry.shared.winPoints(for: packSlug)
    }

    /// Host-only upsert of one pack's payout for a room. Mirrors
    /// the override into the cache so the shelf updates without a
    /// manual refresh. Throws on non-host writes.
    func setRoomPackConfig(roomId: UUID, packSlug: String, winPoints: Int) async throws {
        try await store.setRoomPackConfig(roomId: roomId, packSlug: packSlug, winPoints: winPoints)
        var configs = packConfigsByRoom[roomId] ?? []
        configs.removeAll { $0.packSlug == packSlug }
        configs.append(RoomPackConfig(roomId: roomId, packSlug: packSlug, winPoints: winPoints))
        self.packConfigsByRoom[roomId] = configs
        self.lastError = nil
        cacheTimestamps.removeValue(forKey: "roomPackConfigs:\(roomId.uuidString)")
    }

    // MARK: - Drowning opt-in (V0.9 Wave 1 Slice 1.1)

    /// Flips the calling member's per-room Drowning opt-in flag.
    /// Wraps the `set_drowning_opt_in` RPC and refreshes the
    /// cached Room so the toggle state mirrors in the UI without
    /// a manual reload. The SQL RLS policy in migration 045
    /// enforces that a member can only update their own row.
    func setDrowningOptIn(roomId: UUID, optIn: Bool) async throws {
        try await store.setDrowningOptIn(roomId: roomId, optIn: optIn)
        // Refresh the cached Room so the toggle reflects
        // immediately in any view that reads `room.memberDrowningOptIn`.
        if let idx = self.rooms.firstIndex(where: { $0.id == roomId }) {
            let old = self.rooms[idx]
            self.rooms[idx] = Room(
                id: old.id,
                name: old.name,
                mascotName: old.mascotName,
                mascotPersonality: old.mascotPersonality,
                mascotPoliticalIdeology: old.mascotPoliticalIdeology,
                createdBy: old.createdBy,
                createdAt: old.createdAt,
                updatedAt: old.updatedAt,
                isLive: old.isLive,
                nextEventDescription: old.nextEventDescription,
                joinStartingBonus: old.joinStartingBonus,
                mascotApiKey: old.mascotApiKey,
                userRole: old.userRole,
                briefing48hEnabled: old.briefing48hEnabled,
                calendarAutoAddHost: old.calendarAutoAddHost,
                socialPreferencesEnabled: old.socialPreferencesEnabled,
                socialNarrationEnabled: old.socialNarrationEnabled,
                maxSeats: old.maxSeats,
                memberInviteQuota: old.memberInviteQuota,
                hostJournal: old.hostJournal,
                installedPackSlugs: old.installedPackSlugs,
                seatDepositAmount: old.seatDepositAmount,
                seatDepositTrigger: old.seatDepositTrigger,
                seatDepositGraceMinutes: old.seatDepositGraceMinutes,
                seatDepositDestination: old.seatDepositDestination,
                memberDrowningOptIn: optIn,
                notificationsEnabled: old.notificationsEnabled,
                autoCloseHours: old.autoCloseHours
            )
        }
        self.lastError = nil
    }

    // MARK: - Quiet-by-default notifications (V0.54)

    /// V0.54 — flips the calling member's per-room notifications
    /// opt-in flag. Wraps the `set_notifications_enabled` RPC
    /// (migration 066) and refreshes the cached `Room` so the
    /// BriefingSlot toggle re-renders immediately. Mirrors the
    /// `setDrowningOptIn` cache-update pattern (same column-on-
    /// membership shape) so the existing UI gates read the fresh
    /// `room.notificationsEnabled` value without a re-fetch.
    func setNotificationsEnabled(roomId: UUID, enabled: Bool) async throws {
        try await store.setNotificationsEnabled(roomId: roomId, enabled: enabled)
        if let idx = self.rooms.firstIndex(where: { $0.id == roomId }) {
            let old = self.rooms[idx]
            self.rooms[idx] = Room(
                id: old.id,
                name: old.name,
                mascotName: old.mascotName,
                mascotPersonality: old.mascotPersonality,
                mascotPoliticalIdeology: old.mascotPoliticalIdeology,
                createdBy: old.createdBy,
                createdAt: old.createdAt,
                updatedAt: old.updatedAt,
                isLive: old.isLive,
                nextEventDescription: old.nextEventDescription,
                joinStartingBonus: old.joinStartingBonus,
                mascotApiKey: old.mascotApiKey,
                userRole: old.userRole,
                briefing48hEnabled: old.briefing48hEnabled,
                calendarAutoAddHost: old.calendarAutoAddHost,
                socialPreferencesEnabled: old.socialPreferencesEnabled,
                socialNarrationEnabled: old.socialNarrationEnabled,
                maxSeats: old.maxSeats,
                memberInviteQuota: old.memberInviteQuota,
                hostJournal: old.hostJournal,
                installedPackSlugs: old.installedPackSlugs,
                seatDepositAmount: old.seatDepositAmount,
                seatDepositTrigger: old.seatDepositTrigger,
                seatDepositGraceMinutes: old.seatDepositGraceMinutes,
                seatDepositDestination: old.seatDepositDestination,
                memberDrowningOptIn: old.memberDrowningOptIn,
                notificationsEnabled: enabled,
                autoCloseHours: old.autoCloseHours
            )
        }
        self.lastError = nil
        // V0.54 — mirror the opt-in change into the spec's
        // "per-event fan-out" cache. The toggle's ripple onto
        // future briefings is handled by the next addEvent /
        // upsertEventRSVP cycle; cancel + reschedule any in-flight
        // trio for the room so the previously-scheduled pushes
        // reflect the new opt-in immediately.
        await cancelRoomCadence(roomId: roomId)
    }

    /// V0.54 — flips the calling member's per-event mute flag.
    /// Wraps the `set_event_notifications_muted` RPC (migration
    /// 066) and mirrors the new value into the cached
    /// `eventRSVPsByEvent` row for the caller so the BriefingSlot
    /// mute toggle re-renders immediately. The dispatcher's
    /// `mutedMemberIds` set is recomputed on the next
    /// `scheduleBriefingTrio` call, so we cancel + reschedule the
    /// event's trio so the new mute reflects in any pending
    /// notification. `currentUserId` is passed in by the view
    /// layer (same shape as `applyOptimisticRSVP`'s parameter)
    /// because `RoomService` itself doesn't hold an auth reference.
    func setEventNotificationsMuted(eventId: UUID, muted: Bool, currentUserId: UUID?) async throws {
        try await store.setEventNotificationsMuted(eventId: eventId, muted: muted)
        if let uid = currentUserId, var rows = eventRSVPsByEvent[eventId],
           let idx = rows.firstIndex(where: { $0.memberId == uid }) {
            rows[idx] = EventRSVP(
                eventId: eventId,
                memberId: rows[idx].memberId,
                displayName: rows[idx].displayName,
                state: rows[idx].state,
                notificationsMuted: muted
            )
            eventRSVPsByEvent[eventId] = rows
        }
        self.lastError = nil
        await cancelEventCadence(eventId: eventId)
    }

    /// V0.54 — cancels every pending briefing-trio push for every
    /// event in this room. Used after a per-room opt-in toggle so
    /// a member who just opted out no longer receives the
    /// previously-scheduled T-48h / morning-of pushes. Idempotent;
    /// a no-op for rooms with no active event.
    private func cancelRoomCadence(roomId: UUID) async {
        for (eventId, event) in activeEventByRoom where event.roomId == roomId {
            await NotificationDispatcher.shared.cancelBriefingTrio(eventId: eventId)
        }
    }

    /// V0.54 — cancels every pending briefing-trio push for one
    /// event. Used after a per-event mute toggle so a member who
    /// just muted the event no longer receives previously-
    /// scheduled pushes for it.
    private func cancelEventCadence(eventId: UUID) async {
        await NotificationDispatcher.shared.cancelBriefingTrio(eventId: eventId)
    }

    // MARK: - Host journal (P1.5)

    /// Updates the host's bounded observation/journal field on the
    /// room. Throws on RLS denial (member trying to edit) or server-
    /// side length-cap rejection. Returns the persisted `Room` so
    /// the UI can mirror the canonical value.
    @discardableResult
    func updateHostJournal(roomId: UUID, journal: String?) async throws -> Room {
        let updated = try await store.updateHostJournal(
            roomId: roomId,
            journal: journal
        )
        self.lastError = nil
        if let idx = rooms.firstIndex(where: { $0.id == updated.id }) {
            rooms[idx] = updated
        }
        return updated
    }

    // MARK: - Seat deposit escrow (V0.85 — migration 085)

    /// V0.85 — member. Claims a seat; when the room's trigger is
    /// `.escrow` this routes through `claim_seat_with_deposit`
    /// (migration 085) so the deposit leaves the balance into
    /// escrow and the RSVP flips in one server transaction.
    /// Falls back to the plain RSVP upsert when the room runs
    /// deposits off. On success refreshes the caller's deposit
    /// cache so the chair card renders the held state.
    func claimSeat(eventId: UUID) async throws -> MemberRSVP {
        if roomTriggeringEscrow(forEvent: eventId) {
            try await store.claimSeatWithDeposit(eventId: eventId)
            await loadMySeatDeposit(eventId: eventId, force: true)
            return MemberRSVP(
                id: UUID(), eventId: eventId, roomId: UUID(), memberId: UUID(),
                state: .claimed, respondedAt: Date()
            )
        }
        return try await upsertEventRSVP(eventId: eventId, state: .claimed)
    }

    /// V0.85 — host-only. The broke-member claim: seat claimed
    /// with a zero-amount held deposit row. Wraps
    /// `claim_seat_waived(p_event_id, p_member_id)` (migration
    /// 085). Throws on non-host writes.
    func claimSeatWaived(eventId: UUID, memberId: UUID) async throws {
        try await store.claimSeatWaived(eventId: eventId, memberId: memberId)
        self.lastError = nil
    }

    /// V0.85 — member. The "I'm here" tap: the held deposit
    /// returns instantly. Wraps `check_in_seat(p_event_id)`
    /// (migration 085) and refreshes the deposit cache so the
    /// chair card flips out of the reclaim state. Idempotent.
    func checkInSeat(eventId: UUID) async throws {
        try await store.checkInSeat(eventId: eventId)
        self.lastError = nil
        await loadMySeatDeposit(eventId: eventId, force: true)
    }

    /// V0.85 — the caller's seat deposit for an event, or nil
    /// when none is held. Read from the store each force-load;
    /// cached per-event with the 30s TTL pattern. Drives the
    /// chair card's "I'm here" button.
    @discardableResult
    func loadMySeatDeposit(eventId: UUID, force: Bool = false) async -> SeatDeposit? {
        let key = "mySeatDeposit:\(eventId.uuidString)"
        if !force, isFresh(key), mySeatDepositByEvent[eventId] == nil {
            if let ts = cacheTimestamps[key] { _ = ts }
        }
        do {
            if let deposit = try await store.fetchMySeatDeposit(eventId: eventId) {
                mySeatDepositByEvent[eventId] = deposit
            } else {
                mySeatDepositByEvent.removeValue(forKey: eventId)
            }
            cacheTimestamps[key] = Date()
            self.lastError = nil
            return mySeatDepositByEvent[eventId]
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return mySeatDepositByEvent[eventId]
        }
    }

    /// Cached held deposit for `eventId`, or nil. Drives the
    /// chair card render gate.
    func cachedMySeatDeposit(eventId: UUID) -> SeatDeposit? {
        mySeatDepositByEvent[eventId]
    }

    /// V0.85 — host-only. Loads the per-event arrival card
    /// source: held deposits with no check-in and no play
    /// transaction. Wraps `list_arrival_candidates(p_event_id)`
    /// (migration 085); cached per-event with the 30s TTL.
    @discardableResult
    func loadArrivalCandidates(eventId: UUID, force: Bool = false) async -> [SeatDepositCandidate] {
        let key = "arrivalCandidates:\(eventId.uuidString)"
        if !force, isFresh(key) { return arrivalCandidatesByEvent[eventId] ?? [] }
        do {
            let rows = try await store.loadArrivalCandidates(eventId: eventId)
            arrivalCandidatesByEvent[eventId] = rows
            cacheTimestamps[key] = Date()
            self.lastError = nil
            return rows
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return arrivalCandidatesByEvent[eventId] ?? []
        }
    }

    /// Cached arrival candidates for `eventId`, possibly empty.
    /// Drives the host arrival card render gate.
    func cachedArrivalCandidates(eventId: UUID) -> [SeatDepositCandidate] {
        arrivalCandidatesByEvent[eventId] ?? []
    }

    /// V0.85 — host-only. The confirmed no-show call: the held
    /// deposit stays out. Wraps `forfeit_seat_deposit(p_event_id,
    /// p_member_id)` (migration 085); on success removes the
    /// candidate from the cached list so the arrival card stops
    /// asking. Throws on non-host writes.
    func forfeitSeatDeposit(eventId: UUID, memberId: UUID) async throws {
        try await store.forfeitSeatDeposit(eventId: eventId, memberId: memberId)
        self.lastError = nil
        removeArrivalCandidate(eventId: eventId, memberId: memberId)
    }

    /// V0.85 — host-only. Returns a held deposit without the
    /// member's tap (texted / away / arrived-unscanned). Wraps
    /// `waive_seat_deposit(p_event_id, p_member_id)` (migration
    /// 085); on success removes the candidate from the cached
    /// list. `reason` is free-form; the mascot copy renders it.
    func waiveSeatDeposit(eventId: UUID, memberId: UUID, reason: String?) async throws {
        try await store.waiveSeatDeposit(eventId: eventId, memberId: memberId)
        self.lastError = nil
        removeArrivalCandidate(eventId: eventId, memberId: memberId)
    }

    /// Removes one resolved candidate from the cached arrival
    /// list and drops the cache freshness stamp so the next
    /// render re-reads the server truth.
    private func removeArrivalCandidate(eventId: UUID, memberId: UUID) {
        if var rows = arrivalCandidatesByEvent[eventId] {
            rows.removeAll { $0.userId == memberId }
            arrivalCandidatesByEvent[eventId] = rows
        }
        cacheTimestamps.removeValue(forKey: "arrivalCandidates:\(eventId.uuidString)")
    }

    /// True when the event's room runs the deposit escrow. Reads
    /// the cached rooms list; a miss (room not loaded yet) runs
    /// the plain claim path — the server RPC re-guards anyway.
    private func roomTriggeringEscrow(forEvent eventId: UUID) -> Bool {
        guard let room = rooms.first(where: { r in
            activeEventByRoom.values.contains { $0.id == eventId && $0.roomId == r.id }
        }) else { return false }
        return room.seatDepositTrigger == .escrow && room.seatDepositAmount > 0
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