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
    @EnvironmentObject private var scoringService: ScoringService
    /// W-04 — pops this pushed detail view when the host deletes the
    /// room from settings (the room is gone from the rooms list, so
    /// staying on the page would strand the user on a dead room).
    @Environment(\.dismiss) private var dismiss
    /// iPad host scoring dashboard gate — `.regular` width only. Gated
    /// here (not on UIDevice) so iPad multitasking split-screen stays
    /// on the phone-shaped scroll path.
    @Environment(\.horizontalSizeClass) private var hSize

    /// Drives the host-only Room Settings sheet from the in-room
    /// toolbar gear (L6 spec). Mirrors `RoomPage.settingsRoom` for
    /// the standalone rooms-page gear icon.
    @State private var settingsRoom: Room?
    /// V0.79 — flips when the one-time notif prompt is answered so
    /// SwiftUI re-renders the card away (UserDefaults isn't observed).
    @State private var notifPromptDismissed: Bool = false
    // V0.84 C5 — flips when the one-line drop is dismissed locally
    // so SwiftUI re-renders the prompt away (UserDefaults isn't
    // observed directly). The underlying dismissal flag is stored
    // under `StorageKeys.memberNotePromptDismissed(eventId:)`.
    @State private var memberNotePromptDismissedFlip: Bool = false

    // P0.5 — withdraw + settle sheet bindings. Owned by the view
    // layer so `openWithdraw` / `openScan` can flip them without
    // going through `RoomService` (which would force an extra
    // round-trip). The active event is captured at sheet-present
    // time so the sheets don't drift if the user pulls-to-refresh
    // while the sheet is open.
    @State private var withdrawSheetEvent: Event?
    @State private var settleSheetEvent: Event?
    // V0.34 — count-based scoring member scan. CAH members scan
    // their own stack of won black cards on their own phone; the
    // tally is recorded as the authoritative count for the night.
    @State private var cahScanEvent: Event?
    @State private var casinoWithdrawn: Int = 0
    // V0.47 — host-only pending-withdrawal list. Loaded in
    // `refresh`; the host dispenses physical chips and taps
    // Dispensed to acknowledge (server-persisted meta stamp since
    // V0.73; ledger unchanged).
    @State private var hostWithdrawals: [EventTransaction] = []
    // V0.51 — per-member working hands for the active casino event.
    // Host sees working hand + bank balance; members see working hand only.
    @State private var workingHands: [WorkingHand] = []
    // P0.4 — host-only single-winner scoring sheet binding. Hosts
    // tap "Score a round" on the at-play Witness Slot; the sheet
    // opens for any pack (Casino hosts scan via `ChipScanSheet`).
    @State private var hostScoreEvent: Event?

    // B1.3 — host-only "+ Add an event" CTA in the in-room
    // toolbar. The `AddEventSheet` has shipped since P0.3 (comment
    // block, "Presented by `RoomDetailView` from the host-only
    // '+ Add an event' CTA") but the CTA itself was never wired —
    // it lives in the toolbar so hosts can schedule the next
    // session without entering the settings sheet.
    @State private var showingAddEvent: Bool = false

    // V0.9 Wave 2 Slice 2.2 - the inline "+" in RoomSwitcherMenu
    // opens the same CreateRoomSheet the Rooms tab's "+" opens.
    @State private var showingCreateRoom: Bool = false

    // W2.4 — member-side event edit sheet binding.
    @State private var editEvent: Event?

    // Track P0.4 — iPad host scoring dashboard visibility. Starts true so
    // the dashboard replaces the scroll content the moment the host
    // enters a live `single_winner` event on iPad landscape; the
    // dashboard's Close button returns to the scroll.
    @State private var scoringDashboardVisible: Bool = true

    /// Seat-action error surface. `claimSeat` / `declineSeat` /
    /// `releaseSeat` set `seatActionError` + flip
    /// `showSeatActionError` on failure; the body's `.alert`
    /// presents the message. Driven at the view layer so the
    /// service's `lastError` keeps its existing role and isn't
    /// reshaped by this loop.
    @State private var seatActionError: String?
    @State private var showSeatActionError: Bool = false

    private var isHost: Bool {
        guard let uid = authService.currentUser?.id else { return false }
        return room.userRole == .host || room.createdBy == uid
    }

    /// Track P0.4 — gate for the iPad host scoring dashboard. Only
    /// fires on iPad regular width, host-side, during a live
    /// `single_winner` event (playedAt <= now && settledAt == nil).
    /// Settled events (settledAt within 24h, no new event) render the
    /// normal scroll body on iPad — casino hosts scan via `ChipScanSheet`.
    private var showScoringDashboard: Bool {
        guard scoringDashboardVisible else { return false }
        guard hSize == .regular else { return false }
        guard isHost else { return false }
        guard let event = activeEvent else { return false }
        guard event.playedAt <= Date() else { return false }
        guard event.settledAt == nil else { return false }
        guard let pack = PackRegistry.shared.definition(for: event.packSlug) else { return false }
        return pack.scoringType == .singleWinner
    }

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

    /// V0.62 — single source of truth for the caller's working hand,
    /// derived from `workingHands` (loaded via `get_event_working_hands`,
    /// migration 065). Replaces the old `casinoWithdrawn` derivation
    /// from `get_my_open_withdrawal`, which returned empty on the live
    /// DB and stranded the state machine at `.tonightEvent`. `workingHands`
    /// is keyed by `WorkingHand.memberId: UUID`; `currentUserId` is
    /// `UUID?`; Swift allows `UUID? == UUID` for the lookup.
    private var myWorkingHand: Int {
        workingHands.first(where: { $0.memberId == currentUserId })?.workingHand ?? 0
    }

    /// V0.45 — freshest cached copy of this room. The value passed
    /// in at navigation goes stale after a settings save, so display
    /// surfaces read through the service cache; `room` remains the
    /// fallback until the cache holds it.
    private var liveRoom: Room {
        roomService.room(withId: room.id) ?? room
    }

    /// V0.66 — whether the room has the CAH pack installed. Empty
    /// cache means no explicit overrides → all packs installed
    /// (matches the Operations sub-sheet convention). Drives the
    /// secondary "Count your CAH cards" CTA on every active event.
    private var roomHasCAHPack: Bool {
        let enabled = roomService.cachedRoomPacks(roomId: room.id)
        if enabled.isEmpty { return true }
        return enabled.contains(CardsAgainstHumanityPack.slug)
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

    /// V0.47 — withdrawals still awaiting physical chip dispensing.
    /// V0.73 — the dispensed filter is now server-persisted
    /// (`meta.dispensed`, stamped by `mark_withdrawal_dispensed`,
    /// migration 073) instead of a local `@State` set that forgot
    /// every acknowledgement on relaunch.
    private var pendingWithdrawals: [EventTransaction] {
        hostWithdrawals.filter { !$0.isDispensed }
    }

    /// V0.51 — active casino play (`.inPlay` or `.settleRound`): the
    /// event has started, is not settled, and the room is running
    /// the casino pack. Drives the render gate for the "Chips on
    /// the table" section.
    private var isCasinoPlayActive: Bool {
        guard let event = activeEvent else { return false }
        return event.packSlug == "casino"
            && event.playedAt <= Date()
            && event.settledAt == nil
    }

    /// V0.72 (072) — the current member's scan state for the active
    /// event, from the working-hands read (get_event_working_hands
    /// now returns has_scanned + scanned_value per member).
    private var myScanState: (hasScanned: Bool, scannedValue: Int?) {
        let mine = workingHands.first(where: { $0.memberId == currentUserId })
        return (mine?.hasScanned ?? false, mine?.scannedValue)
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
        Group {
            if showScoringDashboard, let event = activeEvent {
                HostScoringDashboard(room: room, event: event, onClose: { scoringDashboardVisible = false })
                    .environmentObject(roomService)
                    .environmentObject(scoringService)
            } else {
                scrollBody
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .navigationTitle(liveRoom.name)
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
                        onSwitchRoom: onSwitchRoom,
                        onCreateRoom: { showingCreateRoom = true }
                    )
                }
            }
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddEvent = true
                    } label: {
                        Image(systemName: Theme.Icon.chairFill)
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    .accessibilityLabel(Text("Add an event"))
                    .accessibilityHint(Text("Schedule the next games night in \(room.name)"))
                }
            }
            // V0.79 — the gear is member-visible. The settings sheet
            // self-gates its host-only sections; members gain the
            // "My notifications" section (opt-in + per-event mute).
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    settingsRoom = liveRoom
                } label: {
                    Image(systemName: Theme.Icon.gearshape)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .accessibilityLabel(Text("Room settings"))
                .accessibilityHint(Text("Opens settings for \(room.name)"))
            }
        }
        .sheet(item: $settingsRoom) { presented in
            RoomSettingsSheet(room: presented, onRoomDeleted: {
                // W-04 — pop back to the rooms list; the deleted
                // room is already gone from the service cache.
                dismiss()
            })
            .environmentObject(roomService)
            .environmentObject(casinoService)
        }
        .sheet(item: $editEvent) { event in
            EditEventSheet(event: event)
                .environmentObject(roomService)
        }
        .sheet(isPresented: $showingAddEvent) {
            AddEventSheet(
                roomId: room.id,
                onSaved: { _ in
                    showingAddEvent = false
                    Task { await refresh(force: true) }
                }
            )
            .environmentObject(roomService)
        }
        .sheet(item: $withdrawSheetEvent) { event in
            WithdrawChipsSheet(
                eventId: event.id,
                roomId: room.id,
                onDone: { Task { await refresh(force: true) } }
            )
            .environmentObject(casinoService)
            .environmentObject(authService)
        }
        .sheet(item: $settleSheetEvent) { event in
            // V0.50 — vision-first settle. Hosts AND members land
            // here from "Scan your chips" / "Score a round" so the
            // host gets the same vision surface as the member. The
            // host's `record_member_scan` is keyed off the caller's
            // own withdrawal row, so a host who withdrew can scan
            // their own chips cleanly.
            ChipScanSheet(
                eventId: event.id,
                roomId: room.id,
                withdrawn: casinoWithdrawn,
                onDone: { Task { await refresh(force: true) } }
            )
            .environmentObject(casinoService)
            .environmentObject(authService)
        }
        // V0.34 — count_based (CAH) member scan surface. The
        // member scans their stack of won black cards on their own
        // phone; the on-device segmentation detector (LOCKED,
        // `pxPerUnit: 2`) produces a rough estimate, the member
        // confirms / adjusts, and `record_cah_tally` (migration
        // 054) records the tally as the authoritative count for
        // the night. Re-scan converges.
        .sheet(item: $cahScanEvent) { event in
            CAHCardScanSheet(
                eventId: event.id,
                roomId: room.id,
                onDone: { Task { await refresh(force: true) } }
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
                packDisplayName: pack?.displayName ?? event.packSlug,
                defaultCardCount: roomService.effectiveWinPoints(roomId: room.id, packSlug: event.packSlug)
            )
            .environmentObject(roomService)
            .environmentObject(scoringService)
        }
        // V0.9 Wave 2 Slice 2.2 - inline "+" create-room sheet. Same
        // surface as the Rooms-tab "+" (CreateRoomSheet, owned here
        // so it dismisses cleanly when the user backs out of the
        // menu without a confirmed create).
        .sheet(isPresented: $showingCreateRoom) {
            CreateRoomSheet()
                .environmentObject(roomService)
        }
        .task {
            await refresh()
        }
        .refreshable {
            await refresh(force: true)
            Haptics.light()
        }
        .alert("Seat action failed", isPresented: $showSeatActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(seatActionError ?? "")
        }
    }

    // Track P0.4 — existing scroll content moved here so the body can
    // branch on `showScoringDashboard` (iPad host scoring surface).
    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                activeSlot
                    .frame(maxWidth: .infinity)
                // V0.84 C1 — host-only pre-loaded opening lines per
                // claimed RSVP. Pre-night only (playedAt > now); the
                // member never sees this surface. Reads from cached
                // members + RSVPs + leaderboard (all already loaded
                // by `refresh`); recomputed when the cache changes
                // so a new RSVP or fresh leaderboard row appears
                // without a manual pull-to-refresh.
                if isHost,
                   let event = activeEvent,
                   event.playedAt > Date() {
                    HostOpenersSection(
                        eventId: event.id,
                        mascotName: liveRoom.mascotName,
                        members: roomService.cachedMembers(roomId: room.id),
                        rsvps: roomService.cachedEventRSVPs(eventId: event.id),
                        leaderboard: leaderboard,
                        now: Date()
                    )
                    .sectionCard(.standard)
                }
                // V0.79 — one-time notification opt-in prompt. Shows
                // once per room (per device) while opt-in is off;
                // after any answer it lives in Room settings only.
                if activeEvent != nil,
                   !liveRoom.notificationsEnabled,
                   !notifPromptDismissed,
                   !RoomNotifPrompt.isAnswered(roomId: room.id) {
                    RoomNotifPromptCard(
                        roomName: room.name,
                        onOptIn: {
                            RoomNotifPrompt.markAnswered(roomId: room.id)
                            notifPromptDismissed = true
                            Task {
                                try? await roomService.setNotificationsEnabled(
                                    roomId: room.id, enabled: true
                                )
                                Haptics.light()
                            }
                        },
                        onDismiss: {
                            RoomNotifPrompt.markAnswered(roomId: room.id)
                            notifPromptDismissed = true
                        }
                    )
                }
                // V0.66 — host-only "Chips to dispense" cards during active
                // casino play when withdrawals await dispensing.
                if isCasinoPlayActive, isHost, !pendingWithdrawals.isEmpty {
                    HostWithdrawalsSection(
                        withdrawals: pendingWithdrawals,
                        onDispense: { id in
                            Task {
                                _ = await casinoService.markWithdrawalDispensed(transactionId: id)
                                await loadHostWithdrawalsIfNeeded()
                            }
                        }
                    )
                    .sectionCard(.standard)
                }
                // V0.85 — host-only arrival card at session start.
                // Renders when the room runs the deposit escrow,
                // the active event is live (played, not settled),
                // the caller is the host, and held deposits are
                // waiting on a check-in the grace window has
                // covered. The host decides forfeit vs skip per
                // candidate; the system never decides alone.
                if let event = activeEvent,
                   isHost,
                   event.playedAt <= Date(),
                   event.settledAt == nil,
                   liveRoom.seatDepositTrigger == .escrow,
                   !roomService.cachedArrivalCandidates(eventId: event.id).isEmpty {
                    ArrivalCard(
                        room: liveRoom,
                        event: event,
                        candidates: roomService.cachedArrivalCandidates(eventId: event.id),
                        onForfeit: { candidate in
                            Task { await resolveArrivalCandidate(candidate, forfeit: true) }
                        },
                        onSkipTexted: { candidate in
                            Task { await resolveArrivalCandidate(candidate, forfeit: false, reason: "texted") }
                        },
                        onSkipAway: { candidate in
                            Task { await resolveArrivalCandidate(candidate, forfeit: false, reason: "away") }
                        }
                    )
                    .sectionCard(.standard)
                }
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
                if let event = activeEvent,
                   !roomService.cachedEventRounds(eventId: event.id).isEmpty {
                    RoundBreakdownSection(
                        rounds: roomService.cachedEventRounds(eventId: event.id),
                        members: roomService.cachedMembers(roomId: room.id)
                    )
                    .sectionCard(.standard)
                }
                // W-05 — previous-seasons comparison (US-10).
                // Renders only when the room has ended seasons; the
                // section is member-visible (read surface).
                if !roomService.cachedSeasonHistory(roomId: room.id).isEmpty {
                    SeasonHistorySection(
                        rows: roomService.cachedSeasonHistory(roomId: room.id),
                        currentScore: leaderboard.first(where: { $0.userId == currentUserId })?.seasonScore ?? 0
                    )
                    .sectionCard(.standard)
                }
                CollapsibleSection(title: "Packs", caption: "Games-night rules your room is set up for.") {
                    PackShelfReadOnly(room: room)
                        .environmentObject(casinoService)
                }
                .sectionCard(.standard)
                CollapsibleSection(title: "Members", caption: "Everyone with a seat at the table.") {
                    MemberRosterReadOnly(room: room)
                }
                .sectionCard(.standard)
                MascotFooterCaption(
                    room: liveRoom,
                    activeEvent: activeEvent,
                    leaderboard: leaderboard,
                    currentUserId: currentUserId,
                    withdrawnAmount: casinoWithdrawn,
                    currentSeason: currentSeason
                )
            }
            .padding(.horizontal, Theme.Layout.edgePadding)
            .padding(.vertical, Theme.Layout.sectionSpacing)
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
            if isLive && myWorkingHand == 0 {
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
    /// Drowning rows are kept only when:
    ///   - the current user IS the recipient (always allowed), OR
    ///   - the current user is the host of the room (host oversight),
    ///   - OR the current user has opted in to Drowning shares
    ///     (per-room member_drowning_opt_in flag, migration 045).
    /// The SQL RLS layer also enforces this gate — this resolver is
    /// belt-and-braces against a server regression.
    private var seasonAwardsForPrivacy: [SeasonAward] {
        let all = roomService.cachedSeasonAwards(
            seasonId: currentSeason?.id ?? UUID()
        )
        guard let me = authService.currentUser?.id else { return all }
        let isHost = room.userRole == .host
        let optedIn = room.memberDrowningOptIn
        return all.filter { row in
            guard row.awardType.isPrivate else { return true }
            // Recipient always sees their own row.
            if row.recipientUserId == me { return true }
            // Host always sees drowning rows.
            if isHost { return true }
            // Otherwise: only opted-in members see other drowning rows.
            return optedIn
        }
    }

    /// V0.53 — builds the current user's shareable stat card for a
    /// closed season. Only the member's own numbers and public awards;
    /// Drowning is excluded before the card is built. `nil` when the
    /// current user has no leaderboard row (never played this season)
    /// or no current user is signed in.
    private func currentUserStatCard(
        season: Season,
        awards: [SeasonAward]
    ) -> SeasonStatCard? {
        guard let me = authService.currentUser?.id else { return nil }
        guard let entry = leaderboard.first(where: { $0.userId == me }) else {
            return nil
        }
        // Public awards only — Drowning never appears on the card.
        let publicAwards = awards
            .filter { !$0.awardType.isPrivate }
            .map(\.awardType)
        let best = entry.trajectory.map(\.delta).max()
        let worst = entry.trajectory.map(\.delta).min()
        return SeasonStatCard(
            roomName: room.name,
            seasonOrdinal: season.ordinal,
            seasonSubtitle: season.subtitle,
            memberName: entry.displayName,
            record: SeasonStatRecord(
                sessionsPlayed: Int(entry.sessionsPlayed),
                netChips: entry.seasonScore,
                bestSingleSession: best,
                worstSingleSession: worst,
                longestStreak: 0
            ),
            awards: publicAwards,
            mascotLine: season.ordinal.isMultiple(of: 2)
                ? "The deposit is the promise. The night is the payoff."
                : "You bring the chips. It brings the memory."
        )
    }

    @ViewBuilder
    private var activeSlot: some View {
        Group {
            switch state {
            case .loading:
                VStack { ProgressView().tint(Theme.Palette.accent) }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Layout.sectionSpacing * 2)

            case .upcoming(let event):
                BriefingSlot(
                    event: event,
                    briefing: briefing,
                    myRSVP: myRSVP,
                    onClaim: { Task { await claimSeat(eventId: event.id) } },
                    onDecline: { Task { await declineSeat(eventId: event.id) } },
                    onReAccept: { Task { await claimSeat(eventId: event.id) } },
                    onReDecline: { Task { await declineSeat(eventId: event.id) } },
                    rsvps: roomService.cachedEventRSVPs(eventId: event.id),
                    currentUserId: currentUserId,
                    isHost: isHost,
                    isHero: true,
                    onEdit: { editEvent = event },
                    room: room,
                    unconsumedNotes: isHost ? roomService.cachedUnconsumedMemberNotes(roomId: room.id) : [],
                    onMarkNotesConsumed: isHost
                        ? { ids in
                            Task { await markMemberNotesConsumed(roomId: room.id, noteIds: ids) }
                        }
                        : nil,
                    heldDeposit: roomService.cachedMySeatDeposit(eventId: event.id),
                    onCheckIn: { Task { await checkInSeat(eventId: event.id) } }
                )
            case .claimed(let event):
                BriefingSlot(
                    event: event,
                    briefing: briefing,
                    myRSVP: .claimed,
                    onClaim: {},
                    onDecline: {},
                    onRelease: { Task { await releaseSeat(eventId: event.id) } },
                    rsvps: roomService.cachedEventRSVPs(eventId: event.id),
                    currentUserId: currentUserId,
                    isHost: isHost,
                    isHero: true,
                    onEdit: { editEvent = event },
                    room: room,
                    unconsumedNotes: isHost ? roomService.cachedUnconsumedMemberNotes(roomId: room.id) : [],
                    onMarkNotesConsumed: isHost
                        ? { ids in
                            Task { await markMemberNotesConsumed(roomId: room.id, noteIds: ids) }
                        }
                        : nil,
                    heldDeposit: roomService.cachedMySeatDeposit(eventId: event.id),
                    onCheckIn: { Task { await checkInSeat(eventId: event.id) } }
                )
            case .declined(let event):
                // V0.9 Wave 1 Slice 1.2 — wire the re-entry pills so a
                // member who previously declined can change their mind.
                // The pills route through the same claimSeat /
                // declineSeat handlers as the first-time flow.
                BriefingSlot(
                    event: event,
                    briefing: briefing,
                    myRSVP: .declined,
                    onClaim: {},
                    onDecline: {},
                    onReAccept: { Task { await claimSeat(eventId: event.id) } },
                    onReDecline: { Task { await declineSeat(eventId: event.id) } },
                    rsvps: roomService.cachedEventRSVPs(eventId: event.id),
                    currentUserId: currentUserId,
                    isHost: isHost,
                    isHero: true,
                    onEdit: { editEvent = event },
                    room: room,
                    unconsumedNotes: isHost ? roomService.cachedUnconsumedMemberNotes(roomId: room.id) : [],
                    onMarkNotesConsumed: isHost
                        ? { ids in
                            Task { await markMemberNotesConsumed(roomId: room.id, noteIds: ids) }
                        }
                        : nil
                )

            case .inPlay(let event):
                let isCAH = event.packSlug == "cards_against_humanity"
                WitnessSlot(
                    event: event,
                    attestations: openAttestations,
                    // V0.43 — `.inPlay` means the member has already
                    // withdrawn, so the CTA flips to scan regardless
                    // of pack. `isCAH` is still used for `scanTitle`.
                    // V0.73 — but only while there's something to
                    // settle. Already scanned → passive "counted"
                    // capsule; empty hand (shouldn't co-occur with
                    // `.inPlay`, but the data can) → passive
                    // "nothing to settle" capsule.
                    cta: {
                        if isCAH { return .scan }
                        // V0.74 — every scan settles the marginal
                        // delta vs entitlement, so scan stays live
                        // even after counting (rescan to resettle:
                        // play on, win/lose, count again). Empty
                        // hand → nothing to settle.
                        if myWorkingHand == 0 {
                            return .done("Nothing to settle — withdraw to play")
                        }
                        return .scan
                    }(),
                    onWithdraw: { Task { await openWithdraw(event: event) } },
                    onScan: { Task { await openScan(event: event) } },
                    // V0.68 — "Score a round" is gated to single-winner
                    // packs only. For casino/CAH the primary settle CTA
                    // already opens the same sheet, so the host-only
                    // button is redundant there.
                    onScore: isHost && isSingleWinnerPack(event)
                        ? { Task { await openHostScore(event: event) } }
                        : nil,
                    isHero: true,
                    headerMode: .inPlay,
                    scanTitle: isCAH ? "Count your CAH cards" : "Settle casino chips",
                    workingHand: isCAH ? nil : (casinoWithdrawn > 0 ? casinoWithdrawn : nil),
                    hasScanned: !isCAH && myScanState.hasScanned,
                    scannedValue: myScanState.scannedValue,
                    // V0.66 — secondary "Count your CAH cards" CTA
                    // renders for every active event when the room
                    // has CAH installed, so a casino night can still
                    // settle CAH cards.
                    onCAHSettle: roomHasCAHPack
                        ? { cahScanEvent = event }
                        : nil,
                    // V0.68 — "Withdraw more" secondary. The member has
                    // already withdrawn into their working hand but can
                    // still top up. Casino only (CAH has no chip
                    // withdrawal concept); member AND host (host-can-play
                    // lock 2026-07-09).
                    onWithdrawMore: isCAH
                        ? nil
                        : { Task { await openWithdraw(event: event) } }
                )

            // M1.1 — `.tonightEvent` renders the witness hero with
            // the play-just-started copy + the full-width "Withdraw
            // chips" CTA. Same `WitnessSlot` component as `.inPlay`;
            // the started-time caption is what differentiates this
            // state from the post-withdrawal one.
            case .tonightEvent(let event):
                let isCAH = event.packSlug == "cards_against_humanity"
                WitnessSlot(
                    event: event,
                    attestations: openAttestations,
                    cta: isCAH ? .scan : .withdraw,
                    onWithdraw: { Task { await openWithdraw(event: event) } },
                    onScan: { Task { await openScan(event: event) } },
                    // V0.68 — "Score a round" gated to single-winner
                    // packs only (see `.inPlay`). No "Withdraw more"
                    // here — withdraw is already the primary CTA.
                    onScore: isHost && isSingleWinnerPack(event)
                        ? { Task { await openHostScore(event: event) } }
                        : nil,
                    isHero: true,
                    headerMode: .tonightEvent,
                    scanTitle: isCAH ? "Count your CAH cards" : "Settle casino chips",
                    // V0.66 — secondary "Count your CAH cards" CTA
                    // renders for every active event when the room
                    // has CAH installed, so a casino night can still
                    // settle CAH cards.
                    onCAHSettle: roomHasCAHPack
                        ? { cahScanEvent = event }
                        : nil
                )

            // M1.1 — `.seasonClose` renders the awards card with the
            // privacy-filtered awards for the current user. The
            // drowning row stays visible only to the recipient / host /
            // opted-in members; the AwardsCard renders the drowning row
            // through DrowningBadge when it appears.
            case .seasonClose(let season, let awards):
                AwardsCard(
                    season: season,
                    awards: awards,
                    currentUserId: authService.currentUser?.id,
                    isHost: room.userRole == .host,
                    currentUserOptedIn: room.memberDrowningOptIn,
                    statCard: currentUserStatCard(season: season, awards: awards),
                    onToggleDrowningOptIn: { newValue in
                        Task { await setDrowningOptIn(newValue) }
                    }
                )
            case .settleRound(let event):
                let isCAH = event.packSlug == "cards_against_humanity"
                WitnessSlot(
                    event: event,
                    attestations: openAttestations,
                    // V0.34 — settleRound always shows the scan CTA
                    // (no CAH override here per spec — host has
                    // already finalised, the member is tallying).
                    // V0.73 — same honest-CTA gating as `.inPlay`:
                    // scanned or empty-hand members get a passive
                    // capsule instead of a settle button they can't
                    // act on truthfully.
                    cta: {
                        if isCAH { return .scan }
                        // V0.74 — same as `.inPlay`: scan always
                        // settles the marginal delta, so it stays
                        // live through the final count.
                        if myWorkingHand == 0 {
                            return .done("No chips to settle")
                        }
                        return .scan
                    }(),
                    onWithdraw: { Task { await openWithdraw(event: event) } },
                    onScan: { Task { await openScan(event: event) } },
                    // V0.68 — "Score a round" gated to single-winner
                    // packs only (see `.inPlay`). No "Withdraw more" —
                    // host has finalised, settlement in progress.
                    onScore: isHost && isSingleWinnerPack(event)
                        ? { Task { await openHostScore(event: event) } }
                        : nil,
                    isHero: true,
                    headerMode: .settleRound,
                    scanTitle: isCAH ? "Count your CAH cards" : "Settle casino chips",
                    workingHand: isCAH ? nil : (casinoWithdrawn > 0 ? casinoWithdrawn : nil),
                    hasScanned: !isCAH && myScanState.hasScanned,
                    scannedValue: myScanState.scannedValue,
                    // V0.66 — secondary "Count your CAH cards" CTA
                    // renders for every active event when the room
                    // has CAH installed, so a casino night can still
                    // settle CAH cards.
                    onCAHSettle: roomHasCAHPack
                        ? { cahScanEvent = event }
                        : nil
                )

            case .justSettled(let event):
                CeremonialCard(
                    event: event,
                    chapterLine: roomService.cachedEventChapterLine(eventId: event.id),
                    tonightStarCard: roomService.cachedTonightStarCard(eventId: event.id),
                    hostPickMembers: roomService.cachedMembers(roomId: room.id),
                    isHost: isHost,
                    memberNoteWindowOpen: memberNoteWindowOpen(for: event),
                    memberNotePromptVisible: memberNotePromptVisible(for: event.id),
                    onTonightStarPick: isHost
                        ? { memberId, category, custom in
                            Task { await setTonightStarPick(event: event, memberId: memberId, category: category, customText: custom) }
                        }
                        : nil,
                    onSubmitMemberNote: !isHost
                        ? { text in
                            Task { await submitMemberNote(roomId: room.id, text: text) }
                        }
                        : nil,
                    onSkipMemberNote: !isHost
                        ? { skipMemberNotePrompt(for: event.id) }
                        : nil
                )

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
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: state)
    }

    // MARK: - Data operations

    /// Loads every dependency the V0.8 stage needs in parallel:
    /// the active event, the briefing summary, the leaderboard,
    /// the current member's RSVP, the open attestations, the room
    /// members (for the P1.1 roster surface), and the current
    /// season + awards (for the M1.1 `.seasonClose` slot).
    /// Called from `.task` and `.refreshable`.
    private func refresh(force: Bool = false) async {
        Perf.event("refresh start force=\(force)")
        async let active: () = loadActiveIfNeeded(force: force)
        async let board: () = loadLeaderboardIfNeeded(force: force)
        async let attestations: () = loadAttestations()
        async let briefingLoad: () = loadBriefingIfNeeded(force: force)
        async let rsvpLoad: () = loadRSVPIfNeeded(force: force)
        async let membersLoad: () = loadMembersIfNeeded(force: force)
        async let seasonLoad: () = loadSeasonIfNeeded(force: force)
        async let eventsLoad: [RoomSystemEvent] = roomService.loadSystemEvents(roomId: room.id, force: force)
        async let rsvpGridLoad: () = loadRSVPGridIfNeeded(force: force)
        async let packConfigLoad: () = loadPackConfigsIfNeeded(force: force)
        async let packsLoad: [String] = roomService.loadRoomPacks(roomId: room.id, force: force)
        async let roundsLoad: () = loadRoundsIfNeeded(force: force)
        async let chapterLoad: () = loadChapterLineIfNeeded(force: force)
        async let hostWithdrawalsLoad: () = loadHostWithdrawalsIfNeeded()
        async let workingHandsLoad: () = loadWorkingHandsIfNeeded()
        // V0.84 C2 — Tonight's Star card. Loaded every refresh so
        // a host pick made on another device shows up on next open.
        async let tonightStarLoad: () = loadTonightStarCardIfNeeded(force: force)
        // V0.84 C5 — host-only unconsumed member notes. Guarded
        // on `isHost` so the member path is free of the RPC.
        async let notesLoad: () = loadUnconsumedNotesIfNeeded(force: force)
        // V0.85 — arrival card source. Host-only RPC; the member
        // path never fires it (guard inside loader).
        async let arrivalLoad: () = loadArrivalCandidatesIfNeeded(force: force)
        // V0.85 — the caller's own held deposit (the chair card
        // reclaim state). Member path; cheap read. No event →
        // nothing to hold.
        async let myDepositLoad: () = {
            guard let event = activeEvent else { return }
            await roomService.loadMySeatDeposit(eventId: event.id, force: force)
        }()
        _ = await (active, board, attestations, briefingLoad, rsvpLoad, membersLoad, seasonLoad, eventsLoad, rsvpGridLoad, packConfigLoad, packsLoad, roundsLoad, chapterLoad, hostWithdrawalsLoad, workingHandsLoad, tonightStarLoad, notesLoad, arrivalLoad, myDepositLoad)
        Perf.event("refresh end")
        // W2.3 — keep the widget/watch snapshot fresh with the
        // current standings. Best-effort write; the stale-empty
        // rule in `ScoreSnapshot.shouldPersist` keeps a rooms-list
        // refresh from clobbering real standings.
        let topLine = leaderboard.prefix(3)
            .map { "\($0.displayName) \($0.pointsBalance)" }
            .joined(separator: " · ")
        ScoreSnapshotStore.write(
            roomName: room.name,
            leaderboardLine: topLine,
            isLive: activeEvent?.playedAt ?? .distantFuture <= Date()
        )
        // W2.3 — drive the Live Activity per the vision lifecycle
        // (surface pre-play/post-settle, never during play).
        ScoreLiveActivityDriver.apply(
            roomName: room.name,
            leaderboardLine: topLine,
            isLive: activeEvent?.playedAt ?? .distantFuture <= Date()
        )
    }

    /// Loads the chapter line for the active event so the
    /// ceremonial card renders the written title + call-forward.
    /// No-op when there's no active event.
    private func loadChapterLineIfNeeded(force: Bool = false) async {
        guard let event = activeEvent else { return }
        await roomService.loadEventChapterLine(eventId: event.id, force: force)
    }

    /// V0.84 C2 — loads Tonight's Star card for the active event so
    /// the ceremonial-card star section renders. No-op when there's
    /// no active event.
    private func loadTonightStarCardIfNeeded(force: Bool = false) async {
        guard let event = activeEvent else { return }
        await roomService.loadTonightStarCard(eventId: event.id, force: force)
    }

    /// V0.84 C5 — host-only. Loads the room's unconsumed member
    /// notes so the BriefingSlot pre-event notes section renders
    /// when the host opens the room. Guarded on `isHost` so the
    /// member path is free of the RPC.
    private func loadUnconsumedNotesIfNeeded(force: Bool = false) async {
        guard isHost else { return }
        _ = await roomService.loadUnconsumedMemberNotes(roomId: room.id, force: force)
    }

    /// Loads the per-round breakdown for the active event so the
    /// leaderboard's round history renders. No-op when there's no
    /// active event.
    private func loadRoundsIfNeeded(force: Bool = false) async {
        guard let event = activeEvent else { return }
        await roomService.loadEventRounds(eventId: event.id, force: force)
    }

    /// Loads the per-member RSVP rows for the active event so the
    /// briefing slot's seat grid renders claimed chairs. No-op when
    /// there's no active event.
    private func loadRSVPGridIfNeeded(force: Bool = false) async {
        guard let event = activeEvent else { return }
        await roomService.loadEventRSVPs(eventId: event.id, force: force)
    }

    /// Loads the room's pack payout overrides so the pack shelf
    /// shows configured payouts and the host scoring sheet uses
    /// them.
    private func loadPackConfigsIfNeeded(force: Bool = false) async {
        await roomService.loadRoomPackConfigs(roomId: room.id, force: force)
    }

    /// Loads the room's current season and (if present) its awards.
    /// Triggered on every refresh so a host declaring a season-close
    /// in another tab surfaces on next pull-to-refresh.
    private func loadSeasonIfNeeded(force: Bool = false) async {
        await roomService.loadCurrentSeason(roomId: room.id, force: force)
        if let season = roomService.cachedCurrentSeason(roomId: room.id) {
            await roomService.loadSeasonAwards(seasonId: season.id, force: force)
        }
        // W-05 — previous-seasons comparison (US-10). Loaded on
        // every refresh so a host declaring a season-close in
        // another tab surfaces the new ended-season row on the
        // next pull-to-refresh.
        _ = await roomService.loadSeasonHistory(roomId: room.id, force: force)
    }

    private func loadMembersIfNeeded(force: Bool = false) async {
        // Always re-fetch on refresh so a member who joined after
        // the first paint shows up in the roster without a manual
        // pull-to-refresh.
        await roomService.loadRoomMembers(roomId: room.id, force: force)
    }

    private func loadActiveIfNeeded(force: Bool = false) async {
        if roomService.cachedActiveEvent(roomId: room.id) == nil {
            let event = await roomService.loadActiveEvent(
                roomId: room.id, force: force
            )
            // V0.91 — late-opt-in catch-up on room-open. When the
            // local user is opted in to this room and an active
            // event exists, schedule the on-create push for it if
            // the dispatcher has no pending request for the same
            // (eventId, kind, userId) identifier. Covers the case
            // where the realtime INSERT was missed (device
            // suspended, offline at creation moment) AND the case
            // where the user just opted in and is now opening the
            // room for the first time since.
            if event != nil {
                await roomService.scheduleActiveEventOnCreateIfMissing(
                    roomId: room.id
                )
            }
        }
    }

    private func loadLeaderboardIfNeeded(force: Bool = false) async {
        // Honor `force`: a post-scan `refresh(force: true)` must re-fetch
        // even when the cache is already populated, or the standings
        // card keeps showing the pre-scan balance. (V0.72 settle writes
        // points_balance/season_score server-side; the cache was never
        // invalidated on the client.)
        if force || roomService.cachedLeaderboard(roomId: room.id).isEmpty {
            await roomService.loadLeaderboard(roomId: room.id, force: force)
        }
    }

    private func loadBriefingIfNeeded(force: Bool = false) async {
        guard let event = roomService.cachedActiveEvent(roomId: room.id) else { return }
        if roomService.cachedBriefing(eventId: event.id) == nil {
            await roomService.loadBriefing(eventId: event.id, force: force)
        }
    }

    private func loadRSVPIfNeeded(force: Bool = false) async {
        guard let event = roomService.cachedActiveEvent(roomId: room.id) else { return }
        // Always re-fetch on refresh so a stale `.claimed` from a
        // previous session is reconciled against the server.
        await roomService.loadCurrentMemberRSVP(eventId: event.id, force: force)
    }

    private func loadAttestations() async {
        // CasinoService.getMyOpenAttestations is non-throwing and
        // collapses failures to an empty array. We re-fetch on
        // every refresh so the banner reflects newly-opened rows.
        let rows = await Perf.span("loadAttestations") { await casinoService.getMyOpenAttestations() }
        self.openAttestations = rows
    }

    /// V0.47 — loads the host-only pending-withdrawal list.
    /// Guards on host role and the active event being casino;
    /// ensures the active event is cached first so ordering
    /// within the parallel `refresh` doesn't matter. Filters
    /// `casino_withdrawal` rows so the host only sees
    /// withdrawals (the RPC also returns `casino_return` and
    /// other kinds).
    private func loadHostWithdrawalsIfNeeded() async {
        guard isHost else {
            hostWithdrawals = []
            return
        }
        if roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id, force: false)
        }
        guard let event = activeEvent, event.packSlug == "casino" else {
            hostWithdrawals = []
            return
        }
        let all = await Perf.span("loadHostWithdrawals") { await casinoService.getEventTransactions(eventId: event.id) }
        hostWithdrawals = all.filter { $0.kind == "casino_withdrawal" }
    }

    /// V0.51 — loads every room member's working hand for the
    /// active casino event. Runs in the parallel `refresh`; the
    /// service call is non-throwing and collapses to `[]` on
    /// failure, so an empty read renders the section in its
    /// hidden state rather than an error path.
    ///
    /// V0.62.1 — guards on the active-event cache the same way
    /// `loadHostWithdrawalsIfNeeded` does. Without this, a
    /// `refresh` tick where `loadWorkingHandsIfNeeded` runs
    /// before `loadActiveIfNeeded` sees `activeEvent == nil`,
    /// blanks `workingHands`, and pins the casino state machine
    /// at `.tonightEvent` even though the DB shows a non-zero
    /// `working_hand` for the current user.
    private func loadWorkingHandsIfNeeded() async {
        if roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id, force: false)
        }
        guard let event = activeEvent, event.packSlug == "casino" else {
            workingHands = []
            return
        }
        workingHands = await Perf.span("loadWorkingHands") { await casinoService.loadWorkingHands(eventId: event.id) }
        // V0.62 — mirror the caller's working hand into `casinoWithdrawn`
        // so every existing `casinoWithdrawn` reader (sheets, mascot,
        // witness-slot badge) stays correct without touching call sites.
        casinoWithdrawn = myWorkingHand
    }

    /// V0.85 — loads the arrival card source
    /// (`list_arrival_candidates(p_event_id)`, migration 085).
    /// No-op when there's no active event or the room runs
    /// deposits off. Host-gated so a member view never trips the
    /// RPC's host check.
    private func loadArrivalCandidatesIfNeeded(force: Bool = false) async {
        guard isHost else { return }
        guard liveRoom.seatDepositTrigger == .escrow else { return }
        guard let event = activeEvent else { return }
        await roomService.loadArrivalCandidates(eventId: event.id, force: force)
    }

    /// V0.85 — host-only. Routes a single candidate's button-tap
    /// to either `forfeit_seat_deposit` or `waive_seat_deposit`
    /// (migration 085). On failure the body-level `.alert`
    /// (`showSeatActionError`) presents the localized message; on
    /// success the service removes the candidate from the cached
    /// list so the arrival card re-renders without the resolved
    /// row. Reloads candidates + leaderboard so the public
    /// ledger rows the forfeit path writes show up on the next
    /// refresh.
    private func resolveArrivalCandidate(
        _ candidate: SeatDepositCandidate,
        forfeit: Bool,
        reason: String? = nil
    ) async {
        guard let event = activeEvent else { return }
        do {
            if forfeit {
                try await roomService.forfeitSeatDeposit(
                    eventId: event.id, memberId: candidate.userId
                )
            } else {
                try await roomService.waiveSeatDeposit(
                    eventId: event.id, memberId: candidate.userId, reason: reason
                )
            }
            seatActionError = nil
            Haptics.light()
            _ = await roomService.loadLeaderboard(roomId: room.id, force: true)
            await loadArrivalCandidatesIfNeeded(force: true)
        } catch {
            seatActionError = (error as NSError).localizedDescription
            showSeatActionError = true
        }
    }

    // MARK: - Action handlers (wired to the service layer)

    /// Fires `RoomService.claimSeat(eventId)` for the active
    /// event. When the room runs the deposit escrow
    /// (`seatDepositTrigger == .escrow`) the service routes
    /// through `claim_seat_with_deposit` (migration 085) so the
    /// deposit leaves the balance into escrow atomically with
    /// the RSVP claim; otherwise the plain RSVP upsert runs. On
    /// failure the previous state is preserved and the
    /// body-level `.alert` (`showSeatActionError`) presents the
    /// localized message (e.g. the 42501 balance-too-low error).
    private func claimSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .claimed, currentUserId: currentUserId)
        do {
            _ = try await roomService.claimSeat(eventId: eventId)
            seatActionError = nil
            Haptics.success()
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            seatActionError = (error as NSError).localizedDescription
            showSeatActionError = true
        }
    }

    /// Fires `RoomService.upsertEventRSVP(eventId, .declined)`.
    /// Mirror of `claimSeat`.
    private func declineSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .declined, currentUserId: currentUserId)
        do {
            _ = try await roomService.upsertEventRSVP(eventId: eventId, state: .declined)
            seatActionError = nil
            Haptics.light()
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            seatActionError = (error as NSError).localizedDescription
            showSeatActionError = true
        }
    }

    /// V0.85 — the "I'm here" reclaim. Fires
    /// `RoomService.checkInSeat(eventId)` (migration 085's
    /// `check_in_seat` RPC); the held deposit returns to the
    /// balance and the cached deposit flips out of `.held` so
    /// the chair card drops the reclaim button. Errors surface
    /// via the shared seat-action alert.
    private func checkInSeat(eventId: UUID) async {
        do {
            try await roomService.checkInSeat(eventId: eventId)
            seatActionError = nil
            Haptics.success()
        } catch {
            seatActionError = (error as NSError).localizedDescription
            showSeatActionError = true
        }
    }

    /// 2026-08-10 feedback round — releases a claimed seat by
    /// flipping the RSVP back to `.unclaimed`, returning the seat to
    /// the open pool. Same RPC as claim/decline; the server treats
    /// `.unclaimed` as "no response" so the seat counts as open.
    private func releaseSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .unclaimed, currentUserId: currentUserId)
        do {
            _ = try await roomService.upsertEventRSVP(eventId: eventId, state: .unclaimed)
            seatActionError = nil
            Haptics.light()
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            seatActionError = (error as NSError).localizedDescription
            showSeatActionError = true
        }
    }

    /// V0.9 Wave 1 Slice 1.1 — fires the `set_drowning_opt_in` RPC
    /// (migration 045) when the drowning recipient toggles the
    /// share-with-the-room switch in the awards card. The service
    /// refreshes the cached Room so the toggle state mirrors without
    /// a manual reload; the SQL RLS policy is the load-bearing gate.
    private func setDrowningOptIn(_ newValue: Bool) async {
        do {
            try await roomService.setDrowningOptIn(
                roomId: room.id, optIn: newValue
            )
        } catch {
            // Service already populated lastError; nothing to do here.
            _ = error
        }
    }

    /// V0.54 — fires the `set_notifications_enabled` RPC (migration
    /// 066) when the BriefingSlot's "Remind me about this room's
    /// nights" toggle flips. The service mirrors the new value
    /// into the cached Room and cancels the room's pending
    /// briefing-trio pushes so a member who just opted out stops
    /// receiving the previously-scheduled logistics pushes. Errors
    /// surface via `lastError` like the other toggles.
    private func setNotificationsEnabled(_ newValue: Bool) async {
        do {
            try await roomService.setNotificationsEnabled(
                roomId: room.id, enabled: newValue
            )
        } catch {
            _ = error
        }
    }

    /// V0.54 — fires the `set_event_notifications_muted` RPC
    /// (migration 066) when the BriefingSlot's "Mute this event"
    /// toggle flips. The service mirrors the new value into the
    /// caller's cached `eventRSVPsByEvent` row and cancels the
    /// event's pending briefing-trio pushes so the muted member
    /// doesn't receive the previously-scheduled logistics pushes
    /// for this event. Errors surface via `lastError` like the
    /// other toggles.
    private func setEventNotificationsMuted(eventId: UUID, muted: Bool) async {
        do {
            try await roomService.setEventNotificationsMuted(
                eventId: eventId, muted: muted,
                currentUserId: currentUserId
            )
        } catch {
            _ = error
        }
    }

    /// V0.84 C2 — host-only. Sets the Tonight's Star pick for an
    /// event via `set_tonight_star_pick` (migration 083). The
    /// service invalidates and reloads the Tonight's Star card
    /// cache so the ceremonial-card star section refreshes
    /// immediately. Errors surface via `lastError`.
    private func setTonightStarPick(
        event: Event,
        memberId: UUID,
        category: TonightStarOverrideCategory,
        customText: String?
    ) async {
        do {
            try await roomService.setTonightStarPick(
                eventId: event.id,
                memberId: memberId,
                category: category,
                customText: customText
            )
            Haptics.success()
        } catch {
            Perf.event("tonight star pick failed: \(error.localizedDescription)")
        }
    }

    /// V0.84 C5 — member writes a one-line drop via
    /// `submit_member_note` (migration 083). The service
    /// invalidates the notes cache; the host's next read picks it
    /// up. Locally hides the prompt via `memberNotePromptDismissedFlip`
    /// so the card disappears immediately on success.
    private func submitMemberNote(roomId: UUID, text: String) async {
        do {
            try await roomService.submitMemberNote(
                roomId: roomId, noteText: text
            )
            memberNotePromptDismissedFlip.toggle()
            Haptics.success()
        } catch {
            Perf.event("member note submit failed: \(error.localizedDescription)")
        }
    }

    /// V0.84 C5 — host-only. Stamps the listed notes consumed via
    /// `mark_member_notes_consumed` (migration 083). The service
    /// reloads the unconsumed-notes cache so the BriefingSlot
    /// notes section clears.
    private func markMemberNotesConsumed(roomId: UUID, noteIds: [UUID]) async {
        guard !noteIds.isEmpty else { return }
        do {
            try await roomService.markMemberNotesConsumed(
                roomId: roomId, noteIds: noteIds
            )
            Haptics.light()
        } catch {
            Perf.event("member notes consumed failed: \(error.localizedDescription)")
        }
    }

    /// V0.84 C5 — whether the one-line drop prompt is visible for
    /// this event. Driven by the local `UserDefaults` flag under
    /// `StorageKeys.memberNotePromptDismissed(eventId:)` plus a
    /// re-render trigger (`memberNotePromptDismissedFlip`) so
    /// SwiftUI observes the change. The prompt is local-only:
    /// "one tap to dismiss, no nagging, never returns until next
    /// recap". The window itself is gated separately by
    /// `memberNoteWindowOpen(for:)` — the per-event window here
    /// only answers "did this member already dismiss?".
    private func memberNotePromptVisible(for eventId: UUID) -> Bool {
        _ = memberNotePromptDismissedFlip
        return UserDefaults.standard.string(
            forKey: StorageKeys.memberNotePromptDismissed(eventId: eventId)
        ) == nil
    }

    /// V0.84 C5 — whether the one-line drop window is open for this
    /// event. Per the locked spec the drop arrives the NEXT MORNING
    /// with the recap, NOT on the post-session screen. The window
    /// opens once `event.settledAt` is at least 12h before now —
    /// the member reflects in private, then writes one line when
    /// the recap surfaces on the next-morning open. False before
    /// settle (no row to attach to) and during the 12h cool-down
    /// after settle.
    private func memberNoteWindowOpen(for event: Event) -> Bool {
        guard let settledAt = event.settledAt else { return false }
        return settledAt <= Date().addingTimeInterval(-12 * 3600)
    }

    /// V0.84 C5 — local-only dismissal of the one-line drop prompt.
    /// Per the spec: "one tap to dismiss, no nagging, never returns
    /// until next recap". Stored under
    /// `StorageKeys.memberNotePromptDismissed(eventId:)` as `"1"`
    /// (empty/non-present means visible).
    private func skipMemberNotePrompt(for eventId: UUID) {
        UserDefaults.standard.set(
            "1",
            forKey: StorageKeys.memberNotePromptDismissed(eventId: eventId)
        )
        memberNotePromptDismissedFlip.toggle()
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

    /// V0.68 — "Score a round" is only meaningful for single-winner
    /// packs (Monopoly Deal, Pluto Chess) whose scoring surface is
    /// `HostScoreEntrySheet`/dashboard. For `.withdrawReturn` (casino)
    /// and `.countBased` (CAH) the primary settle CTA already opens
    /// the same sheet, so the host-only button is gated off there.
    private func isSingleWinnerPack(_ event: Event) -> Bool {
        PackRegistry.shared.definition(for: event.packSlug)?.scoringType == .singleWinner
    }

    /// Chip-scan CTA. Flips `settleSheetEvent` so the
    /// `ChipScanSheet` (vision) renders. The sheet takes the
    /// member's net returned chips and routes through
    /// `ScoringService.recordRoundInput(...)`. The
    /// `record_member_scan` RPC + camera/Vision pipeline are the
    /// settle path.
    ///
    /// V0.34 — count-based scoring (CAH). When the event's pack is
    /// `cards_against_humanity`, the scan CTA opens the
    /// `CAHCardScanSheet` instead — the member scans their stack
    /// of won black cards and the tally is recorded as the
    /// authoritative count for the night.
    private func openScan(event: Event) async {
        if event.packSlug == "cards_against_humanity" {
            cahScanEvent = event
        } else {
            settleSheetEvent = event
        }
    }

    /// P0.4 — host-only "Score a round" CTA on the at-play Witness
    /// Slot. V0.50 branches on scoring type so vision is the
    /// primary host surface for both packs:
    ///   - `.withdrawReturn` (Casino) → `ChipScanSheet`
    ///     (flips `settleSheetEvent`; the vision surface).
    ///   - `.countBased` (CAH) → `CAHCardScanSheet`
    ///     (flips `cahScanEvent`; the vision surface).
    ///     Fixes the CAH-on-iPad dead tap — the dashboard gate
    ///     only renders `single_winner`, so `count_based` must
    ///     NOT route to the dashboard.
    ///   - default (`singleWinner`) → iPad regular →
    ///     `scoringDashboardVisible`; else `hostScoreEvent`.
    private func openHostScore(event: Event) async {
        guard let pack = PackRegistry.shared.definition(for: event.packSlug) else {
            if hSize == .regular {
                scoringDashboardVisible = true
            } else {
                hostScoreEvent = event
            }
            return
        }
        switch pack.scoringType {
        case .withdrawReturn:
            settleSheetEvent = event
        case .countBased:
            cahScanEvent = event
        case .singleWinner:
            if hSize == .regular {
                scoringDashboardVisible = true
            } else {
                hostScoreEvent = event
            }
        }
    }
}

