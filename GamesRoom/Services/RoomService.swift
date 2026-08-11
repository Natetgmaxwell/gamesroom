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

    /// W2.7 — builds and schedules the joined-late catch-up push.
    /// The identifier is stable per event, so a re-join overwrites
    /// instead of stacking — no duplicate pushes.
    private func scheduleCatchUpIfNeeded(room: Room) async {
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
            rsvpState: .unclaimed
        )
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

    // MARK: - Seasons (M1.1)

    /// Loads the room's current season. Returns the cached value
    /// (which may be `nil` only for rooms that never opened a
    /// season). Called from `RoomDetailView.task` alongside the
    /// active-event + briefing loads.
    @discardableResult
    func loadCurrentSeason(roomId: UUID) async -> Season? {
        do {
            let season = try await store.fetchCurrentSeason(roomId: roomId)
            self.currentSeasonByRoom[roomId] = season
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
    func loadSeasonAwards(seasonId: UUID) async -> [SeasonAward] {
        do {
            let rows = try await store.fetchSeasonAwards(seasonId: seasonId)
            self.awardsBySeason[seasonId] = rows
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

    /// Loads the room's member roster into the cache. Returns the
    /// cached value (possibly empty). Called from `RoomDetailView.task`
    /// and from `RoomSettingsSheet` when the host opens the members
    /// section.
    @discardableResult
    func loadRoomMembers(roomId: UUID) async -> [Member] {
        do {
            let rows = try await store.fetchRoomMembers(roomId: roomId)
            self.membersByRoom[roomId] = rows
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
                team: team
            )
            membersByRoom[roomId] = roster
        }
    }

    /// Loads the per-round breakdown for one event into the cache.
    /// Returns the cached value (possibly empty). Called from
    /// `RoomDetailView` when the leaderboard's per-round section
    /// renders.
    @discardableResult
    func loadEventRounds(eventId: UUID) async -> [EventRound] {
        do {
            let rows = try await store.fetchEventRounds(eventId: eventId)
            self.roundsByEvent[eventId] = rows
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
        // P1.3 — re-schedule with the new cadence. Reads the
        // matching event from the cache to surface the name +
        // playedAt; falls back to the row's roomId for the
        // roster lookup.
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
            await NotificationDispatcher.shared.cancelBriefingTrio(eventId: event.id)
            await NotificationDispatcher.shared.scheduleBriefingTrio(
                eventId: event.id,
                eventName: event.name,
                playedAt: event.playedAt,
                mascotName: room?.mascotName ?? "Your mascot",
                perMemberCadence: cadence,
                hostNote: event.hostNote,
                mascotApiKey: room?.mascotApiKey,
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
        // from the room's roster cache.
        let room = rooms.first(where: { $0.id == roomId })
        let roster = membersByRoom[roomId] ?? []
        let cadence = roster.reduce(into: [UUID: MemberRSVPState]()) { acc, member in
            acc[member.userId] = .unclaimed
        }
        await NotificationDispatcher.shared.scheduleBriefingTrio(
            eventId: newId,
            eventName: name,
            playedAt: playedAt,
            mascotName: room?.mascotName ?? "Your mascot",
            perMemberCadence: cadence,
            memberNames: roster.map(\.displayName),
            mascotApiKey: room?.mascotApiKey,
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

    /// W2.6 — writes the chapter line for a settled event via the
    /// `write_chapter_line` RPC (migration 051). Any room member
    /// may write; the ceremonial card renders it post-settle.
    func writeChapterLine(eventId: UUID, title: String, callForward: String?) async throws {
        try await store.writeChapterLine(eventId: eventId, title: title, callForward: callForward)
        self.lastError = nil
    }

    /// W2.6 — loads the chapter line for one event into the cache.
    @discardableResult
    func loadEventChapterLine(eventId: UUID) async -> ChapterLine? {
        do {
            let line = try await store.fetchEventChapterLine(eventId: eventId)
            self.chapterLineByEvent[eventId] = line
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

    /// W2.6 — host-only. Sets the active season's subtitle via the
    /// `set_season_subtitle` RPC (migration 051) — the
    /// host-approval beat for the mascot's proposed subtitle.
    /// Refreshes the season cache so the awards card updates.
    func setSeasonSubtitle(roomId: UUID, subtitle: String?) async throws {
        try await store.setSeasonSubtitle(roomId: roomId, subtitle: subtitle)
        self.lastError = nil
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

    /// Cached current season for `roomId`. `nil` only when the
    /// room has never opened a season.
    func cachedCurrentSeason(roomId: UUID) -> Season? {
        currentSeasonByRoom[roomId]
    }

    /// Cached awards for `seasonId`, possibly empty.
    func cachedSeasonAwards(seasonId: UUID) -> [SeasonAward] {
        awardsBySeason[seasonId] ?? []
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
    func loadRoomPacks(roomId: UUID) async -> [String] {
        do {
            let slugs = try await store.fetchRoomPacks(roomId: roomId)
            self.roomPacksByRoom[roomId] = slugs
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
    }

    /// Cached unread system events for `roomId`, possibly empty.
    func cachedSystemEvents(roomId: UUID) -> [RoomSystemEvent] {
        systemEventsByRoom[roomId] ?? []
    }

    /// Fetch the room's unread system events and cache them.
    /// Called from `RoomDetailView`'s `.task`.
    @discardableResult
    func loadSystemEvents(roomId: UUID) async -> [RoomSystemEvent] {
        do {
            let events = try await store.fetchRoomSystemEvents(roomId: roomId)
            let unread = events.filter { $0.acknowledgedAt == nil }
            self.systemEventsByRoom[roomId] = unread
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
        } catch {
            self.lastError = (error as NSError).localizedDescription
        }
    }

    // MARK: - Seat-grid RSVP read (2026-08-10 feedback round)

    /// Loads the per-member RSVP rows for one event into the cache.
    /// Called from `RoomDetailView.task` alongside the briefing
    /// load so the seat grid renders with real claim data.
    @discardableResult
    func loadEventRSVPs(eventId: UUID) async -> [EventRSVP] {
        do {
            let rows = try await store.fetchEventRSVPs(eventId: eventId)
            self.eventRSVPsByEvent[eventId] = rows
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
    func loadRoomPackConfigs(roomId: UUID) async -> [RoomPackConfig] {
        do {
            let rows = try await store.fetchRoomPackConfigs(roomId: roomId)
            self.packConfigsByRoom[roomId] = rows
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
                memberDrowningOptIn: optIn
            )
        }
        self.lastError = nil
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