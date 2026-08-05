//
//  RoomDetailView.swift
//  GamesRoom
//
//  V0.8 three-slot stage. One page, content rotates by the room's
//  state machine. The dominant-action wash is at most one `.hero`
//  SectionCard per slot, per the 80/20/10 rule.
//
//  State precedence (first match wins):
//    1. .loading            — first open with no data yet
//    2. .justSettled        — settledAt within 24h, no new event
//    3. .inPlay             — activeEvent.isLive && withdrawals exist
//    4. .settleRound        — host finalized, not all members scanned
//    5. .upcoming           — playedAt > now, RSVP == .unclaimed
//    6. .claimed            — playedAt > now, RSVP == .claimed
//    7. .declined           — playedAt > now, RSVP == .declined
//    8. .readStandings      — no active event, no recent settle
//
//  Data flow
//  ---------
//  This view is the canonical consumer of `RoomService` +
//  `CasinoService`. Reads come from the services' `@Published`
//  caches (populated by `loadActiveEvent`, `loadBriefing`,
//  `loadLeaderboard`, `loadCurrentMemberRSVP`,
//  `casinoService.getMyOpenAttestations`). Writes flow through
//  `RoomService.upsertEventRSVP` (Claim / Decline),
//  `RoomService.updateRoom` (settings), and
//  `CasinoService.submitMemberScan` (chip scan). All actions go
//  through the protocol-based `RoomStore` so the same view tree
//  runs against the live Supabase backend or the in-memory fake.
//

import SwiftUI

// MARK: - RoomDetailView

struct RoomDetailView: View {
    let room: Room
    let allRooms: [Room]
    let onDismiss: () -> Void
    let onSwitchRoom: (Room) -> Void

    @EnvironmentObject private var authService: AuthService
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var casinoService: CasinoService

    /// Drives the host-only Room Settings sheet from the in-room
    /// toolbar gear (L6 spec). Mirrors `RoomPage.settingsRoom` for
    /// the standalone rooms-page gear icon.
    @State private var settingsRoom: Room?

    // P0.5 — withdraw + settle sheet bindings. Owned by the view
    // layer so `openWithdraw` / `openScan` can flip them without
    // going through `RoomService` (which would force an extra
    // round-trip). The active event is captured at sheet-present
    // time so the sheets don't drift if the user pulls-to-refresh
    // while the sheet is open.
    @State private var withdrawSheetEvent: Event?
    @State private var settleSheetEvent: Event?
    @State private var casinoWithdrawn: Int = 0

    // P0.4 — host-only single-winner scoring sheet binding. Hosts
    // tap "Score a round" on the at-play Witness Slot; the sheet
    // opens for any pack (Casino host scoring routes through
    // `SettleCasinoSheet` instead).
    @State private var hostScoreEvent: Event?

    private var isHost: Bool {
        guard let uid = authService.currentUser?.id else { return false }
        return room.userRole == .host || room.createdBy == uid
    }

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

    // MARK: Service-backed state

    /// Cached active event for this room. Driven by
    /// `roomService.loadActiveEvent(roomId:)` in `.task`.
    private var activeEvent: Event? {
        roomService.cachedActiveEvent(roomId: room.id)
    }

    /// Cached briefing summary for the active event, if any.
    private var briefing: BriefingSummary? {
        guard let event = activeEvent else { return nil }
        return roomService.cachedBriefing(eventId: event.id)
    }

    /// Cached current-member RSVP for the active event, defaulting
    /// to `.unclaimed`. Drives the upcoming / claimed / declined
    /// slot branches.
    private var myRSVP: MemberRSVPState {
        guard let event = activeEvent else { return .unclaimed }
        return roomService.cachedRSVP(eventId: event.id)
    }

    /// Cached leaderboard for this room. Possibly empty.
    private var leaderboard: [LeaderboardEntry] {
        roomService.cachedLeaderboard(roomId: room.id)
    }

    /// Unread system events for this room (pack installed/removed,
    /// season closed). Drives the System banner above the standings.
    private var systemEvents: [RoomSystemEvent] {
        roomService.cachedSystemEvents(roomId: room.id)
    }