// MARK: - States

private enum V0State: Equatable {
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
    /// V0.84 C5 — the room the briefing belongs to. Read by the
    /// host's notes section to surface the mascot name in the
    /// "Mascot: Member left a note for next time" line.
    let room: Room
    /// V0.9 Wave 1 Slice 1.2 - when the member has already declined,
    /// the briefing slot surfaces a "Re-accept / Re-decline" pill so
    /// the user can change their mind before the event. Wired up
    /// only when the parent passes non-nil callbacks.
    let onReAccept: (() -> Void)?
    let onReDecline: (() -> Void)?
    /// 2026-08-10 feedback round - when the member has claimed a
    /// seat, this releases it (flips the RSVP back to `.unclaimed`).
    /// Wired up only when the parent passes a non-nil callback.
    let onRelease: (() -> Void)?
    /// Per-member RSVP rows for the event, driving the seat grid.
    /// Empty until the parent's load resolves.
    let rsvps: [EventRSVP]
    /// The current user's id, so the grid can mark their seat.
    let currentUserId: UUID?
    /// Decline visibility (V0.9): only the host sees who declined.
    let isHost: Bool
    let isHero: Bool
    /// W2.4 — member-side event edit. Wired up only when the
    /// parent passes a non-nil callback.
    let onEdit: (() -> Void)?
    /// V0.84 C5 — host-only unconsumed notes for the room's
    /// pre-event host prep. Empty array (the default) means the
    /// section is hidden.
    let unconsumedNotes: [RoomMemberNote]
    /// V0.84 C5 — host-only. Stamps the listed notes consumed so
    /// the section clears. Wired up only when the parent passes
    /// a non-nil callback.
    let onMarkNotesConsumed: (([UUID]) -> Void)?
    /// V0.85 — the caller's seat deposit for the event, or nil.
    /// A held deposit renders the "I'm here" reclaim button on
    /// the chair card; nil keeps the claimed state as it was.
    let heldDeposit: SeatDeposit?
    /// V0.85 — the "I'm here" tap. Returns the held deposit
    /// instantly; the reclaim IS the check-in. Wired up only
    /// when the parent passes a non-nil callback.
    let onCheckIn: (() -> Void)?
    // V0.79 — notification toggle params removed. Preferences moved
    // to the one-time RoomNotifPromptCard (main room page) and
    // RoomSettingsSheet's "My notifications" section.

