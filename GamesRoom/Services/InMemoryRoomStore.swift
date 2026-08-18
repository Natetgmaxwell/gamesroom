//
//  InMemoryRoomStore.swift
//  GamesRoom
//
//  Track D2 — the default `RoomStore` implementation. Foundation-only
//  so the test harness (`build-and-run-tests.sh`) can construct and
//  exercise it without the Supabase stack on the build host. The
//  companion `RoomStore.swift` keeps `LiveRoomStore` (which depends
//  on `SupabaseClientProvider`) — that file does NOT compile in
//  the harness; this one does.
//
//  The default `RoomStore` implementation. Holds three seeded rooms
//  (mirroring `RoomService.preview()`) and synthesises the per-room
//  active event, briefing summary, leaderboard, and attestation rows
//  in-memory. Mutations (RSVP upserts, room-settings edits, event
//  creates) update the in-memory state so the UI re-renders as if
//  the network had succeeded. This is the "no infra" path —
//  installed builds run against `InMemoryRoomStore.shared` until a
//  real Supabase connection string is wired up.
//

import Foundation

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

    /// Map of `eventId → chapter line`. W2.6 — written at settle,
    /// rendered on the ceremonial card.
    private var chapterLines: [UUID: ChapterLine]

    /// Map of `roomId → enabled pack slugs`. M4. Empty when a
    /// room has no pack overrides — callers fall back to the
    /// global `PackRegistry.shared.allPacks` per the V0.8 brief.
    private var roomPacks: [UUID: [String]]

    /// Map of `roomId → prior seasons with the caller's totals`,
    /// ordered most recent first. W-05 — drives the US-10
    /// previous-seasons comparison surface. The first seeded
    /// room (Carwoola) carries two prior seasons so previews
    /// render the "improving over time" section with real data;
    /// the other rooms stay empty.
    private var seasonHistoryByRoom: [UUID: [SeasonHistoryEntry]]

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

    /// V0.54 — per-event mute flags. `[eventId: [memberId: muted]]`.
    /// Mirrors the `event_rsvps.notifications_muted` server-side
    /// column so `fetchEventRSVPs` can layer it onto the read.
    private var eventMutes: [UUID: [UUID: Bool]]

    /// V0.54 — per-room opt-in flags for the synthetic current
    /// member (the in-memory store has no real auth context).
    /// Mirrors `room_memberships.notifications_enabled` so the
    /// `rooms` cache reflects the toggle without a re-fetch.
    private var notificationsEnabledByRoom: [UUID: Bool]

    /// Map of `roomId → payout overrides`. Empty when a room has
    /// no overrides — callers fall back to the pack's static
    /// `winPoints` default per the 2026-08-10 feedback round.
    private var packConfigs: [UUID: [RoomPackConfig]]

    /// Map of `roomId → casino config`. W-06 (US-26) — every seeded
    /// room starts with a defaults row (`standardPresets == true`,
    /// empty chip color map) so the host's settings sheet can
    /// read a non-nil initial state on first open.
    private var casinoConfigs: [UUID: CasinoConfig]

    /// Map of `join_code → roomId` for the in-memory analogue of
    /// the `public.join_codes` table. Codes are minted by
    /// `generateJoinCode(roomId:)` and consumed (removed) by
    /// `redeemJoinCode(code:)`. Powers the P0.2 onboarding
    /// create-room + join-code surfaces without Supabase.
    private var joinCodes: [String: UUID]

    /// V0.55 — invitee scope per join code. `[code: inviteeUserId]`.
    /// Mirrors `join_codes.invitee_user_id` (migration 068): a
    /// non-nil invitee makes the code tier 3, usable only by that
    /// user.
    private var joinCodeInvitees: [String: UUID]

    /// V0.55 — tier-2 joins awaiting host approval. `[roomId: [userId]]`.
    /// Mirrors `room_memberships.invite_tier = 2` (migration 068).
    /// Tier-2 joins are live immediately; the host's one-tap remove
    /// deletes the membership row.
    private var tierTwoJoinsByRoom: [UUID: [UUID]]

    init() {
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
        self.eventMutes = [:]
        self.notificationsEnabledByRoom = [:]
        self.packConfigs = [:]
        self.joinCodes = [:]
        self.joinCodeInvitees = [:]
        self.tierTwoJoinsByRoom = [:]
        self.seasonHistoryByRoom = [:]
        // W-06 — seed every room with a default casino config so
        // the host's settings sheet reads a non-nil initial state.
        // `standardPresets == true` with an empty map is the
        // table-default that the SQL migration sets on insert.
        self.casinoConfigs = [
            carwoola.id: CasinoConfig(
                roomId: carwoola.id, enabled: false,
                chipColorMap: [:], standardPresets: true
            ),
            pluto.id: CasinoConfig(
                roomId: pluto.id, enabled: false,
                chipColorMap: [:], standardPresets: true
            ),
            felt.id: CasinoConfig(
                roomId: felt.id, enabled: false,
                chipColorMap: [:], standardPresets: true
            )
        ]

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
        self.chapterLines = [:]

        // W-05 — seed the first room (Carwoola Crew) with two
        // prior ended seasons, most recent first in the array.
        // The order reflects the SQL `ORDER BY ordinal DESC`:
        // ordinal 2 ("The Comeback") is the freshest prior arc;
        // ordinal 1 ("Genesis") is the oldest. Caller totals are
        // chosen so the +340 movement (640 → 980) makes the
        // "improving over time" story land in the seed view.
        // V0.35 — each season also carries `scoreProgression`
        // (per-session cumulative totals) so the season-history
        // card v2 sparkline renders in the in-memory path.
        // Points sit inside the season window and the last point
        // matches `callerTotal`, matching the migration-057
        // contract.
        self.seasonHistoryByRoom[carwoola.id] = [
            SeasonHistoryEntry(
                seasonId: UUID(),
                ordinal: 2,
                subtitle: "The Comeback",
                startedAt: Date().addingTimeInterval(-86_400 * 60),
                endedAt: Date().addingTimeInterval(-86_400 * 30),
                callerTotal: 980,
                callerRank: 1,
                scoreProgression: [
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 55), total: 200),
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 45), total: 600),
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 32), total: 980)
                ]
            ),
            SeasonHistoryEntry(
                seasonId: UUID(),
                ordinal: 1,
                subtitle: "Genesis",
                startedAt: Date().addingTimeInterval(-86_400 * 120),
                endedAt: Date().addingTimeInterval(-86_400 * 61),
                callerTotal: 640,
                callerRank: 3,
                scoreProgression: [
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 110), total: 150),
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 90), total: 400),
                    SeasonScorePoint(at: Date().addingTimeInterval(-86_400 * 65), total: 640)
                ]
            )
        ]
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

    /// V0.55 — mints a join code, then scopes it to the invitee when
    /// one is given (tier 3). Mirrors `generate_join_code` +
    /// `scope_join_code` (migration 068). When `inviteeUserId` is nil
    /// the code stays open (tier 1 host or tier 2 member).
    func generateInviteCode(roomId: UUID, inviteeUserId: UUID?) async throws -> String {
        let code = try await generateJoinCode(roomId: roomId)
        if let inviteeUserId {
            joinCodeInvitees[code] = inviteeUserId
        }
        return code
    }

    /// V0.55 — host-only. Removes (or restores) a tier-2 join from
    /// the roster. Mirrors `approve_tier_two_join` (migration 068):
    /// `remove: true` deletes the membership row, `false` is a no-op.
    func approveTierTwoJoin(roomId: UUID, userId: UUID, remove: Bool) async throws {
        guard rooms.contains(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \\(roomId) not found"]
            )
        }
        if remove {
            var joins = tierTwoJoinsByRoom[roomId] ?? []
            joins.removeAll { $0 == userId }
            tierTwoJoinsByRoom[roomId] = joins
        }
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
        // V0.55 — tier-3 invitee scope: a code scoped to one invitee
        // is rejected for anyone else (same P0002 as a typo). The
        // in-memory store's synthetic current member is the host of
        // the first seeded room; a scoped code is only redeemable by
        // its invitee.
        if let invitee = joinCodeInvitees[normalised], invitee != currentSyntheticMemberId() {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Code not found or already redeemed"]
            )
        }
        // Mark the code consumed so a second tap reports the
        // "already redeemed" path. Mirrors the live redeem_join_code
        // row update.
        joinCodes.removeValue(forKey: normalised)
        joinCodeInvitees.removeValue(forKey: normalised)
        return RedeemedRoom(roomId: room.id, roomName: room.name)
    }

    /// V0.76 — the caller's invite rewards in a room. The in-memory
    /// store has no reward ledger, so it returns zeroed values (the
    /// live store is the source of truth for rewards).
    func fetchMyInviteRewards(roomId: UUID) async throws -> InviteRewards {
        return InviteRewards(friendsJoined: 0, totalReward: 0)
    }

    /// Returns one synthetic `Member` row per seeded room so the
    /// roster surface renders without Supabase. The host is always
    /// row 0 (matches the live `get_room_members` ordering: host
    /// first, then alphabetical). Used by `RoomService.fetchRoomMembers`.
    func fetchRoomMembers(roomId: UUID) async throws -> [Member] {
        guard let room = rooms.first(where: { $0.id == roomId }) else {
            return []
        }
        // V0.54 — the synthetic current member's per-room opt-in is
        // stored off-band (the in-memory store has no real auth
        // context). Pre-populate every synthetic roster member with
        // `notificationsEnabled = false` so the opt-in filter
        // reflects quiet-by-default out of the gate; the test only
        // checks the field is decodable.
        return [
            Member(
                id: "\(room.id.uuidString):\(room.createdBy.uuidString)",
                roomId: room.id,
                userId: room.createdBy,
                role: .host,
                joinedAt: room.createdAt,
                displayName: "Host",
                notificationsEnabled: false
            ),
            Member(
                id: "\(room.id.uuidString):synthetic-member-2",
                roomId: room.id,
                userId: UUID(),
                role: .member,
                joinedAt: room.createdAt.addingTimeInterval(86_400 * 7),
                displayName: "Alex",
                notificationsEnabled: false
            ),
            Member(
                id: "\(room.id.uuidString):synthetic-member-3",
                roomId: room.id,
                userId: UUID(),
                role: .member,
                joinedAt: room.createdAt.addingTimeInterval(86_400 * 14),
                displayName: "Sam",
                notificationsEnabled: false
            )
        ]
    }

    // MARK: Active event

    func fetchActiveEvent(roomId: UUID) async throws -> Event? {
        return events[roomId]
    }

    /// V0.82 — in-memory mirror of `auto_close_stale_events`.
    /// Stamps `settledAt` on the room's event whose night passed
    /// the room's auto-close window (V0.83: `autoCloseHours`,
    /// default 8), so previews exercise the same transition the
    /// live RPC produces.
    func autoCloseStaleEvents(roomId: UUID) async throws -> Int {
        let windowHours = rooms.first(where: { $0.id == roomId })?.autoCloseHours ?? 8
        guard let event = events[roomId],
              event.settledAt == nil,
              event.playedAt < Date().addingTimeInterval(-Double(windowHours) * 3600) else {
            return 0
        }
        events[roomId] = Event(
            id: event.id,
            roomId: event.roomId,
            name: event.name,
            playedAt: event.playedAt,
            createdAt: event.createdAt,
            venue: event.venue,
            hostNote: event.hostNote,
            maxSeats: event.maxSeats,
            startedAt: event.startedAt,
            settledAt: Date(),
            sessionId: event.sessionId,
            packSlug: event.packSlug,
            hostFinalized: event.hostFinalized
        )
        return 1
    }

    /// In-memory mirror of `set_member_team` (migration 049).
    /// No-op for the synthetic roster — the seeded members have no
    /// team state to mutate, and previews don't need persistence.
    func setMemberTeam(roomId: UUID, memberId: UUID, team: String?) async throws {
        _ = roomId
        _ = memberId
        _ = team
    }

    /// In-memory mirror of `get_event_rounds` (migration 049).
    /// Returns an empty breakdown — the seeded rooms have no
    /// round_submissions rows.
    func fetchEventRounds(eventId: UUID) async throws -> [EventRound] {
        _ = eventId
        return []
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

    /// In-memory mirror of `close_season` (migration 048): closes
    /// the active season, seeds a fresh active season, and returns
    /// the closed season. Awards are not computed here — the
    /// in-memory store's seeded award rows stay put so previews
    /// keep rendering the awards card.
    func closeSeason(roomId: UUID) async throws -> Season {
        guard let active = currentSeasons[roomId], active.status == .active else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No active season to close"]
            )
        }
        let closed = Season(
            id: active.id,
            roomId: active.roomId,
            ordinal: active.ordinal,
            subtitle: active.subtitle,
            status: .ended,
            startedAt: active.startedAt,
            endedAt: Date()
        )
        let next = Season(
            id: UUID(),
            roomId: roomId,
            ordinal: active.ordinal + 1,
            subtitle: "",
            status: .active,
            startedAt: Date(),
            endedAt: nil
        )
        currentSeasons[roomId] = next
        return closed
    }

    /// In-memory mirror of `get_season_history` (migration 053).
    /// Returns the seeded prior seasons for the room, most recent
    /// first. Empty when the room has no ended seasons or when
    /// the caller is not a member — the seed scope matches the
    /// synthetic-member model (the in-memory store has no real
    /// auth context).
    func fetchSeasonHistory(roomId: UUID) async throws -> [SeasonHistoryEntry] {
        return seasonHistoryByRoom[roomId] ?? []
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
        let knownSlugs = Set(PackRegistry.shared.allPacks.map { $0.slug })
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

    // MARK: Quiet-by-default notifications (V0.54)

    /// In-memory mirror of `set_notifications_enabled(p_room_id,
    /// p_enabled)` (migration 066). The synthetic current member's
    /// per-room opt-in lives off-band in `notificationsEnabledByRoom`;
    /// the service-layer caller mirrors the value into the Room
    /// cache so the toggle reflects in the UI without a re-fetch.
    func setNotificationsEnabled(roomId: UUID, enabled: Bool) async throws {
        notificationsEnabledByRoom[roomId] = enabled
    }

    /// In-memory mirror of `set_event_notifications_muted(p_event_id,
    /// p_muted)` (migration 066). Upserts the caller's entry on the
    /// per-event mute map so the next `fetchEventRSVPs` reads the
    /// fresh flag (mirrors the service-layer live upsert
    /// semantics). The synthetic current member is the host of the
    /// first seeded room, matching the existing `upsertEventRSVP`
    /// pattern.
    func setEventNotificationsMuted(eventId: UUID, muted: Bool) async throws {
        var perEvent = eventMutes[eventId] ?? [:]
        perEvent[currentSyntheticMemberId()] = muted
        eventMutes[eventId] = perEvent
    }

    // MARK: Seat-grid RSVP read (2026-08-10 feedback round)

    /// Synthesises one `EventRSVP` row per seeded member for the
    /// event's room, layered over the in-memory `rsvps` map so a
    /// claim/decline in the same process reflects immediately.
    /// Members without an RSVP row read as `.unclaimed`. V0.54 —
    /// layers the per-event mute flag from `eventMutes` onto each
    /// row so the dispatcher's `mutedMemberIds` set can derive
    /// straight from the existing `eventRSVPsByEvent` cache.
    func fetchEventRSVPs(eventId: UUID) async throws -> [EventRSVP] {
        guard let event = events[eventId] else { return [] }
        let members = try await fetchRoomMembers(roomId: event.roomId)
        let states = rsvps[eventId] ?? [:]
        let mutes = eventMutes[eventId] ?? [:]
        return members.map { member in
            EventRSVP(
                eventId: eventId,
                memberId: member.userId,
                displayName: member.displayName,
                state: states[member.userId] ?? .unclaimed,
                notificationsMuted: mutes[member.userId] ?? false
            )
        }
    }

    // MARK: Per-room pack payouts (2026-08-10 feedback round)

    /// Returns the in-memory payout overrides for the room. The
    /// store seeds no overrides — every pack falls back to its
    /// static `winPoints` default until the host sets one.
    func fetchRoomPackConfigs(roomId: UUID) async throws -> [RoomPackConfig] {
        return packConfigs[roomId] ?? []
    }

    /// Stores the payout override in the in-memory map. Mirrors
    /// the live RPC's upsert semantics: setting a value replaces
    /// the previous override for that pack.
    func setRoomPackConfig(roomId: UUID, packSlug: String, winPoints: Int) async throws {
        var configs = packConfigs[roomId] ?? []
        configs.removeAll { $0.packSlug == packSlug }
        configs.append(RoomPackConfig(roomId: roomId, packSlug: packSlug, winPoints: winPoints))
        packConfigs[roomId] = configs
    }

    // MARK: Casino config (W-06, US-26)

    /// In-memory mirror of `get_casino_config(p_room_id)` (migration
    /// 014). Returns the room's casino config or nil when the room
    /// has no row.
    func fetchCasinoConfig(roomId: UUID) async throws -> CasinoConfig? {
        return casinoConfigs[roomId]
    }

    /// In-memory mirror of `upsert_casino_config(p_room_id,
    /// p_enabled, p_chip_color_map, p_standard_presets)` (migration
    /// 014). No host check on the in-memory path — mirrors the
    /// `setRoomPackConfig` simplicity.
    func updateCasinoConfig(
        roomId: UUID,
        enabled: Bool,
        chipColorMap: [ChipColor: Int],
        standardPresets: Bool
    ) async throws {
        casinoConfigs[roomId] = CasinoConfig(
            roomId: roomId,
            enabled: enabled,
            chipColorMap: chipColorMap,
            standardPresets: standardPresets
        )
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

    /// In-memory mirror of `update_event_member_fields` (migration
    /// 050). Mutates the seeded event's note + venue so previews
    /// reflect the edit.
    func updateEventMemberFields(eventId: UUID, note: String?, venue: String?) async throws {
        guard var event = events.values.first(where: { $0.id == eventId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"]
            )
        }
        event = Event(
            id: event.id,
            roomId: event.roomId,
            name: event.name,
            playedAt: event.playedAt,
            createdAt: event.createdAt,
            venue: (venue?.isEmpty ?? true) ? nil : venue,
            hostNote: (note?.isEmpty ?? true) ? nil : note,
            maxSeats: event.maxSeats,
            startedAt: event.startedAt,
            settledAt: event.settledAt,
            sessionId: event.sessionId,
            packSlug: event.packSlug,
            hostFinalized: event.hostFinalized
        )
        events[event.roomId] = event
    }

    /// In-memory mirror of `write_chapter_line` (migration 051).
    /// Stores the line in a local dict so the ceremonial card can
    /// render it in previews.
    func writeChapterLine(eventId: UUID, title: String, callForward: String?) async throws {
        guard let event = events.values.first(where: { $0.id == eventId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Event not found"]
            )
        }
        chapterLines[eventId] = ChapterLine(
            id: UUID(),
            roomId: event.roomId,
            sessionId: event.id,
            title: title,
            nextEpisodeTeaser: callForward,
            writtenAt: Date()
        )
    }

    /// In-memory mirror of `get_event_chapter_line` (migration 051).
    func fetchEventChapterLine(eventId: UUID) async throws -> ChapterLine? {
        return chapterLines[eventId]
    }

    /// In-memory mirror of `set_season_subtitle` (migration 051).
    /// Mutates the active season's subtitle so the awards card
    /// reflects the host's approval in previews.
    func setSeasonSubtitle(roomId: UUID, subtitle: String?) async throws {
        guard let season = currentSeasons[roomId], season.status == .active else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No active season"]
            )
        }
        currentSeasons[roomId] = Season(
            id: season.id,
            roomId: season.roomId,
            ordinal: season.ordinal,
            subtitle: (subtitle?.isEmpty ?? true) ? "" : subtitle!,
            status: season.status,
            startedAt: season.startedAt,
            endedAt: season.endedAt
        )
    }

    // MARK: Room settings

    /// In-memory mirror of `delete_room` (migration 052). The first
    /// seeded room's host is the synthetic current member id, so
    /// a delete on rooms[0] succeeds; deletes on any other seeded
    /// room throw the same "Only the host can delete rooms" error
    /// the live RPC surfaces. Cleans up every per-room map the
    /// store maintains so a subsequent fetchRooms no longer
    /// surfaces the deleted room and the next join code redeem
    /// hits the "Code not found or already redeemed" path.
    func deleteRoom(roomId: UUID) async throws {
        guard let room = rooms.first(where: { $0.id == roomId }) else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "room \(roomId) not found"]
            )
        }
        guard room.createdBy == currentSyntheticMemberId() else {
            throw NSError(
                domain: "InMemoryRoomStore",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Only the host can delete rooms"]
            )
        }

        // Remove the room itself.
        rooms.removeAll { $0.id == roomId }

        // Expire every join code minted for the room.
        for (code, codeRoomId) in joinCodes where codeRoomId == roomId {
            joinCodes.removeValue(forKey: code)
        }

        // Drop the room's active event (and any briefing attached
        // to it). The room's events map is keyed by roomId (one
        // active event per room); also clean briefings keyed by
        // the event id, and any round breakdowns / RSVPs that
        // belong to the event.
        if let event = events[roomId] {
            events.removeValue(forKey: roomId)
            briefings.removeValue(forKey: event.id)
            rsvps.removeValue(forKey: event.id)
            chapterLines.removeValue(forKey: event.id)
        }

        // Per-room caches that aren't room-id-keyed directly.
        leaderboards.removeValue(forKey: roomId)
        currentSeasons.removeValue(forKey: roomId)
        roomPacks.removeValue(forKey: roomId)
        roomSystemEvents.removeValue(forKey: roomId)
        packConfigs.removeValue(forKey: roomId)
        seasonHistoryByRoom.removeValue(forKey: roomId)
        casinoConfigs.removeValue(forKey: roomId)
    }

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
            memberInviteQuota: memberInviteQuota,
            autoCloseHours: autoCloseHours
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
            hostJournal: journal,
            autoCloseHours: existing.autoCloseHours
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