    /// Open attestations for the current member across all rooms
    /// (one row typically). Driven by
    /// `casinoService.getMyOpenAttestations()` in `.task`.
    @State private var openAttestations: [OpenAttestationSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                activeSlot
                    .frame(maxWidth: .infinity)
                if !systemEvents.isEmpty {
                    SystemBanner(
                        events: systemEvents,
                        onDismiss: { eventId in
                            Task { await roomService.acknowledgeSystemEvent(eventId: eventId, roomId: room.id) }
                        }
                    )
                    .sectionCard(.standard)
                }
                if !leaderboard.isEmpty {
                    StandingsSection(
                        entries: leaderboard,
                        currentUserId: currentUserId
                    )
                    .sectionCard(.standard)
                }
                PackShelfReadOnly(room: room)
                    .sectionCard(.standard)
                MemberRosterReadOnly(room: room)
                    .sectionCard(.standard)
                MascotFooterCaption(room: room)
            }
            .padding(.horizontal, Theme.Layout.edgePadding)
            .padding(.vertical, Theme.Layout.sectionSpacing)
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            // M1.2 — rooms dropdown (only when there's something
            // to switch to OR create). The menu renders for any
            // user with ≥ 1 room, with a "+ Create a new room"
            // section appended when there's >1 room. Per vision
            // §3.7, the dropdown is the canonical reachability
            // surface; the Rooms tab remains the bulk-management
            // view.
            ToolbarItem(placement: .topBarLeading) {
                if !allRooms.isEmpty {
                    RoomSwitcherMenu(
                        currentRoom: room,
                        allRooms: allRooms,
                        activeEventByRoom: roomService.activeEventByRoom,
                        onSwitchRoom: onSwitchRoom
                    )
                }
            }
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        settingsRoom = room
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    .accessibilityLabel(Text("Room settings"))
                    .accessibilityHint(Text("Opens settings for \(room.name)"))
                }
            }
        }
        .sheet(item: $settingsRoom) { presented in
            RoomSettingsSheet(room: presented)
                .environmentObject(roomService)
        }
        .sheet(item: $withdrawSheetEvent) { event in
            WithdrawChipsSheet(eventId: event.id, roomId: room.id)
                .environmentObject(casinoService)
                .environmentObject(authService)
        }
        .sheet(item: $settleSheetEvent) { event in
            // P0.5 virtual-only Casino: the withdrawn amount is
            // sourced from the prior `CasinoService.withdraw(...)`
            // row via the latest open attestation's
            // `vision_amount_points` proxy. Until we wire the
            // attestation → withdrawn lookup, default to 0 so
            // the sheet always renders. The member can edit
            // the displayed withdrawn value via the stepper
            // (returns 0–200 pts in 10-pt increments).
            SettleCasinoSheet(
                eventId: event.id,
                roomId: room.id,
                withdrawn: casinoWithdrawn
            )
            .environmentObject(scoringService)
            .environmentObject(authService)
        }
        .sheet(item: $hostScoreEvent) { event in
            let pack = PackRegistry.shared.definition(for: event.packSlug)
            HostScoreEntrySheet(
                eventId: event.id,
                roomId: room.id,
                packSlug: event.packSlug,
                packDisplayName: pack?.displayName ?? event.packSlug
            )
            .environmentObject(roomService)
            .environmentObject(scoringService)
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh()
        }
    }

    // MARK: - State resolution

    private var state: V0State {
        if activeEvent == nil, briefing == nil, leaderboard.isEmpty {
            return .loading
        }
        // M1.1 — season-close takes priority over active-event
        // branches. When the current season has ended, the page
        // should render the awards card regardless of whether the
        // room has a recently-settled or in-play event — the
        // awards card IS the hero for that period.
        if let season = currentSeason, season.status == .ended {
            return .seasonClose(season, seasonAwardsForPrivacy)
        }
        if let event = activeEvent {
            let isLive = event.playedAt <= Date()
            let isSettled = event.settledAt != nil
            if isSettled,
               let s = event.settledAt,
               s > Date().addingTimeInterval(-86_400) {
                return .justSettled(event)
            }
            if isLive && event.hostFinalized {
                return .settleRound(event)
            }
            // M1.1 — `.tonightEvent` is the play-just-started
            // moment: live, member hasn't moved chips yet, the
            // host hasn't finalised. Distinct from `.inPlay` so
            // the witness hero can carry the started-time caption
            // in isolation. The collapse-into-`.inPlay` that the
            // audit flags (V0State used to mix these) is undone
            // here — the brief's 10-state machine wins.
            if isLive && casinoWithdrawn == 0 {
                return .tonightEvent(event)
            }
            if isLive {
                return .inPlay(event)
            }
            // playedAt > now ⇒ pre-play
            switch myRSVP {
            case .unclaimed: return .upcoming(event)
            case .claimed:   return .claimed(event)
            case .declined:  return .declined(event)
            }
        }
        return .readStandings
    }

    /// M1.1 — current season cached read. `nil` only when the
    /// room has never opened a season (no row in
    /// `public.seasons`).
    private var currentSeason: Season? {
        roomService.cachedCurrentSeason(roomId: room.id)
    }

    /// M1.1 — cached awards filtered for the current user.
    /// Drowning rows are kept only when the current user IS the
    /// recipient — the privacy boundary the SQL RLS layer also
    /// enforces. Belt-and-braces against a server regression.
    private var seasonAwardsForPrivacy: [SeasonAward] {
        let all = roomService.cachedSeasonAwards(
            seasonId: currentSeason?.id ?? UUID()
        )
        guard let me = authService.currentUser?.id else { return all }
        return all.filter { row in
            guard row.awardType.isPrivate else { return true }
            return row.recipientUserId == me
        }
    }

    @ViewBuilder
    private var activeSlot: some View {
        switch state {
        case .loading:
            VStack { ProgressView().tint(Theme.Palette.accent) }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Layout.sectionSpacing * 2)

        case .upcoming(let event):
            BriefingSlot(event: event, briefing: briefing, myRSVP: myRSVP,
                         onClaim: { Task { await claimSeat(eventId: event.id) } },
                         onDecline: { Task { await declineSeat(eventId: event.id) } },
                         isHero: true)
        case .claimed(let event):
            BriefingSlot(event: event, briefing: briefing, myRSVP: .claimed,
                         onClaim: {}, onDecline: {}, isHero: true)
        case .declined(let event):
            BriefingSlot(event: event, briefing: briefing, myRSVP: .declined,
                         onClaim: {}, onDecline: {}, isHero: true)

        case inPlay(let event):
            WitnessSlot(
                event: event,
                attestations: openAttestations,
                cta: .withdraw,
                onWithdraw: { Task { await openWithdraw(event: event) } },
                onScan: { Task { await openScan(event: event) } },
                onScore: isHost
                    ? { Task { await openHostScore(event: event) } }
                    : nil,
                isHero: true,
                headerMode: .inPlay
            )

        // M1.1 — `.tonightEvent` renders the witness hero with
        // the play-just-started copy + the full-width "Withdraw
        // chips" CTA. Same `WitnessSlot` component as `.inPlay`;
        // the started-time caption is what differentiates this
        // state from the post-withdrawal one.
        case .tonightEvent(let event):
            WitnessSlot(
                event: event,
                attestations: openAttestations,
                cta: .withdraw,
                onWithdraw: { Task { await openWithdraw(event: event) } },
                onScan: { Task { await openScan(event: event) } },
                onScore: isHost
                    ? { Task { await openHostScore(event: event) } }
                    : nil,
                isHero: true,
                headerMode: .tonightEvent
            )

        // M1.1 — `.seasonClose` renders the awards card with the
        // privacy-filtered awards for the current user. The
        // drowning row stays visible only to the recipient.
        case .seasonClose(let season, let awards):
            AwardsCard(season: season, awards: awards)
        case .settleRound(let event):
            WitnessSlot(
                event: event,
                attestations: openAttestations,
                cta: .scan,
                onWithdraw: { Task { await openWithdraw(event: event) } },
                onScan: { Task { await openScan(event: event) } },
                onScore: isHost
                    ? { Task { await openHostScore(event: event) } }
                    : nil,
                isHero: true,
                headerMode: .settleRound
            )

        case .justSettled(let event):
            CeremonialCard(event: event)

        case .readStandings:
            VStack(alignment: .leading, spacing: 12) {
                Text("Standings")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("The ledger fills in after your first night.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectionCard(.hero)
        }
    }

    // MARK: - Data operations

    /// Loads every dependency the V0.8 stage needs in parallel:
    /// the active event, the briefing summary, the leaderboard,
    /// the current member's RSVP, the open attestations, the room
    /// members (for the P1.1 roster surface), and the current
    /// season + awards (for the M1.1 `.seasonClose` slot).
    /// Called from `.task` and `.refreshable`.
    private func refresh() async {
        async let active: () = loadActiveIfNeeded()
        async let board: () = loadLeaderboardIfNeeded()
        async let attestations: () = loadAttestations()
        async let briefingLoad: () = loadBriefingIfNeeded()
        async let rsvpLoad: () = loadRSVPIfNeeded()
        async let membersLoad: () = loadMembersIfNeeded()
        async let seasonLoad: () = loadSeasonIfNeeded()
        async let withdrawalLoad: () = loadMyOpenWithdrawalIfNeeded()
        async let eventsLoad: () = roomService.loadSystemEvents(roomId: room.id)
        _ = await (active, board, attestations, briefingLoad, rsvpLoad, membersLoad, seasonLoad, withdrawalLoad, eventsLoad)
    }

    /// Loads the room's current season and (if present) its awards.
    /// Triggered on every refresh so a host declaring a season-close
    /// in another tab surfaces on next pull-to-refresh.
    private func loadSeasonIfNeeded() async {
        await roomService.loadCurrentSeason(roomId: room.id)
        if let season = roomService.cachedCurrentSeason(roomId: room.id) {
            await roomService.loadSeasonAwards(seasonId: season.id)
        }
    }

    private func loadMembersIfNeeded() async {
        // Always re-fetch on refresh so a member who joined after
        // the first paint shows up in the roster without a manual
        // pull-to-refresh.
        await roomService.loadRoomMembers(roomId: room.id)
    }

    private func loadActiveIfNeeded() async {
        if roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id)
        }
    }

    private func loadLeaderboardIfNeeded() async {
        if roomService.cachedLeaderboard(roomId: room.id).isEmpty {
            await roomService.loadLeaderboard(roomId: room.id)
        }
    }

    private func loadBriefingIfNeeded() async {
        guard let event = roomService.cachedActiveEvent(roomId: room.id) else { return }
        if roomService.cachedBriefing(eventId: event.id) == nil {
            await roomService.loadBriefing(eventId: event.id)
        }
    }

    private func loadRSVPIfNeeded() async {
        guard let event = roomService.cachedActiveEvent(roomId: room.id) else { return }
        // Always re-fetch on refresh so a stale `.claimed` from a
        // previous session is reconciled against the server.
        await roomService.loadCurrentMemberRSVP(eventId: event.id)
    }

    private func loadAttestations() async {
        // CasinoService.getMyOpenAttestations is non-throwing and
        // collapses failures to an empty array. We re-fetch on
        // every refresh so the banner reflects newly-opened rows.
        let rows = await casinoService.getMyOpenAttestations()
        self.openAttestations = rows
    }

    /// M3.1 — loads the calling member's open withdrawal for the
    /// active event and assigns it to `casinoWithdrawn`. Powers
    /// the SettleCasinoSheet stepper default so the member sees
    /// the actual bracket they moved, not 0. Lazy on refresh so
    /// a fresh withdrawal surfaces on the next pull-to-refresh.
    private func loadMyOpenWithdrawalIfNeeded() async {
        guard let event = activeEvent else {
            casinoWithdrawn = 0
            return
        }
        let row = await casinoService.loadMyOpenWithdrawal(eventId: event.id)
        casinoWithdrawn = Int(row?.pointsWithdrawn ?? 0)
    }

    // MARK: - Action handlers (wired to the service layer)

    /// Fires `RoomService.upsertEventRSVP(eventId, .claimed)` for
    /// the active event. On success the service's `rsvpByEvent`
    /// cache is updated and the slot rotates to `.claimed`. On
    /// failure the previous state is preserved and `lastError` is
    /// surfaced via the service.
    private func claimSeat(eventId: UUID) async {
        do {
            _ = try await roomService.upsertEventRSVP(eventId: eventId, state: .claimed)
        } catch {
            // Service already populated lastError; nothing to do here.
            _ = error
        }
    }

    /// Fires `RoomService.upsertEventRSVP(eventId, .declined)`.
    /// Mirror of `claimSeat`.
    private func declineSeat(eventId: UUID) async {
        do {
            _ = try await roomService.upsertEventRSVP(eventId: eventId, state: .declined)
        } catch {
            _ = error
        }
    }

    /// Chip-withdraw CTA on the at-play Witness Slot. P0.5 virtual-
    /// only Casino: flips `withdrawSheetEvent` so the
    /// `WithdrawChipsSheet` renders. The sheet loads the member's
    /// current balance and submits through
    /// `CasinoService.withdraw(...)`. The full camera/Vision
    /// pipeline is intentionally out of scope for this MVP slice
    /// — see plan section 3 P0.5 for the accepted virtual-only
    /// Casino path.
    private func openWithdraw(event: Event) async {
        withdrawSheetEvent = event
    }

    /// Chip-scan CTA. P0.5 virtual-only Casino: flips
    /// `settleSheetEvent` so the `SettleCasinoSheet` renders. The
    /// sheet takes the member's net returned chips and routes
    /// through `ScoringService.recordRoundInput(...)`. The
    /// `record_member_scan` RPC + camera/Vision pipeline remain in
    /// the codebase for the eventual physical-chip flip but are
    /// not exercised by the V0.8 surface.
    private func openScan(event: Event) async {
        settleSheetEvent = event
    }

    /// P0.4 — host-only "Score a round" CTA on the at-play Witness
    /// Slot. Opens `HostScoreEntrySheet` for the event's pack.
    /// For Casino, the host's equivalent is `SettleCasinoSheet`
    /// (the member-driven flow), so this CTA flips the same
    /// `settleSheetEvent` binding — the casino pack renders the
    /// settle sheet instead of the single-winner picker.
    private func openHostScore(event: Event) async {
        if let pack = PackRegistry.shared.definition(for: event.packSlug),
           pack.scoringType == .withdrawReturn {
            settleSheetEvent = event
        } else {
            hostScoreEvent = event
        }
    }
}