    init(
        event: Event,
        briefing: BriefingSummary?,
        myRSVP: MemberRSVPState,
        onClaim: @escaping () -> Void,
        onDecline: @escaping () -> Void,
        onReAccept: (() -> Void)? = nil,
        onReDecline: (() -> Void)? = nil,
        onRelease: (() -> Void)? = nil,
        rsvps: [EventRSVP] = [],
        currentUserId: UUID? = nil,
        isHost: Bool,
        isHero: Bool,
        onEdit: (() -> Void)? = nil,
        room: Room,
        unconsumedNotes: [RoomMemberNote] = [],
        onMarkNotesConsumed: (([UUID]) -> Void)? = nil,
        heldDeposit: SeatDeposit? = nil,
        onCheckIn: (() -> Void)? = nil
    ) {
        self.event = event
        self.briefing = briefing
        self.myRSVP = myRSVP
        self.onClaim = onClaim
        self.onDecline = onDecline
        self.onReAccept = onReAccept
        self.onReDecline = onReDecline
        self.onRelease = onRelease
        self.rsvps = rsvps
        self.currentUserId = currentUserId
        self.isHost = isHost
        self.isHero = isHero
        self.onEdit = onEdit
        self.room = room
        self.unconsumedNotes = unconsumedNotes
        self.onMarkNotesConsumed = onMarkNotesConsumed
        self.heldDeposit = heldDeposit
        self.onCheckIn = onCheckIn
    }

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
                BriefingSeatCount(summary: briefing, isHost: isHost)
            }

            // W2.4 — member-side event edit. Any member can adjust
            // the note + venue while the event is still in the
            // future; the affordance sits next to the briefing
            // content, not in a settings tab.
            if let onEdit {
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: Theme.Icon.infoCircle)
                        Text("Edit details")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            // V0.84 C5 — host-only notes section, above the seat
            // grid. Hidden when there are no unconsumed notes.
            // Per the spec: "for each note — '<MascotName>: <Member>
            // left a note for next time.' + the note text (body font).
            // After render (onAppear of section), host taps 'Done
            // reading' ⇒ markMemberNotesConsumed."
            if isHost, !unconsumedNotes.isEmpty, let onMarkNotesConsumed {
                UnconsumedMemberNotesSection(
                    room: room,
                    notes: unconsumedNotes,
                    onDone: { ids in onMarkNotesConsumed(ids) }
                )
                .padding(.top, 4)
            }

            // 2026-08-10 feedback round — the seat grid is the
            // "chairs coloured in" visual indicator: claimed seats
            // render filled with the member's initial, open seats
            // render as outline chairs, the current user's seat is
            // highlighted. Renders whenever the event has a
            // maxSeats count, even before the per-member RSVP rows
            // load (the grid then shows all-open seats).
            if event.maxSeats > 0 {
                SeatGridRow(maxSeats: event.maxSeats, rsvps: rsvps, currentUserId: currentUserId)
                    .padding(.top, 4)
                if event.startedAt == nil,
                   let caption = SocialProof.claimedSeatsCaption(
                       claimedNames: rsvps
                           .filter { $0.state == .claimed }
                           .map { $0.displayName }
                   ) {
                    Text(caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }

            // V0.79 — notification preferences left the briefing
            // card. A one-time prompt on the main room page owns
            // discovery; Room settings → "My notifications" owns
            // the durable toggles. "Can't make it" already mutes
            // per-event (dispatcher's declined gate), so no mute
            // control lives here anymore.

            // V0.86 — first-time-only mascot voice line for the
            // calendar permission. The brief: "Games Room can add
            // events to your calendar. Tap to allow." One-time,
            // then gone (substrate: no come-back engagement). The
            // gate is `EKEventStore.authorizationStatus(for:
            // .event) == .notDetermined && !CalendarPrompt
            // .hasSeenVoiceLine()`. The markSeen() fires on
            // first interaction (denied or granted) — the row
            // never re-appears.
            if CalendarService.shared.authorizationStatus() == .notDetermined,
               !CalendarPrompt.hasSeenVoiceLine() {
                CalendarVoiceLineRow()
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
                    .pressScale()
                    Button(action: onDecline) {
                        Text("Can't make it")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline))
                    }
                    .pressScale()
                }
                .padding(.top, 8)

            case .claimed:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: Theme.Icon.checkmarkCircleFill)
                            .foregroundStyle(Theme.Palette.accent)
                        Text("You're in.")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    // V0.85 — the reclaim. A held deposit renders
                    // the "I'm here" button: one tap returns the
                    // deposit and records attendance itself. The
                    // member wants their chips back, so no nagging
                    // is ever needed.
                    if let deposit = heldDeposit, deposit.status == .held, let onCheckIn {
                        Text("Tap when you walk in — your deposit comes straight back.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        Button(action: onCheckIn) {
                            Text("I'm here — reclaim \(deposit.amount) CC")
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Theme.Palette.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Check in and reclaim the \(deposit.amount) CC seat deposit"))
                    }
                    // 2026-08-10 feedback round — a claimed seat is
                    // not terminal: the member can release it and
                    // the seat returns to the open pool.
                    if let onRelease {
                        Button(action: onRelease) {
                            Text("Release my seat")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)

            case .declined:
                V0StateReEntryPills(
                    onReAccept: onReAccept ?? {},
                    onReDecline: onReDecline ?? {}
                )
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
        .appearTransition()
    }

}