// MARK: - States

private enum V0State {
    case loading
    case justSettled(Event)
    /// M1.1 — the play-just-started moment: the event is live
    /// but the member hasn't moved any chips yet. Distinct from
    /// `.inPlay` so the witness hero can render the started-time
    /// caption + the full-width "Withdraw chips" CTA in
    /// isolation. Transitions to `.inPlay` once a withdrawal
    /// lands.
    case tonightEvent(Event)
    case inPlay(Event)
    case settleRound(Event)
    case upcoming(Event)
    case claimed(Event)
    case declined(Event)
    case readStandings
    /// M1.1 — season-close moment: the current season has
    /// `status == .ended`. Renders the awards card surface with
    /// per-recipient privacy filtering for the drowning row.
    case seasonClose(Season, [SeasonAward])
}

// MARK: - Briefing slot

private struct BriefingSlot: View {
    let event: Event
    let briefing: BriefingSummary?
    let myRSVP: MemberRSVPState
    let onClaim: () -> Void
    let onDecline: () -> Void
    let isHero: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Text(event.name)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)

            Text("\(event.playedAt, format: .dateTime.weekday().day().month().hour().minute()) · \(event.maxSeats) seats")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

            if let venue = event.venue, !venue.isEmpty {
                Text(venue)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            }

            if let hostNote = event.hostNote, !hostNote.isEmpty {
                Text(hostNote)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
                    .padding(.top, 8)
            }

            if let briefing {
                BriefingSeatCount(summary: briefing)
            }

            switch myRSVP {
            case .unclaimed:
                HStack(spacing: 12) {
                    Button(action: onClaim) {
                        Text("Claim seat")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button(action: onDecline) {
                        Text("Can't make it")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline))
                    }
                }
                .padding(.top, 8)

            case .claimed:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.accent)
                    Text("You're in.")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .padding(.top, 8)

            case .declined:
                Text("You said you can't make it.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHero ? Theme.Palette.accent.opacity(0.10) : Theme.Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Palette.hairline, lineWidth: 1))
        )
    }
}

// MARK: - Briefing seat-count row

private struct BriefingSeatCount: View {
    let summary: BriefingSummary

    var body: some View {
        HStack(spacing: 12) {
            Text("\(summary.seatsLeft) seats left")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("·")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            Text("\(summary.seatsClaimed) claimed")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            if summary.seatsDeclined > 0 {
                Text("·")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                Text("\(summary.seatsDeclined) declined")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer()
        }
        .padding(.top, 4)
    }
}

// MARK: - Witness slot (at-play)

private struct WitnessSlot: View {
    enum CTA { case withdraw, scan }

    /// M1.1 — header copy differentiates `.tonightEvent`
    /// (play-just-started, "started N min ago") from `.inPlay`
    /// (mid-game, "phones face-down"). The same `WitnessSlot`
    /// component renders both — only the eyebrow + caption
    /// change.
    enum HeaderMode { case inPlay, tonightEvent, settleRound }

    let event: Event
    let attestations: [OpenAttestationSummary]
    let cta: CTA
    let onWithdraw: () -> Void
    let onScan: () -> Void
    /// Host-only callback that opens `HostScoreEntrySheet`. `nil`
    /// for member sessions — the host-only button doesn't render.
    let onScore: (() -> Void)?
    let isHero: Bool
    /// M1.1 — defaults to `.inPlay` for backwards-compat with
    /// the pre-M1.1 call sites. New call sites for
    /// `.tonightEvent` / `.settleRound` set this explicitly.
    var headerMode: HeaderMode = .inPlay

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(Theme.Typography.title.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(headerCaption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                Spacer()
            }

            if !attestations.isEmpty {
                ForEach(attestations) { s in
                    HStack(spacing: 8) {
                        Text(s.contextLabel)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text(s.visionAmountPoints >= 0 ? "+\(s.visionAmountPoints)" : "\(s.visionAmountPoints)")
                            .font(Theme.Typography.body.monospacedDigit())
                            .foregroundStyle(s.visionAmountPoints >= 0 ? Theme.Palette.accent : Theme.Palette.primaryText.opacity(0.55))
                    }
                    .padding(.vertical, 6)
                }
            }

            switch cta {
            case .withdraw:
                Button(action: onWithdraw) {
                    Text("Withdraw chips")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 8)

            case .scan:
                Button(action: onScan) {
                    Text("Scan your chips")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 8)
            }

            // P0.4 — host-only "Score a round" affordance. Renders
            // below the member-facing CTA so the host's at-play
            // surface carries both the chip-withdraw entry point
            // AND the round-recording control without crowding the
            // dominant action. Members see nothing here.
            if let onScore {
                Button(action: onScore) {
                    HStack {
                        Image(systemName: "checkmark.seal.fill")
                        Text("Score a round")
                    }
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel(Text("Score a round (host)"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isHero ? Theme.Palette.accent.opacity(0.10) : Theme.Palette.surface)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.Palette.hairline, lineWidth: 1))
        )
    }