// MARK: - Re-entry pills (V0.9 Wave 1 Slice 1.2)

/// Two-button row rendered when the member has already declined an
/// event. The brief previously treated `.declined` as terminal —
/// the dispatcher dropped the member from T-48h and morning-of
/// pushes, the briefing slot showed a static "you said you can't
/// make it" caption. Wave 1 Slice 1.2 surfaces a re-entry path:
/// "Re-accept" flips the row to `.claimed` (same RPC, same RLS);
/// "Re-decline" re-confirms the decline. Both buttons route
/// through `RoomService.upsertEventRSVP` so the server-side write
/// is the same code path as the first-time claim.
private struct V0StateReEntryPills: View {
    let onReAccept: () -> Void
    let onReDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You said you can\'t make it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            HStack(spacing: 12) {
                Button(action: onReAccept) {
                    Text("Re-accept")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button(action: onReDecline) {
                    Text("Re-decline")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.Palette.hairline))
                }
            }
        }
    }
}

// MARK: - Briefing seat-count row

// MARK: - Unconsumed member notes (V0.84 C5 — host pre-event)

/// V0.84 C5 — host-only section surfaced ABOVE the seat grid on
/// the BriefingSlot when the room has unconsumed member notes.
/// Per the spec: for each note — "<MascotName>: <Member> left a
/// note for next time." + the note text (body font). After render
/// (onAppear of section), host taps "Done reading" ⇒
/// `markMemberNotesConsumed` with the listed ids.
private struct UnconsumedMemberNotesSection: View {
    let room: Room
    let notes: [RoomMemberNote]
    let onDone: ([UUID]) -> Void