    /// M1.1 — copy variant for the witness header. Each variant
    /// carries the V0.8 brief's intent: `.tonightEvent` is
    /// play-just-started (no withdrawals yet), `.inPlay` is the
    /// canonical mid-game copy, `.settleRound` is the host-finalised
    /// "phones face-down — count what's on the table" copy.
    private var headerTitle: String {
        switch headerMode {
        case .inPlay:       return "The game is on"
        case .tonightEvent: return "The night has started"
        case .settleRound:  return "Count what's on the table"
        }
    }

    private var headerCaption: String {
        switch headerMode {
        case .inPlay:
            return "Phones face-down. Stay in the room."
        case .tonightEvent:
            return "The host just kicked off. Move your first chips when you're ready."
        case .settleRound:
            return "The host has finalised. Settle your stack before you leave the room."
        }
    }
}

// MARK: - Ceremonial card (post-play, ≤24h after settle)

private struct CeremonialCard: View {
    let event: Event

    var body: some View {
        VStack(alignment: .leading, spacing: 64) {
            Text(event.name)
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Palette.primaryText)

            if let settledAt = event.settledAt {
                Text("Settled \(settledAt, format: .relative(presentation: .named))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            Spacer().frame(height: 32)

            HStack {
                Text("Next session:")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Text(event.playedAt.addingTimeInterval(86_400 * 7), format: .dateTime.weekday().day().month())
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }

            Spacer().frame(height: 24)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent.opacity(0.7))
                Text("Standings below")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent.opacity(0.7))
            }
            .accessibilityLabel(Text("Standings continue below"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.cardInset)
        // M2.5 — state-driven hero wash. The CeremonialCard
        // (.justSettled) is always the active slot in its V0State,
        // so .hero is correct here. The hard-coded `.hero` on
        // the original page-level Tonight card (audit §11
        // finding) is no longer in the tree — the slot renderer
        // drives the wash via `isHero`.
        .sectionCard(.hero)
    }
}

// MARK: - Awards card (season-close slot, M1.1)

/// Renders the per-season awards. The `.drowning` row is private
/// to the recipient — the calling resolver (`seasonAwardsForPrivacy`
/// in `RoomDetailView`) already filters drowning rows whose
/// `recipientUserId` isn't the current user. The card renders
/// whatever rows it receives; it does not re-filter.
private struct AwardsCard: View {
    let season: Season
    let awards: [SeasonAward]

    /// Stable display order: phoenix, veteran, whale, drowning.
    /// `AwardType.CaseIterable` defines the order; we sort by it.
    private var sortedAwards: [SeasonAward] {
        awards.sorted { lhs, rhs in
            let lhsIdx = AwardType.allCases.firstIndex(of: lhs.awardType) ?? 0
            let rhsIdx = AwardType.allCases.firstIndex(of: rhs.awardType) ?? 0
            return lhsIdx < rhsIdx
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Season \(season.ordinal) is closed")
                    .font(Theme.Typography.title.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                if !season.subtitle.isEmpty {
                    Text(season.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }

            if sortedAwards.isEmpty {
                Text("Awards haven't been declared yet.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .padding(.top, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedAwards.enumerated()), id: \.element.id) { idx, award in
                        AwardRow(award: award)
                        if idx != sortedAwards.count - 1 {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            if let endedAt = season.endedAt {
                Text("Closed \(endedAt, format: .relative(presentation: .named))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.cardInset)
        .sectionCard(.hero)
    }
}

/// One row inside the awards card. The drowning icon is muted
/// (the row is private; UI just looks calmer). Other awards use
/// their award type's symbol.
private struct AwardRow: View {
    let award: SeasonAward

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(Theme.Typography.body)
                .foregroundStyle(award.awardType.isPrivate
                    ? Theme.Palette.primaryText.opacity(0.55)
                    : Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(award.recipientDisplayName)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("·")
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                    Text(award.awardType.displayName)
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(award.awardType.isPrivate
                            ? Theme.Palette.primaryText.opacity(0.55)
                            : Theme.Palette.accent)
                }
                if let caption = award.caption, !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var symbol: String {
        switch award.awardType {
        case .phoenix:  return "flame.fill"
        case .veteran:  return "checkmark.seal.fill"
        case .whale:    return "circle.hexagongrid.fill"
        case .drowning: return "drop.fill"
        }
    }
}

// MARK: - System banner (briefing slot notification stream)

private struct SystemBanner: View {
    let events: [RoomSystemEvent]
    let onDismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(events) { event in
                HStack(spacing: 10) {
                    Image(systemName: iconFor(event.kind))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.kind.displayName)
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(payloadDescription(for: event))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                    Spacer()
                    Button {
                        onDismiss(event.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                    }
                    .accessibilityLabel(Text("Dismiss"))
                }
                if event.id != events.last?.id {
                    Divider().overlay(Theme.Palette.hairline)
                }
            }
        }
    }

    private func iconFor(_ kind: RoomSystemEvent.Kind) -> String {
        switch kind {
        case .packInstalled: return "plus.circle.fill"
        case .packRemoved:   return "minus.circle.fill"
        case .seasonClosed:  return "flag.checkered"
        }
    }

    private func payloadDescription(for event: RoomSystemEvent) -> String {
        switch event.kind {
        case .packInstalled, .packRemoved:
            if let name = event.payload["pack_name"] {
                return "Pack: \(String(describing: name.value))"
            }
            return "A pack was updated."
        case .seasonClosed:
            return "The season has been closed by the host."
        }
    }
}

// MARK: - Standings section (always-on, below the slot)

private struct StandingsSection: View {
    let entries: [LeaderboardEntry]
    let currentUserId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Standings")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                LeaderboardRow(
                    rank: idx + 1,
                    name: entry.displayName,
                    score: Int(entry.pointsBalance),
                    lastDelta: Int(entry.lastSessionDelta),
                    sessionsPlayed: Int(entry.sessionsPlayed),
                    trajectory: entry.trajectory.map { Int($0.delta) },
                    isYou: entry.userId == currentUserId,
                    isRecentlyCorrected: entry.isRecentlyCorrected
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rankFor(_ entry: LeaderboardEntry) -> Int {
        // Host excluded from rank numbering (per LockedRow component).
        if entry.isHost { return 0 }
        let nonHostCount = entries.prefix(while: { $0.id != entry.id }).filter { !$0.isHost }.count
        return nonHostCount + 1
    }
}

// MARK: - Pack shelf (read-only on-page)

private struct PackShelfReadOnly: View {
    let room: Room
    /// The four V0.8 packs from `PackRegistry.shared`. Each tile
    /// renders name + icon + description; tapping the tile opens a
    /// how-to guide placeholder (per the brief: "an entry point to
    /// each how-to guide"). The how-to body itself is a V0.9+ slice;
    /// the tap surface ships here so the rest of the shelf contract
    /// is in place.
    private var packs: [any PackDefinition.Type] {
        PackRegistry.shared.allPacks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Text("Packs")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)

            Text("Games-night rules your room is set up for.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

            VStack(spacing: 0) {
                ForEach(Array(packs.enumerated()), id: \.element.slug) { idx, pack in
                    packRow(pack)
                    if idx != packs.count - 1 {
                        Divider()
                            .overlay(Theme.Palette.hairline)
                            .padding(.horizontal, Theme.Layout.edgePadding)
                    }
                }
            }
            .background(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func packRow(_ pack: any PackDefinition.Type) -> some View {
        // M2.1 — pack rows are read-only display only. The
        // chevron + tap affordance are dropped per the Track E
        // verdict ("DROP the pack-row trigger"). The how-to
        // body is V0.9; until then, the row shows the pack's
        // name + description as static metadata for the room.
        HStack(spacing: Theme.Layout.gutter) {
            Image(systemName: pack.iconSystemName)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.displayName)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(pack.description)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, Theme.Layout.cardInset)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(pack.displayName) — \(pack.description)"))
    }
}

// MARK: - Member roster

private struct MemberRosterReadOnly: View {
    let room: Room
    /// The cached roster for this room (host first, then
    /// alphabetical per `get_room_members`). Falls back to "Loading…"
    /// when the cache is empty — `RoomDetailView.refresh()` is
    /// responsible for populating the cache on first appear.
    @EnvironmentObject private var roomService: RoomService

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Text("Members")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("Everyone with a seat at the table.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

            let members = roomService.cachedMembers(roomId: room.id)
            if members.isEmpty {
                HStack {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Loading members…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                .padding(.vertical, Theme.Layout.cardInset)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { idx, member in
                        memberRow(member)
                        if idx != members.count - 1 {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                                .padding(.horizontal, Theme.Layout.edgePadding)
                        }
                    }
                }
                .background(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func memberRow(_ member: Member) -> some View {
        HStack(spacing: Theme.Layout.gutter) {
            // Avatar placeholder — the V0.8 brief deliberately
            // surfaces a monogram (initials) rather than a photo so
            // the roster renders without a media dependency.
            Circle()
                .fill(Theme.Palette.accent.opacity(0.18))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(initials(for: member.displayName))
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(member.displayName)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(member.role == .host ? "Host" : "Member")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, Theme.Layout.cardInset)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(member.displayName), \(member.role == .host ? "host" : "member")"))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Mascot footer caption

private struct MascotFooterCaption: View {
    let room: Room
    /// Pure template interpolation per V0.8 brief — the footer
    /// caption is one of the 100 voice cells, picked from the
    /// room's `(personality × ideology × .postPlayRecap)`
    /// combination. Tap opens the deep-dive bubble. See
    /// `MascotEngine.generateVoice(...)` for the placeholder
    /// contract; nil fields are simply omitted from the template.
    ///
    /// M2.3 — pass real memberCount + memberNames from the cached
    /// roster so the post-play recap template doesn't substitute
    /// "0 members". Members are loaded by `RoomDetailView.task`;
    /// this view reads from the service's published cache so the
    /// caption updates without a manual refresh.
    private var members: [Member] {
        roomService.cachedMembers(roomId: room.id)
    }
    private var caption: String {
        MascotEngine.generateVoice(
            mascotName: room.mascotName,
            roomName: room.name,
            personality: room.mascotPersonality,
            ideology: room.mascotPoliticalIdeology,
            kind: .postPlayRecap,
            context: .init(
                activeEventTitle: nil,
                lastEventDaysAgo: nil,
                memberCount: members.count,
                memberNames: members.map(\.displayName)
            )
        )
    }
    var body: some View {
        Text(caption)
            .font(Theme.Typography.caption.italic())
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Layout.sectionSpacing)
    }
}

// MARK: - Room switcher menu (M1.2)

/// Toolbar dropdown that lists the user's rooms with active-event
/// indicators and an optional "+ Create a new room" section.
///
/// Per vision §3.7: the rooms list is a top-bar dropdown
/// reachable from any room view. The Rooms tab remains the
/// bulk-management view; this menu is the in-room quick-switch.
///
/// Per plan §2.7: when there's only the current room, the menu
/// renders with just that room (no-op on tap) — never hides.
private struct RoomSwitcherMenu: View {
    let currentRoom: Room
    let allRooms: [Room]
    let activeEventByRoom: [UUID: Event]
    let onSwitchRoom: (Room) -> Void

    /// `true` when more than one room exists; the "+ Create a
    /// new room" section only renders when there's something to
    /// switch to AND something to add to.
    private var canCreate: Bool {
        allRooms.count > 1
    }

    /// Rooms other than the current one, in display order. The
    /// current room renders at the top with a checkmark.
    private var otherRooms: [Room] {
        allRooms.filter { $0.id != currentRoom.id }
    }

    var body: some View {
        Menu {
            Section {
                Button {
                    // No-op: current room is already shown.
                } label: {
                    Label {
                        HStack {
                            Text(currentRoom.name)
                            if activeEventByRoom[currentRoom.id] != nil {
                                Text("•")
                                    .foregroundStyle(Theme.Palette.accent)
                                    .accessibilityLabel(Text("Active session"))
                            }
                            Spacer()
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    } icon: {
                        Text(currentRoom.mascotName.prefix(1).uppercased())
                    }
                }
                .disabled(true)

                ForEach(otherRooms) { room in
                    Button {
                        onSwitchRoom(room)
                    } label: {
                        Label {
                            HStack {
                                Text(room.name)
                                if activeEventByRoom[room.id] != nil {
                                    Text("•")
                                        .foregroundStyle(Theme.Palette.accent)
                                        .accessibilityLabel(Text("Active session"))
                                }
                            }
                        } icon: {
                            Text(room.mascotName.prefix(1).uppercased())
                        }
                    }
                }
            }

            if canCreate {
                Section {
                    // The Rooms tab owns the create-room surface
                    // — tapping this pops back to the Rooms tab.
                    // For now, the dropdown is read-only here; the
                    // Rooms tab's "+" remains the canonical create
                    // entry per audit §7.2. The dropdown gets a
                    // future "create" surface in a follow-up slice.
                    Text("Create a room from the Rooms tab")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentRoom.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .accessibilityLabel(Text("Switch room — currently \(currentRoom.name)"))
        }
    }
}