    /// Stable ids used by the "Done reading" CTA. Captured on
    /// `onAppear` so we don't re-snapshot every render.
    @State private var capturedIds: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes for next time")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            ForEach(notes, id: \.id) { note in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(room.mascotName): \(note.memberDisplayName) left a note for next time.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                    Text(note.noteText)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            }
            Button(action: { onDone(capturedIds) }) {
                Text("Done reading")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            if capturedIds.isEmpty {
                capturedIds = notes.map(\.id)
            }
        }
    }
}

private struct BriefingSeatCount: View {
    let summary: BriefingSummary
    /// Decline visibility (V0.9): only the host sees who declined.
    /// Members see claimed + total only — a declined seat reads as
    /// simply open. Server enforces this too (migration 064); this
    /// gate covers the optimistic-update flash before the RPC lands.
    let isHost: Bool

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
            if isHost, summary.seatsDeclined > 0 {
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

// MARK: - Seat grid row (2026-08-10 feedback round)

/// The "chairs coloured in" seat indicator on the briefing slot.
/// Renders `maxSeats` cells: claimed seats fill with the member's
/// initial, open seats render an outline chair labelled "open", and
/// the current user's seat is highlighted with the brass accent.
/// The grid adapts its column count to the seat total so 4, 6, and
/// 8-seat tables all read cleanly.
private struct SeatGridRow: View {
    let maxSeats: Int
    let rsvps: [EventRSVP]
    let currentUserId: UUID?

    /// V0.42 — fires only for the current user's claim, not every
    /// grid render. Reset to false after ~500ms so the burst is a
    /// single one-shot celebration.
    @State private var justClaimed: Bool = false

    private var columns: [GridItem] {
        let count = SeatGrid.columnCount(for: maxSeats)
        return Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: count
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(SeatGrid.cells(maxSeats: maxSeats, rsvps: rsvps)) { cell in
                seatCell(cell)
            }
        }
        .onChange(of: rsvps) { _, newValue in
            guard let me = currentUserId else { return }
            let nowClaimed = newValue.contains { $0.memberId == me && $0.state == .claimed }
            if nowClaimed {
                justClaimed = true
                Task { try? await Task.sleep(for: .milliseconds(500)); justClaimed = false }
            }
        }
    }

    @ViewBuilder
    private func seatCell(_ cell: SeatGrid.Cell) -> some View {
        if let rsvp = cell.rsvp {
            let isYours = rsvp.memberId == currentUserId
            VStack(spacing: 3) {
                Image(systemName: Theme.Icon.chairFill)
                    .font(Theme.Typography.body)
                    .foregroundStyle(isYours ? Theme.Palette.accent : Theme.Palette.primaryText.opacity(0.75))
                Text(initial(for: rsvp.displayName))
                    .font(Theme.Typography.footnote.weight(.semibold))
                    .foregroundStyle(isYours ? Theme.Palette.accent : Theme.Palette.primaryText.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isYours ? Theme.Palette.accent.opacity(0.16) : Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isYours ? Theme.Palette.accent : Theme.Palette.hairline,
                            lineWidth: isYours ? 1.0 : 0.5)
            )
            .overlay {
                if isYours && justClaimed {
                    ConfettiBurst()
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isYours)
            .accessibilityElement()
            .accessibilityLabel(Text(accessibilityLabel(for: rsvp)))
        } else {
            VStack(spacing: 3) {
                Image(systemName: Theme.Icon.chair)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.3))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Palette.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.Palette.hairline.opacity(0.6), lineWidth: 0.5)
            )
            .accessibilityElement()
            .accessibilityLabel(Text("open seat"))
        }
    }

    private func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "·" }
        return String(first).uppercased()
    }

    private func accessibilityLabel(for rsvp: EventRSVP) -> String {
        let isYours = rsvp.memberId == currentUserId
        let owner = isYours ? "your seat" : "\(rsvp.displayName)'s seat"
        return "\(owner), claimed"
    }
}

// MARK: - Witness slot (at-play)

private struct WitnessSlot: View {
    enum CTA: Equatable {
        case withdraw
        case scan
        /// V0.73 — passive "nothing more to do" state. Renders as a
        /// non-interactive capsule (not a button) so a member who has
        /// already scanned, or holds no chips to settle, isn't
        /// offered an action that lies about their state.
        case done(String)
    }

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
    /// V0.52 — the scan button's label. Defaults to
    /// "Settle casino chips" so the pack-named convention matches
    /// if a future call site omits it; CAH call sites pass
    /// "Count your CAH cards" so the button names the pack.
    var scanTitle: String = "Settle casino chips"
    /// V0.46 — working hand (withdrawn chips) surfaced in the
    /// hero badge. nil = don't render (CAH / not-yet-withdrawn).
    var workingHand: Int? = nil
    /// V0.72 (072) — the current member has already scanned their
    /// chips this session. Flips the badge from "Working hand: N"
    /// to the counted state (the chips are with the host now).
    var hasScanned: Bool = false
    /// V0.72 (072) — the member's latest scanned value, when known.
    var scannedValue: Int? = nil
    /// V0.66 — secondary "Count your CAH cards" CTA. Renders for
    /// EVERY active event when the room has the CAH pack installed,
    /// so a member/host on a casino night can still settle their CAH
    /// cards. nil = don't render. Styled as an outline button, one
    /// tap behind the primary CTA — never a second filled primary.
    var onCAHSettle: (() -> Void)? = nil
    /// V0.68 — secondary "Withdraw more" CTA. Renders for casino
    /// events in `.inPlay` (member AND host) so a member who has
    /// already withdrawn into their working hand can still top up.
    /// nil = don't render. Styled as an outline button, one tap
    /// behind the primary CTA.
    var onWithdrawMore: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 12) {
                Image(systemName: Theme.Icon.circleHexagongridFill)
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

            // V0.46 — working-hand badge. Renders only when the
            // member has chips withdrawn (casino, post-withdraw);
            // CAH and not-yet-withdrawn states pass nil. V0.70
            // pops the badge in via the parent's popIn animation
            // when `workingHand` flips from nil/0 to a positive
            // value (the withdraw lands, state moves to .inPlay).
            // V0.74 — the badge state derives from E vs the last
            // scan: `workingHand` is now the TRUE table stack (last
            // scan + withdrawals after it), so counted ⟺
            // scannedValue == workingHand. A fresh withdrawal flips
            // the badge back to pending — those chips haven't been
            // counted, and the next scan settles the whole delta.
            if let workingHand, workingHand > 0 {
                if hasScanned, let scannedValue, scannedValue == workingHand {
                    HStack(spacing: 6) {
                        Image(systemName: Theme.Icon.checkmarkCircleFill)
                        Text("Counted: \(scannedValue) pts — settled")
                    }
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(Text("Chips counted: \(scannedValue) points — settled"))
                    .padding(.top, 4)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: Theme.Icon.handPointUpFill)
                        Text("Working hand: \(workingHand) pts")
                    }
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .accessibilityLabel(Text("Working hand: \(workingHand) pts"))
                    .padding(.top, 4)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
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

            // V0.70 — single Button whose identity persists across
            // the `cta` flip. Two separate Buttons would snap the
            // label on `.withdraw` ↔ `.scan`; one Button with a
            // computed title + cross-fading text keeps the surface
            // stable. `CTA` has no associated values, so it is
            // Equatable without declaration.
            // V0.73 — `.done` isn't a button. A member who has
            // already scanned (or holds no chips) gets a passive
            // capsule, not an action that lies about their state.
            if case .done = cta {
                Text(ctaTitle)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Palette.accent.opacity(0.12))
                    .clipShape(Capsule())
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.fade, value: cta)
                    .padding(.top, 8)
                    .accessibilityLabel(Text(ctaTitle))
            } else {
            Button(action: ctaAction) {
                Text(ctaTitle)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contentTransition(.opacity)
                    .animation(Theme.Motion.fade, value: cta)
            }
            .padding(.top, 8)
            }

            // V0.68 — secondary "Withdraw more" CTA. Renders for casino
            // events in `.inPlay` so a member who has already withdrawn
            // into their working hand can still top up. One tap behind
            // the primary CTA, styled as an outline button. V0.70
            // animates the secondary CTAs in via the outer VStack's
            // fade animation when the optionals flip.
            if let onWithdrawMore {
                Button(action: onWithdrawMore) {
                    Text("Withdraw more")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
                .pressScale()
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel(Text("Withdraw more"))
            }

            // V0.66 — secondary "Count your CAH cards" CTA. Renders for
            // every active event when the room has the CAH pack installed,
            // so a casino night can still settle CAH cards. One tap behind
            // the primary CTA, styled as an outline button.
            if let onCAHSettle {
                Button(action: onCAHSettle) {
                    Text("Count your CAH cards")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
                .pressScale()
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityLabel(Text("Count your CAH cards"))
            }

            // P0.4 — host-only "Score a round" affordance. Renders
            // below the member-facing CTA so the host's at-play
            // surface carries both the chip-withdraw entry point
            // AND the round-recording control without crowding the
            // dominant action. Members see nothing here.
            if let onScore {
                Button(action: onScore) {
                    HStack {
                        Image(systemName: Theme.Icon.checkmarkSealFill)
                        Text("Score a round")
                    }
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))
                }
                .buttonStyle(.plain)
                .pressScale()
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
        .appearTransition()
        // V0.70 — drive the working-hand badge pop-in and the
        // secondary CTAs' fade-in from one place. Closures aren't
        // Equatable, so the secondary CTAs track the Bool of the
        // optional, not the closure itself.
        .animation(Theme.Motion.popIn, value: workingHand)
        .animation(Theme.Motion.fade, value: onWithdrawMore != nil)
        .animation(Theme.Motion.fade, value: onCAHSettle != nil)
    }

    /// V0.70 — title for the primary CTA. `.withdraw` reads
    /// "Withdraw to play"; `.scan` reads from the `scanTitle` the
    /// caller passed (pack-named: "Settle casino chips" or
    /// "Count your CAH cards").
    private var ctaTitle: String {
        switch cta {
        case .withdraw:    return "Withdraw to play"
        case .scan:        return scanTitle
        case .done(let t): return t
        }
    }

    /// V0.70 — action for the primary CTA. Routes to the
    /// member's withdraw or scan handler depending on the
    /// current state. `.done` has no action — the surface renders
    /// as a passive capsule, so this closure is never called.
    private var ctaAction: () -> Void {
        switch cta {
        case .withdraw: return onWithdraw
        case .scan:     return onScan
        case .done:     return {}
        }
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
    let chapterLine: ChapterLine?
    /// V0.84 C2 — Tonight's Star card for this event (host pick or
    /// chip-swing fallback). `nil` when no winner either way —
    /// the section is hidden in that case (matches the 067 empty
    /// case).
    let tonightStarCard: TonightStarCard?
    /// V0.84 C2 — host-only. Members of the room the host can pick
    /// from. Empty array means the host can't open the picker
    /// (the parent gates on `isHost && !members.isEmpty`).
    let hostPickMembers: [Member]
    let isHost: Bool
    /// V0.84 C5 — whether the next-morning drop window is open for
    /// this event. Per the locked spec the drop arrives the next
    /// morning with the recap, NOT on the post-session screen, so
    /// the prompt stays hidden during the 12h cool-down after
    /// settle. Combined with `memberNotePromptVisible` to decide
    /// whether the prompt renders.
    let memberNoteWindowOpen: Bool
    /// V0.84 C5 — whether the current member has already submitted
    /// or dismissed the one-line drop for this event. Drives
    /// whether the prompt renders below the star section (gated
    /// further by `memberNoteWindowOpen` — the drop only arrives
    /// the next morning, not the post-session screen).
    let memberNotePromptVisible: Bool
    /// V0.84 C2 + C5 — host-only actions for the picker.
    let onTonightStarPick: ((UUID, TonightStarOverrideCategory, String?) -> Void)?
    /// V0.84 C5 — member submit/skip for the one-line drop.
    let onSubmitMemberNote: ((String) -> Void)?
    let onSkipMemberNote: (() -> Void)?

    /// V0.84 C2 — local UI state for the inline picker. Empty
    /// string means "no member selected yet"; picker only
    /// submits when a member is selected.
    @State private var pickerSelectedMemberId: UUID?
    @State private var pickerSelectedCategory: TonightStarOverrideCategory = .bestPlay
    @State private var pickerCustomText: String = ""

    /// V0.84 C5 — local UI state for the one-line drop text field.
    @State private var memberNoteDraft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 64) {
            Text(chapterLine?.title ?? event.name)
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Palette.primaryText)

            if let settledAt = event.settledAt {
                Text("Settled \(settledAt, format: .relative(presentation: .named))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            if let teaser = chapterLine?.nextEpisodeTeaser, !teaser.isEmpty {
                HStack(spacing: 6) {
                    Text("↳ Next:")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text(teaser)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
            }

            // V0.84 C2 — Tonight's Star section. Hidden when
            // `tonightStarCard == nil` (no host pick AND no
            // chip-swing winner — matches the 067 empty case).
            if let card = tonightStarCard {
                TonightStarSection(card: card)
            }

            // V0.84 C5 — one-line drop prompt. Member-only, gated on
            // both `memberNoteWindowOpen` (the next-morning window
            // has opened, ≥12h since settle) AND
            // `memberNotePromptVisible` (the member hasn't already
            // submitted or dismissed it). Next-morning rule: the
            // drop arrives the next morning with the recap, NOT on
            // the post-session screen — the 12h cool-down gives
            // the member private space to reflect first.
            if !isHost, memberNoteWindowOpen, memberNotePromptVisible, let onSubmitMemberNote, let onSkipMemberNote {
                MemberNotePromptSection(
                    draft: $memberNoteDraft,
                    onSubmit: {
                        let text = memberNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        onSubmitMemberNote(text)
                        memberNoteDraft = ""
                    },
                    onSkip: {
                        onSkipMemberNote()
                        memberNoteDraft = ""
                    }
                )
            }

            // V0.84 C2 — host-only inline picker. Sits below the
            // member-visible star section. Gated on `isHost` AND a
            // non-nil `onTonightStarPick` callback (parents don't
            // wire the callback when the room has no members).
            if isHost, let onTonightStarPick, !hostPickMembers.isEmpty {
                HostTonightStarPickerSection(
                    members: hostPickMembers,
                    currentCard: tonightStarCard,
                    selectedMemberId: $pickerSelectedMemberId,
                    selectedCategory: $pickerSelectedCategory,
                    customText: $pickerCustomText,
                    onSave: {
                        guard let memberId = pickerSelectedMemberId else { return }
                        let category = pickerSelectedCategory
                        let text: String?
                        if category == .custom {
                            let trimmed = pickerCustomText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            text = trimmed
                        } else {
                            text = nil
                        }
                        onTonightStarPick(memberId, category, text)
                    }
                )
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
                Image(systemName: Theme.Icon.arrowDown)
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

// MARK: - Tonight's Star section (V0.84 C2)

/// V0.84 C2 — Tonight's Star read section on the ceremonial card.
/// Renders the winner (display name) + the category line (mascot
/// voice when the host picked a category; plain "the night's
/// biggest swing" when the chip-swing fallback is in play). The
/// `custom_text` from a `.custom` host pick is rendered alongside
/// (not inside) the mascot line, per the spec.
private struct TonightStarSection: View {
    let card: TonightStarCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Tonight's Star")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(card.memberDisplayName)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
            Text(categoryLine)
                .font(Theme.Typography.body.italic())
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            if let custom = card.customText, !custom.isEmpty {
                Text("“\(custom)”")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var categoryLine: String {
        if let category = card.overrideCategory {
            return category.mascotLine(winnerName: card.memberDisplayName)
        }
        return "The night's biggest swing."
    }
}

// MARK: - Member note prompt (V0.84 C5)

/// V0.84 C5 — the one-line drop. Italic mascot-styled prompt above
/// the text field, Send + Skip buttons (caption size). Send ⇒
/// `onSubmit` with the trimmed draft; Skip ⇒ `onSkip`. Local
/// state: "one tap to dismiss, no nagging, never returns until
/// next recap".
private struct MemberNotePromptSection: View {
    @Binding var draft: String
    let onSubmit: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anything you want the room to know next time?")
                .font(Theme.Typography.body.italic())
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            TextField(
                "",
                text: $draft,
                prompt: Text("One line for the host")
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            )
            .textFieldStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText)
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            HStack(spacing: 12) {
                Button(action: onSubmit) {
                    Text("Send")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(action: onSkip) {
                    Text("Skip")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Host Tonight's Star picker (V0.84 C2)

/// V0.84 C2 — host-only inline picker for Tonight's Star. Member
/// menu + category chips row + custom text field (visible only
/// when `.custom`, required) + Save. Mascot-styled header "The
/// host calls it — not a vote." lives in the body header line.
private struct HostTonightStarPickerSection: View {
    let members: [Member]
    let currentCard: TonightStarCard?
    @Binding var selectedMemberId: UUID?
    @Binding var selectedCategory: TonightStarOverrideCategory
    @Binding var customText: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The host calls it — not a vote.")
                .font(Theme.Typography.body.italic())
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            HStack(spacing: 8) {
                ForEach(TonightStarOverrideCategory.allCases, id: \.self) { cat in
                    Button(action: { selectedCategory = cat }) {
                        Text(cat.shortLabel)
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(
                                selectedCategory == cat
                                    ? Theme.Palette.background
                                    : Theme.Palette.primaryText.opacity(0.75)
                            )
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                selectedCategory == cat
                                    ? Theme.Palette.accent
                                    : Theme.Palette.surface
                            )
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            MemberMenuPicker(
                members: members,
                selection: $selectedMemberId
            )
            if selectedCategory == .custom {
                TextField(
                    "",
                    text: $customText,
                    prompt: Text("Custom line")
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                )
                .textFieldStyle(.plain)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText)
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            }
            Button(action: onSave) {
                Text("Save the call")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
        }
        .onAppear {
            if selectedMemberId == nil {
                selectedMemberId = currentCard?.memberId ?? members.first?.userId
            }
        }
    }

    private var canSave: Bool {
        guard selectedMemberId != nil else { return false }
        if selectedCategory == .custom {
            return !customText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

// MARK: - Member menu picker (V0.84 C2 host)

/// V0.84 C2 — host-only member picker. SwiftUI `Menu` driven by
/// the room's `Member` roster so the host can re-point Tonight's
/// Star at any room member, not just the chip-swing default.
private struct MemberMenuPicker: View {
    let members: [Member]
    @Binding var selection: UUID?

    var body: some View {
        Menu {
            ForEach(members, id: \.userId) { member in
                Button(member.displayName) { selection = member.userId }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currentLabel)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText)
                Image(systemName: Theme.Icon.chevronDown)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.Palette.hairline, lineWidth: 0.5))
        }
    }

    private var currentLabel: String {
        guard let selection,
              let member = members.first(where: { $0.userId == selection }) else {
            return "Pick a member"
        }
        return member.displayName
    }
}

// MARK: - Awards card (season-close slot, M1.1)

/// V0.53 — ShareLink requires a `Transferable` item; `UIImage` isn't
/// one. This wrapper exports the rendered stat card as PNG data.
private struct ShareableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
    }
}

/// The season-close awards card. Renders the season's award rows
/// (Phoenix / Veteran / Whale / Drowning) with the Drowning privacy
/// rules applied by the caller: the card receives only the rows it
/// may show, and the Drowning row is rendered through
/// `DrowningBadge` so the recipient sees an opt-in toggle and
/// opted-in viewers see a muted "you've opted in" footnote.
/// Non-drowning rows use the standard `AwardRow`.
private struct AwardsCard: View {
    let season: Season
    let awards: [SeasonAward]
    let currentUserId: UUID?
    let isHost: Bool
    let currentUserOptedIn: Bool
    /// V0.53 — the current user's shareable stat card, or `nil` when
    /// they have no season record. When present, a share action is
    /// offered on the card.
    let statCard: SeasonStatCard?
    let onToggleDrowningOptIn: (Bool) -> Void

    /// V0.53 — the rendered stat card PNG, produced lazily on first
    /// share. `ImageRenderer` is not exercised by the parse-only gate,
    /// so this is a manual-pass surface on an Xcode host.
    @State private var shareImage: UIImage?

    /// V0.70 — per-row appear state. The set holds the indices of
    /// rows that have already staggered in; each row reads its own
    /// membership to drive opacity/offset. Each row's `onAppear`
    /// sleeps `idx * 50ms` then inserts its own index inside a
    /// `withAnimation(Theme.Motion.fade)` (no `.delay` — the sleep
    /// already staggers), so rows cascade in independently and a
    /// late-appearing row doesn't short-circuit the cascade.
    @State private var appearedIndices: Set<Int> = []

    /// Stable display order: phoenix, veteran, whale, drowning,
    /// ironMann, comebackKid, goodSport. `AwardType.CaseIterable`
    /// defines the order; we sort by it.
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
                        awardView(for: award, at: idx)
                        if idx != sortedAwards.count - 1 {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            // V0.53 — share the member's own stat card. The card is
            // generated on the member's device and shared through the
            // system share sheet; the app never broadcasts it.
            if let statCard {
                let cardImage = renderImage(for: statCard)
                ShareLink(
                    item: ShareableImage(image: cardImage),
                    preview: SharePreview(
                        "\(statCard.memberName) — Season \(statCard.seasonOrdinal)",
                        image: Image(uiImage: cardImage)
                    )
                ) {
                    Label("Share my season card", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .padding(.top, 4)
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

    /// Renders the stat card to a PNG via `ImageRenderer`. Cached in
    /// `shareImage` so repeated shares don't re-render.
    private func renderImage(for card: SeasonStatCard) -> UIImage {
        if let shareImage { return shareImage }
        let renderer = ImageRenderer(
            content: SeasonStatCardView(card: card)
        )
        renderer.scale = 2.0
        let image = renderer.uiImage ?? UIImage()
        shareImage = image
        return image
    }

    @ViewBuilder
    private func awardView(for award: SeasonAward, at idx: Int) -> some View {
        Group {
            if award.awardType == .drowning {
                DrowningBadge(
                    award: award,
                    isRecipient: award.recipientUserId == currentUserId,
                    isOptedIn: currentUserOptedIn,
                    onToggleOptIn: onToggleDrowningOptIn
                )
            } else {
                AwardRow(award: award)
            }
        }
        // V0.70 — staggered fade-in. Subtle (opacity + 6pt offset,
        // no scale, no spring) per the V0.8 "table distance" rule.
        // Per-row state: each row reads its own membership in
        // `appearedIndices`, so the rows cascade independently and
        // row 0's onAppear can't flip a shared Bool that every row
        // reads.
        .opacity(appearedIndices.contains(idx) ? 1 : 0)
        .offset(y: appearedIndices.contains(idx) ? 0 : 6)
        .onAppear { staggerAppear(idx: idx) }
    }

    /// V0.70 — dispatches a staggered state flip for one row.
    /// Sleeps for `idx * 50ms`, then inserts `idx` into
    /// `appearedIndices` inside a `withAnimation(Theme.Motion.fade)`
    /// — no `.delay`, because the sleep already staggers the flip
    /// and stacking another delay would double-stagger. The
    /// `Task.isCancelled` guard short-circuits on view teardown.
    private func staggerAppear(idx: Int) {
        Task {
            try? await Task.sleep(for: .milliseconds(idx * 50))
            if !Task.isCancelled {
                withAnimation(Theme.Motion.fade) {
                    _ = appearedIndices.insert(idx)
                }
            }
        }
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
        case .phoenix:     return "flame.fill"
        case .veteran:     return "checkmark.seal.fill"
        case .whale:       return "circle.hexagongrid.fill"
        case .drowning:    return "drop.fill"
        case .ironMann:    return "figure.run"
        case .comebackKid: return "arrow.uturn.up.circle.fill"
        case .goodSport:   return "hand.thumbsup.fill"
        case .tonightStar: return "star.fill"
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
                        Image(systemName: Theme.Icon.xmark)
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

// MARK: - Host withdrawals section (V0.47)

/// Host-only list of pending chip withdrawals to physically
/// dispense. One row per `casino_withdrawal` transaction
/// (member name + absolute amount, since the RPC returns the
/// amount as a negative ledger entry) with a tap-to-dismiss
/// "Dispensed" acknowledgement. Local state only — the ledger
/// is never mutated by this surface.
private struct HostWithdrawalsSection: View {
    let withdrawals: [EventTransaction]
    let onDispense: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 8) {
                Image(systemName: Theme.Icon.circleHexagongridFill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Chips to dispense")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
            VStack(spacing: 0) {
                ForEach(withdrawals) { txn in
                    row(txn: txn)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Theme.Motion.fade, value: withdrawals.map(\.id))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(txn: EventTransaction) -> some View {
        HStack(spacing: Theme.Layout.cardInset) {
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.memberDisplayName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Withdrew chips")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer()
            Text("\(abs(txn.amountPoints)) pts")
                .font(Theme.Typography.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.accent)
            Button {
                Haptics.light()
                onDispense(txn.id)
            } label: {
                Text("Dispensed")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.Palette.accent)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dispensed \(txn.memberDisplayName)'s \(abs(txn.amountPoints)) points"))
        }
    }
}

// MARK: - Host openers section (V0.84 C1)

/// V0.84 C1 — host-only pre-loaded opening line per attending member.
/// Rendered directly under `activeSlot` (see `RoomDetailView.scrollBody`),
/// gated on `isHost` so the member never sees it. The body of each row
/// is mascot-framed by the view; `HostOpenerSuggestion.line` carries
/// the per-member body only. One row per CLAIMED RSVP; declined and
/// unclaimed members are excluded, but every claimed seat gets
/// exactly one opener (a stale-cache member falls back to a name-only
/// row via `HostOpenerDerivation.fallbackMember`).
private struct HostOpenersSection: View {
    let eventId: UUID
    let mascotName: String
    let members: [Member]
    let rsvps: [EventRSVP]
    let leaderboard: [LeaderboardEntry]
    let now: Date

    private var suggestions: [HostOpenerSuggestion] {
        HostOpenerDerivation.suggestions(
            eventId: eventId,
            members: members,
            rsvps: rsvps,
            leaderboard: leaderboard,
            now: now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 8) {
                Image(systemName: Theme.Icon.bubbleLeftAndBubbleRightFill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Openers for tonight")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
            if suggestions.isEmpty {
                Text("No one has claimed a seat yet.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, suggestion in
                        row(suggestion)
                        if idx != suggestions.count - 1 {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ suggestion: HostOpenerSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(mascotName) suggests:")
                .font(Theme.Typography.caption.weight(.semibold))
                .foregroundStyle(Theme.Palette.accent)
            Text(suggestion.line)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(mascotName) suggests for \(suggestion.displayName): \(suggestion.line)"))
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
                    // V0.34 — the leaderboard RPC ranks by
                    // `season_score`; `pointsBalance` is the casino
                    // wallet (seeded at 200, never touched by
                    // `round_score`) and shows 0 for CAH rooms.
                    // `seasonScore` is the season standings number
                    // and for CAH it IS total cards won.
                    score: Int(entry.seasonScore),
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

// MARK: - Round breakdown (F-MVP-05 V2-full, W1.6)

/// Per-round history for the active event, rendered under the
/// leaderboard. One row per `round_submissions` entry (migration
/// 035), read through `get_event_rounds` (migration 049). Each
/// round shows the pack, the round index, and the per-member
/// deltas the host submitted.
private struct RoundBreakdownSection: View {
    let rounds: [EventRound]
    let members: [Member]

    private var memberNameById: [UUID: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.displayName) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Round history")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)

            ForEach(rounds) { round in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Round \(round.roundIndex)")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text(round.packSlug.replacingOccurrences(of: "_", with: " "))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                    ForEach(round.entries, id: \.id) { entry in
                        HStack {
                            Text(memberNameById[entry.memberId] ?? "Member")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                            Spacer()
                            Text(deltaText(entry.pointsDelta))
                                .font(Theme.Typography.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(entry.pointsDelta >= 0
                                    ? Theme.Palette.accent
                                    : Theme.Palette.primaryText.opacity(0.6))
                        }
                    }
                }
                .padding(.vertical, 6)
                if round.id != rounds.last?.id {
                    Divider().overlay(Theme.Palette.hairline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func deltaText(_ delta: Int64) -> String {
        delta >= 0 ? "+\(delta)" : "\(delta)"
    }
}

// MARK: - Season history (W-05, US-10)

/// Previous-seasons comparison — the "improving over time" view.
/// Renders one row per ended season with the caller's total, the
/// delta vs the active season, and a sparkline of the caller's
/// intra-season arc. Member-visible read surface; hidden entirely
/// when the room has no ended seasons.
private struct SeasonHistorySection: View {
    let rows: [SeasonHistoryEntry]
    let currentScore: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Past seasons")
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("Your standing each season — how the current arc compares.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    seasonRow(row)
                    if idx != rows.count - 1 {
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

    private func seasonRow(_ row: SeasonHistoryEntry) -> some View {
        let d = row.delta(against: currentScore)
        let primaryText = row.subtitle.isEmpty ? dateRange(row) : row.subtitle
        let showCaption = !row.subtitle.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(primaryText)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showCaption {
                        Text(dateRange(row))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(row.callerTotal)")
                        .font(Theme.Typography.title.monospacedDigit())
                        .foregroundStyle(Theme.Palette.primaryText)
                    deltaCluster(d)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            if row.scoreProgression.count >= 2 {
                TrendSparkline(points: row.scoreProgression, color: trendColor(for: d))
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, Theme.Layout.cardInset)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            Text("\(primaryText), \(row.callerTotal) points, \(deltaLabel(d)) versus the current season")
        )
    }

    private func deltaCluster(_ d: Int64) -> some View {
        let color: Color = d > 0
            ? Theme.Palette.accent
            : (d < 0 ? Theme.Palette.primaryText.opacity(0.6) : Theme.Palette.primaryText.opacity(0.45))
        let arrow: String? = d == 0 ? nil : (d > 0 ? "arrow.up" : "arrow.down")
        return HStack(spacing: 3) {
            if let arrowName = arrow {
                Image(systemName: arrowName)
                    .font(Theme.Typography.footnote.weight(.semibold))
            }
            Text(deltaLabel(d))
                .font(Theme.Typography.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(color)
    }

    private func trendColor(for d: Int64) -> Color {
        d > 0
            ? Theme.Palette.accent
            : (d < 0 ? Theme.Palette.primaryText.opacity(0.6) : Theme.Palette.primaryText.opacity(0.45))
    }

    private func dateRange(_ row: SeasonHistoryEntry) -> String {
        if let ended = row.endedAt {
            return "\(row.startedAt.formatted(.dateTime.month().day().year())) – \(ended.formatted(.dateTime.month().day().year()))"
        }
        return row.startedAt.formatted(date: .abbreviated, time: .omitted)
    }

    private func deltaLabel(_ d: Int64) -> String {
        d >= 0 ? "+\(d)" : "\(d)"
    }
}

/// Hand-rolled polyline sparkline for `SeasonHistoryEntry.scoreProgression`.
/// No Swift Charts import — the codebase has zero Charts precedent and
/// the parse-check environment must keep working.
private struct TrendSparkline: View {
    let points: [SeasonScorePoint]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let totalMin = points.map(\.total).min() ?? 0
            let totalMax = points.map(\.total).max() ?? 0
            let range = totalMax - totalMin
            let denom = max(Double(points.count - 1), 1)
            let path = Path { p in
                for (i, point) in points.enumerated() {
                    let x = geo.size.width * (Double(i) / denom)
                    let normalized: Double
                    if range == 0 {
                        normalized = 0.5
                    } else {
                        normalized = Double(point.total - totalMin) / Double(range)
                    }
                    let y = geo.size.height * (1 - normalized)
                    if i == 0 {
                        p.move(to: CGPoint(x: x, y: y))
                    } else {
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            path
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Pack shelf (read-only on-page)

private struct PackShelfReadOnly: View {
    let room: Room
    @EnvironmentObject private var roomService: RoomService
    /// V0.35B — Casino chip-config sheet uses the same surface as
    /// Room Settings → Operations → Casino. Two ways to get there
    /// is fine (the spec decision).
    @EnvironmentObject private var casinoService: CasinoService

    /// 2026-08-10 feedback round — the pack the host tapped to edit
    /// its payout. nil = no editor presented.
    @State private var payoutPack: (any PackDefinition.Type)?

    /// V0.35B — the count-based pack the host tapped to edit its
    /// default points-per-card. nil = no editor presented.
    @State private var cahConfigPack: (any PackDefinition.Type)?

    /// V0.35B — drives presentation of the existing
    /// `RoomSettingsCasinoSheet` for `.withdrawReturn` packs.
    @State private var showingCasinoConfig: Bool = false

    /// The room's enabled packs from `PackRegistry.shared`, filtered
    /// by the room's installed set. An empty cache means the room
    /// has no explicit overrides — fall back to the default
    /// installed set (all four V0.8 packs), matching the Operations
    /// sub-sheet's convention.
    private var packs: [any PackDefinition.Type] {
        let enabled = roomService.cachedRoomPacks(roomId: room.id)
        if enabled.isEmpty {
            return PackRegistry.shared.allPacks
        }
        return PackRegistry.shared.allPacks.filter { enabled.contains($0.slug) }
    }

    private var isHost: Bool {
        room.userRole == .host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            VStack(spacing: 0) {
                ForEach(Array(packs.enumerated()), id: \.offset) { idx, pack in
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
        .sheet(item: Binding<AnyPackType?>(
            get: { payoutPack.map(AnyPackType.init) },
            set: { payoutPack = $0?.type }
        )) { wrapped in
            PackPayoutSheet(
                roomId: room.id,
                pack: wrapped.type,
                currentPoints: roomService.effectiveWinPoints(roomId: room.id, packSlug: wrapped.type.slug),
                onSave: { points in
                    try await savePayout(packSlug: wrapped.type.slug, points: points)
                }
            )
            .environmentObject(roomService)
        }
        .sheet(item: Binding<AnyPackType?>(
            get: { cahConfigPack.map(AnyPackType.init) },
            set: { cahConfigPack = $0?.type }
        )) { wrapped in
            CAHConfigSheet(
                roomId: room.id,
                pack: wrapped.type,
                currentPoints: roomService.effectiveWinPoints(roomId: room.id, packSlug: wrapped.type.slug),
                onSave: { points in
                    try await savePayout(packSlug: wrapped.type.slug, points: points)
                }
            )
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showingCasinoConfig) {
            // Reuse the existing RoomSettingsCasinoSheet verbatim.
            // The chip-color-map editor handles per-room overrides
            // for Casino's withdraw/return scoring.
            RoomSettingsCasinoSheet(roomId: room.id)
                .environmentObject(casinoService)
        }
    }

    private func packRow(_ pack: any PackDefinition.Type) -> some View {
        // 2026-08-10 feedback round — the pack row is now the
        // payout surface: hosts tap a pack to edit how much a win
        // pays out; members see the configured payout as a caption.
        // The row shows the pack's name + description + the
        // effective win points for single-winner packs.
        // V0.35B — the row now also surfaces the configured
        // points-per-card for `.countBased` packs (CAH), and the
        // tap handler routes each scoring type to its own editor.
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
                if pack.scoringType == .singleWinner || pack.scoringType == .countBased {
                    Text(payoutCaption(for: pack))
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if isHost {
                Image(systemName: Theme.Icon.sliderHorizontal3)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            }
        }
        .padding(.vertical, Theme.Layout.cardInset)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isHost else { return }
            // V0.35B — route each scoring type to its own config
            // surface. singleWinner keeps the payout sheet (V0.34
            // behaviour); withdrawReturn opens the Casino chip
            // sheet; countBased opens the CAH points-per-card
            // sheet.
            switch pack.scoringType {
            case .singleWinner:
                payoutPack = pack
            case .withdrawReturn:
                showingCasinoConfig = true
            case .countBased:
                cahConfigPack = pack
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(pack.displayName) — \(pack.description)"))
        .accessibilityHint(Text(accessibilityHint(for: pack)))
    }

    private func accessibilityHint(for pack: any PackDefinition.Type) -> String {
        guard isHost else { return "" }
        switch pack.scoringType {
        case .singleWinner:
            return "Tap to change how much a win pays out"
        case .countBased:
            return "Tap to change points per card"
        case .withdrawReturn:
            return "Tap to change chip values"
        }
    }

    private func payoutCaption(for pack: any PackDefinition.Type) -> String {
        let points = roomService.effectiveWinPoints(roomId: room.id, packSlug: pack.slug)
        switch pack.scoringType {
        case .countBased:
            return points == 1 ? "1 pt per card" : "\(points) pts per card"
        case .singleWinner, .withdrawReturn:
            return points == 1 ? "1 pt per win" : "\(points) pts per win"
        }
    }

    private func savePayout(packSlug: String, points: Int) async throws {
        try await roomService.setRoomPackConfig(roomId: room.id, packSlug: packSlug, winPoints: points)
    }
}

// MARK: - Pack payout sheet (2026-08-10 feedback round)

/// Host-only editor for one pack's per-room payout. A stepper over
/// the win points; saving routes through
/// `RoomService.setRoomPackConfig` (migration 047). Members never
/// see this sheet — the shelf only opens it for hosts.
private struct PackPayoutSheet: View {
    let roomId: UUID
    let pack: any PackDefinition.Type
    let currentPoints: Int
    let onSave: (Int) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var points: Int
    @State private var isSaving: Bool = false
    @State private var errorMessage: String = ""
    @State private var showError: Bool = false

    init(roomId: UUID, pack: any PackDefinition.Type, currentPoints: Int, onSave: @escaping (Int) async throws -> Void) {
        self.roomId = roomId
        self.pack = pack
        self.currentPoints = currentPoints
        self.onSave = onSave
        _points = State(initialValue: max(0, (currentPoints / 5) * 5))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("\(points) pts per win", value: $points, in: 0...1000, step: 5)
                } header: {
                    Text("Payout")
                } footer: {
                    Text("How many points a win pays out in this room. The default is \(PackRegistry.shared.winPoints(for: pack.slug)) pt(s); this overrides it for \(pack.displayName) only.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle(pack.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            do {
                                try await onSave(points)
                                Haptics.success()
                                dismiss()
                            } catch {
                                errorMessage = (error as NSError).localizedDescription
                                showError = true
                                isSaving = false
                            }
                        }
                    }
                    .tint(Theme.Palette.accent)
                    .disabled(isSaving)
                }
            }
            .alert("Couldn't save", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .tint(Theme.Palette.accent)
    }
}

// MARK: - CAH points-per-card sheet (V0.35B)

/// V0.35B — host-only editor for a `.countBased` pack's default
/// points-per-card (CAH). Mirrors `PackPayoutSheet`'s shape
/// (NavigationStack + Form + Cancel/Save toolbar). Saves through
/// `RoomService.setRoomPackConfig` (migration 047 path — same
/// `RoomPackConfig.winPoints` override used by single-winner packs;
/// in the count-based model 1 card = 1 point, so points-per-card IS
/// the default cards-won per round and seeds the host's per-round
/// "Cards won" stepper in `HostScoreEntrySheet`).
private struct CAHConfigSheet: View {
    let roomId: UUID
    let pack: any PackDefinition.Type
    let currentPoints: Int
    let onSave: (Int) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var points: Int
    @State private var isSaving: Bool = false
    @State private var errorMessage: String = ""
    @State private var showError: Bool = false

    init(roomId: UUID, pack: any PackDefinition.Type, currentPoints: Int, onSave: @escaping (Int) async throws -> Void) {
        self.roomId = roomId
        self.pack = pack
        self.currentPoints = currentPoints
        self.onSave = onSave
        // Floor at 1 — count-based packs need at least one card
        // per round for the stepper in HostScoreEntrySheet to be
        // meaningful (its range is 1...20).
        _points = State(initialValue: max(1, currentPoints))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper("\(points) pts per card", value: $points, in: 1...20, step: 1)
                } header: {
                    Text("Points per card")
                } footer: {
                    Text("The default points a won black card is worth in this room; the host can still adjust per round when scoring. The pack default is \(PackRegistry.shared.winPoints(for: pack.slug)).")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle(pack.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            isSaving = true
                            do {
                                try await onSave(points)
                                Haptics.success()
                                dismiss()
                            } catch {
                                errorMessage = (error as NSError).localizedDescription
                                showError = true
                                isSaving = false
                            }
                        }
                    }
                    .tint(Theme.Palette.accent)
                    .disabled(isSaving)
                }
            }
            .alert("Couldn't save", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
        .tint(Theme.Palette.accent)
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
    @EnvironmentObject private var authService: AuthService

    /// V0.55 — the freshly-minted invite code, shown for the host /
    /// member to share. `nil` until "Invite a friend" is tapped.
    @State private var inviteCode: String?
    /// V0.55 — the invitee picked for a tier-3 scoped code. `nil`
    /// until the member picks a co-member from their other rooms.
    @State private var inviteeUserId: UUID?
    /// V0.55 — transient error surface for the invite actions.
    @State private var inviteError: String?
    @State private var showInviteError: Bool = false
    /// V0.76 — the caller's invite rewards (friends joined + points
    /// earned). Loaded on appear; drives the reward banner.
    @State private var inviteRewards: InviteRewards?
    /// V0.76 — true once the reward banner has fired its success
    /// haptic, so the "paid off" moment lands exactly once.
    @State private var rewardHapticFired = false

    private var isHost: Bool {
        guard let uid = authService.currentUser?.id else { return false }
        return room.userRole == .host || room.createdBy == uid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            inviteSection
            let members = roomService.cachedMembers(roomId: room.id)
            if members.isEmpty {
                Text("No members yet — share your join code to get the table set.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
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
        .alert("Invite failed", isPresented: $showInviteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteError ?? "")
        }
        .task {
            // V0.76 — load the caller's invite rewards so the banner
            // can show when a friend's join has paid off. Best-effort;
            // a failure just leaves the banner hidden.
            if let rewards = try? await roomService.fetchMyInviteRewards(roomId: room.id) {
                inviteRewards = rewards
            }
        }
    }

    /// V0.55 — the invite affordance on the roster. Host sees
    /// "Invite a friend" (tier 1 host code) + the tier-2 approval
    /// queue (one-tap remove). Member sees "Invite a friend" (tier 2,
    /// quota-limited) + a tier-3 invitee-scoped code field.
    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            // V0.76 — reward banner. Shows when a friend has joined
            // via the caller's code and the +50 has landed. The
            // success haptic fires once (rewardHapticFired) so the
            // "paid off" moment is felt, not just seen.
            if let rewards = inviteRewards, rewards.friendsJoined > 0 {
                rewardBanner(rewards)
                    .onAppear {
                        if !rewardHapticFired {
                            Haptics.success()
                            rewardHapticFired = true
                        }
                    }
            }

            if let code = inviteCode {
                HStack(spacing: Theme.Layout.gutter) {
                    Text(code)
                        .font(Theme.Typography.body.monospaced().weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                    Spacer()
                    // V0.76 — native share sheet with a prefilled
                    // message, so inviting is one tap (not copy-paste).
                    ShareLink(
                        item: "Join me in Games Room — use code \(code) to get 200 pts to start!",
                        preview: SharePreview("Join me in Games Room")
                    ) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .accessibilityLabel(Text("Share invite code"))
                    Button {
                        UIPasteboard.general.string = code
                        Haptics.light()
                    } label: {
                        Image(systemName: Theme.Icon.plusCircle)
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .accessibilityLabel(Text("Copy invite code"))
                }
                .padding(.vertical, Theme.Layout.cardInset)
                .padding(.horizontal, Theme.Layout.edgePadding)
                .background(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if isHost {
                hostInviteRow
                tierTwoApprovalQueue
            } else {
                memberInviteRow
                tierThreeInviteField
            }
        }
    }

    /// V0.76 — the reward banner. A compact, celebratory card that
    /// shows how many friends joined via the caller's codes and the
    /// points earned. Uses the accent palette so it reads as a win,
    /// not a system notice.
    private func rewardBanner(_ rewards: InviteRewards) -> some View {
        HStack(spacing: Theme.Layout.gutter) {
            Image(systemName: Theme.Icon.person2Fill)
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Your invite paid off")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(rewards.friendsJoined == 1
                     ? "1 friend joined — +\(rewards.totalReward) pts"
                     : "\(rewards.friendsJoined) friends joined — +\(rewards.totalReward) pts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer()
        }
        .padding(.vertical, Theme.Layout.cardInset)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .background(Theme.Palette.accent.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.Palette.accent.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// V0.55 — host "Invite a friend" row. Generates a tier-1 host
    /// code.
    private var hostInviteRow: some View {
        Button {
            Task {
                do {
                    inviteCode = try await roomService.generateInviteCode(roomId: room.id, inviteeUserId: nil)
                } catch {
                    inviteError = error.localizedDescription
                    showInviteError = true
                }
            }
        } label: {
            HStack {
                Image(systemName: Theme.Icon.person2Fill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Invite a friend")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer()
            }
            .padding(.vertical, Theme.Layout.cardInset)
            .padding(.horizontal, Theme.Layout.edgePadding)
            .background(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// V0.55 — host tier-2 approval queue. Lists recent tier-2
    /// joins (from the roster where `inviteTier == 2`), each with a
    /// one-tap remove. Tier-2 joins are live immediately; this is the
    /// host's gate.
    @ViewBuilder
    private var tierTwoApprovalQueue: some View {
        let tierTwo = roomService.cachedMembers(roomId: room.id)
            .filter { $0.inviteTier == 2 }
        if !tierTwo.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pending invites")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                ForEach(tierTwo) { member in
                    HStack {
                        Text(member.displayName)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Button {
                            Task {
                                do {
                                    try await roomService.approveTierTwoJoin(roomId: room.id, userId: member.userId, remove: true)
                                } catch {
                                    inviteError = error.localizedDescription
                                    showInviteError = true
                                }
                            }
                        } label: {
                            Text("Remove")
                                .font(Theme.Typography.caption.weight(.semibold))
                                .foregroundStyle(Theme.Palette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, Theme.Layout.cardInset)
            .padding(.horizontal, Theme.Layout.edgePadding)
            .background(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// V0.55 — member "Invite a friend" row. Generates a tier-2
    /// member code (quota-limited per migration 007).
    private var memberInviteRow: some View {
        Button {
            Task {
                do {
                    inviteCode = try await roomService.generateInviteCode(roomId: room.id, inviteeUserId: nil)
                } catch {
                    inviteError = error.localizedDescription
                    showInviteError = true
                }
            }
        } label: {
            HStack {
                Image(systemName: Theme.Icon.person2Fill)
                    .foregroundStyle(Theme.Palette.accent)
                Text("Invite a friend")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Spacer()
            }
            .padding(.vertical, Theme.Layout.cardInset)
            .padding(.horizontal, Theme.Layout.edgePadding)
            .background(Theme.Palette.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    /// V0.55 — member tier-3 invitee-scoped code field. Picks a
    /// co-member from the caller's other rooms and scopes the code to
    /// that invitee. The invitee must be a member of one of the
    /// caller's other rooms (the invite-chain bridge).
    @ViewBuilder
    private var tierThreeInviteField: some View {
        let candidates = otherRoomMembers()
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
                Text("Send a code to someone in your other rooms")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Menu {
                    ForEach(candidates) { member in
                        Button(member.displayName) {
                            inviteeUserId = member.userId
                        }
                    }
                } label: {
                    HStack {
                        Text(inviteeName ?? "Choose a friend")
                            .font(Theme.Typography.body)
                            .foregroundStyle(inviteeUserId == nil ? Theme.Palette.primaryText.opacity(0.55) : Theme.Palette.primaryText)
                        Spacer()
                        Image(systemName: Theme.Icon.chevronDown)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                    }
                    .padding(.vertical, Theme.Layout.cardInset)
                    .padding(.horizontal, Theme.Layout.edgePadding)
                    .background(Theme.Palette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if let inviteeUserId {
                    Button {
                        Task {
                            do {
                                inviteCode = try await roomService.generateInviteCode(roomId: room.id, inviteeUserId: inviteeUserId)
                            } catch {
                                inviteError = error.localizedDescription
                                showInviteError = true
                            }
                        }
                    } label: {
                        Text("Generate scoped code")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// V0.55 — co-members of the caller's OTHER rooms (the invite-chain
    /// bridge). Deduped by user id; excludes the caller and members
    /// already in this room.
    private func otherRoomMembers() -> [Member] {
        guard let me = authService.currentUser?.id else { return [] }
        var seen = Set<UUID>()
        var result: [Member] = []
        for otherRoom in roomService.rooms where otherRoom.id != room.id {
            for member in roomService.cachedMembers(roomId: otherRoom.id) {
                guard member.userId != me, seen.insert(member.userId).inserted else { continue }
                result.append(member)
            }
        }
        return result
    }

    private var inviteeName: String? {
        guard let inviteeUserId else { return nil }
        return otherRoomMembers().first(where: { $0.userId == inviteeUserId })?.displayName
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

// MARK: - Collapsible section (V0.40)

private struct CollapsibleSection<Content: View>: View {
    let title: String
    let caption: String
    @State private var isExpanded: Bool = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(caption)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                    Spacer()
                    Image(systemName: isExpanded ? Theme.Icon.chevronUp : Theme.Icon.chevronDown)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(title))
            .accessibilityHint(Text(isExpanded ? "Tap to collapse." : "Tap to expand."))

            if isExpanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Mascot footer caption

private struct MascotFooterCaption: View {
    let room: Room
    let activeEvent: Event?
    let leaderboard: [LeaderboardEntry]
    let currentUserId: UUID?
    /// V0.48 — the member's withdrawn casino chips (working hand).
    /// Drives the `.inPlayWithWithdrawal` footer kind + `{working_hand}`.
    let withdrawnAmount: Int
    /// V0.48 — the room's current season. When `.ended`, the footer
    /// resolves `.seasonClose` (awards arc).
    let currentSeason: Season?
    @EnvironmentObject private var roomService: RoomService
    /// V0.81 — the LLM-resolved caption (when the bundle key is
    /// present). Starts `nil` so the synchronous template is shown
    /// immediately; the LLM result swaps in when the async task
    /// lands, and any failure keeps the template visible. The
    /// template is the safe default per V0.26 fallback semantics —
    /// `MascotEngine.generateVoiceLLM` returns the template string
    /// verbatim on missing key / bad endpoint / timeout / empty
    /// body, so this is also what happens if `generateVoiceLLM`
    /// itself decides to fall back.
    @State private var llmCaption: String?
    /// Room-state-aware caption (V0.36). `footerKind` resolves one of
    /// the twelve `NotificationKind` flavours from the room's active
    /// event + leaderboard + working hand + season; `RoomContext`
    /// carries recent winners, leader name, caller rank, event count,
    /// days quiet, working hand, last-winner delta, and season days
    /// left. The 25-voice matrix still flavours the body, so the
    /// mascot's personality × ideology stays in charge. Tap opens the
    /// deep-dive bubble. See `MascotEngine.generateVoice(...)` for
    /// the placeholder contract — nil optional placeholders are
    /// silently dropped at the sentence boundary.
    ///
    /// M2.3 — pass real memberCount + memberNames from the cached
    /// roster so the room-template tokens don't substitute "0
    /// members". Members are loaded by `RoomDetailView.task`; this
    /// view reads from the service's published cache so the caption
    /// updates without a manual refresh.
    private var members: [Member] {
        roomService.cachedMembers(roomId: room.id)
    }
    private var memberNameById: [UUID: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.displayName) })
    }
    /// Days since any member last played a session in this room.
    /// `nil` when no leaderboard row has a `lastSessionAt` —
    /// `recentWinnerNames` and other placeholders stay substitutable.
    private var daysSinceLastPlay: Int? {
        guard let last = leaderboard.compactMap(\.lastSessionAt).max() else {
            return nil
        }
        return Int(Date().timeIntervalSince(last) / 86_400)
    }
    /// The resolved `NotificationKind` for the current state. Pure;
    /// recomputed when the view re-renders.
    private var footerKind: MascotEngine.NotificationKind {
        MascotEngine.footerKind(
            activeEvent: activeEvent,
            leaderboard: leaderboard,
            withdrawnAmount: withdrawnAmount,
            currentSeason: currentSeason
        )
    }
    /// The fully-populated `RoomContext` for the LLM prompt path
    /// AND the template path. Pure; recomputed when the view
    /// re-renders. The footer caption's view-of-the-world.
    private var roomContext: MascotEngine.RoomContext {
        .init(
            activeEventTitle: activeEvent?.name,
            lastEventDaysAgo: daysSinceLastPlay,
            memberCount: members.count,
            memberNames: members.map(\.displayName),
            recentWinnerNames: MascotEngine.recentWinners(
                rounds: roomService.cachedEventRounds(
                    eventId: activeEvent?.id ?? UUID()
                ),
                memberNameById: memberNameById
            ),
            leaderName: MascotEngine.leaderName(leaderboard: leaderboard),
            callerRank: MascotEngine.callerRank(
                leaderboard: leaderboard,
                currentUserId: currentUserId
            ),
            eventCount: leaderboard
                .map(\.sessionsPlayed)
                .max()
                .map { Int($0) },
            withdrawnAmount: withdrawnAmount > 0 ? withdrawnAmount : nil,
            lastWinnerDelta: MascotEngine.lastWinnerDelta(
                rounds: roomService.cachedEventRounds(
                    eventId: activeEvent?.id ?? UUID()
                )
            ),
            seasonDaysLeft: nil
        )
    }
    /// The synchronous template body — shown instantly on every state
    /// change so the room page bottom never blanks. The 25-voice
    /// matrix + RoomContext drive this, identical to the V0.36
    /// pre-LLM behaviour.
    private var templateCaption: String {
        MascotEngine.generateVoice(
            mascotName: room.mascotName,
            roomName: room.name,
            personality: room.mascotPersonality,
            ideology: room.mascotPoliticalIdeology,
            kind: footerKind,
            context: roomContext
        )
    }
    /// What the View actually renders. LLM wins when present,
    /// template when the LLM hasn't landed (or fell back). When the
    /// underlying state changes, `.task(id:)` clears `llmCaption`
    /// and re-fires — so the cross-fade between two LLM lines also
    /// shows the template in the gap, never a blank frame.
    private var caption: String {
        llmCaption ?? templateCaption
    }
    /// V0.81 — fires the edge-function call once per (footer-kind,
    /// members, leaderboard, withdrawn) snapshot. When the caller
    /// has no session, the call short-circuits to the template and
    /// `llmCaption` stays nil — template forever, zero network cost.
    /// When the call succeeds and the body is different from the
    /// template, `llmCaption` swaps in; any failure (non-200,
    /// decode error, timeout) leaves `llmCaption` nil and the
    /// template stays visible.
    private func refreshLLMCaption() async {
        let authToken = await SupabaseClientProvider.currentSession()?.accessToken
        // No session ⇒ template only, no network call.
        guard let authToken, !authToken.isEmpty else {
            llmCaption = nil
            return
        }
        let result = await MascotEngine.generateVoiceLLM(
            mascotName: room.mascotName,
            roomName: room.name,
            personality: room.mascotPersonality,
            ideology: room.mascotPoliticalIdeology,
            kind: footerKind,
            context: roomContext,
            authToken: authToken,
            roomId: room.id,
            eventId: activeEvent?.id
        )
        // `generateVoiceLLM` returns the template verbatim on every
        // failure path — so an unchanged result is either the API
        // actually echoed the template, or the engine fell back.
        // Either way the visible body is identical to the template;
        // skip the swap so we don't pay the cross-fade cost for no
        // visual change. The template path's sentinel-fallback
        // (missing key) is handled by the guard above, so this only
        // elides genuine no-ops, never a real LLM response.
        llmCaption = MascotEngine.chooseLLMCaption(
            llmResult: result,
            template: templateCaption
        )
    }
    var body: some View {
        Text(caption)
            .font(Theme.Typography.caption.italic())
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
            // 2026-08-10 feedback round — the caption was cut off at
            // one line. The mascot comment is the room's voice; let
            // it wrap so the whole comment is readable.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Layout.sectionSpacing)
            // V0.70 — the mascot "speaks" when its caption changes.
            // `.id(caption)` forces SwiftUI to treat each new line
            // as a different view so the transition fires; the
            // attached fade animation drives the cross-fade.
            .id(caption)
            .transition(.opacity.combined(with: .offset(y: 4)))
            .animation(Theme.Motion.fade, value: caption)
            // V0.81 — kick the LLM task whenever the snapshot the
            // caption depends on changes. The id collapses to the
            // same string for a given (kind, members, leaderboard,
            // withdrawn) tuple, so SwiftUI only re-fires the task
            // when something actually shifts — not on every parent
            // re-render. Resetting `llmCaption` to nil first means
            // the template re-appears during the in-flight gap, so
            // the View is never blank between two LLM lines.
            .task(id: footerTaskKey) {
                llmCaption = nil
                await refreshLLMCaption()
            }
    }
    /// Stable id that changes only when the inputs the LLM call
    /// depends on change. Used to gate `.task(id:)` so SwiftUI
    /// cancels + restarts the LLM call exactly when the footer
    /// state genuinely shifts.
    ///
    /// V0.81 — personality + ideology are part of the key. The
    /// mascot's voice IS the caption; when the host changes the
    /// room's personality/politics in settings and saves, the
    /// cached `llmCaption` must be discarded and re-generated in
    /// the new voice. Without them the task id is unchanged after
    /// a voice edit, `.task(id:)` never re-fires, and the footer
    /// keeps narrating in the OLD voice.
    private var footerTaskKey: String {
        "\(footerKind.rawValue)|\(room.mascotPersonality.rawValue)|\(room.mascotPoliticalIdeology.rawValue)|\(members.count)|\(leaderboard.count)|\(withdrawnAmount)|\(room.id)"
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
    /// V0.9 Wave 2 Slice 2.2 - inline create-room row. The parent
    /// supplies this so the create surface can be a sheet owned
    /// by `RoomDetailView` (matching the Rooms-tab pattern).
    let onCreateRoom: () -> Void

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
                            Image(systemName: Theme.Icon.checkmark)
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
                    // V0.9 Wave 2 Slice 2.2 - inline create-room row.
                    // Tapping opens the same CreateRoomSheet the
                    // Rooms tab's "+" opens. The hint that pointed
                    // at the Rooms tab is gone.
                    Button(action: onCreateRoom) {
                        Label("Create new room", systemImage: Theme.Icon.plusCircleFill)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentRoom.name)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .lineLimit(1)
                Image(systemName: Theme.Icon.chevronDown)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .accessibilityLabel(Text("Switch room — currently \(currentRoom.name)"))
        }
    }
}

// MARK: - Micro-interaction modifiers (V0.42)
//
// Three small `ViewModifier` helpers shared across the room detail
// page. Kept private and file-scoped because the room detail page is
// the only consumer — `Theme.swift` owns view-agnostic styling; these
// are page-specific motion helpers.

// MARK: Appear transition

private struct AppearModifier: ViewModifier {
    @State private var appeared = false
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared ? 1 : 0.97)
            .onAppear {
                withAnimation(.easeOut(duration: 0.25)) {
                    appeared = true
                }
            }
    }
}

extension View {
    /// Fade + slight scale on first appear. Fast and subtle — the
    /// card settles into place rather than popping.
    func appearTransition() -> some View {
        modifier(AppearModifier())
    }
}

// MARK: Press scale

private struct PressScaleModifier: ViewModifier {
    @State private var isPressed = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

extension View {
    /// Scales the button down slightly while pressed, back up on
    /// release. Gives tactile press feedback without a custom
    /// button style.
    func pressScale() -> some View {
        modifier(PressScaleModifier())
    }
}