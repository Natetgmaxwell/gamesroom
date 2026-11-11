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
    /// v1.2.2 S6 T6 — the Question Box driver runs from this page
    /// (see the `.task` on `body`), so the page reads the same turn
    /// cache the section prints from.
    @EnvironmentObject private var questionBox: QuestionBoxService
    /// W-04 — pops this pushed detail view when the host deletes the
    /// room from settings (the room is gone from the rooms list, so
    /// staying on the page would strand the user on a dead room).
    @Environment(\.dismiss) private var dismiss
    /// iPad host scoring dashboard gate — `.regular` width only. Gated
    /// here (not on UIDevice) so iPad multitasking split-screen stays
    /// on the phone-shaped scroll path.
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// P2 (audit 03 C1) — the one sheet this page is showing. Every
    /// call site that used to set a Bool or a payload optional sets a
    /// `RoomPresentation` case instead, so two sheets can never be
    /// asked of one node. The page therefore has exactly two
    /// presentation bindings: this one and `roomConfirm`.
    @State private var presenting: RoomPresentation?
    /// The page's one `confirmationDialog` ("Sam hasn't cashed out.
    /// Settle the night anyway?"). A dialog cannot be presented from
    /// inside a sheet, so it keeps its own slot — as an enum.
    @State private var roomConfirm: RoomConfirm?
    /// V0.79 — flips when the one-time notif prompt is answered so
    /// SwiftUI re-renders the card away (UserDefaults isn't observed).
    @State private var notifPromptDismissed: Bool = false
    /// Lane S2: the post-claim reminder ask was tapped this session.
    @State private var claimReminderAskTapped: Bool = false
    @State private var packsExpanded = false
    // V0.84 C5 — flips when the one-line drop is dismissed locally
    // so SwiftUI re-renders the prompt away (UserDefaults isn't
    // observed directly). The underlying dismissal flag is stored
    // under `StorageKeys.memberNotePromptDismissed(eventId:)`.
    @State private var memberNotePromptDismissedFlip: Bool = false

    // P2 — the take-chips / cash-out sheets are cases on
    // `presenting`. Each was a separate `@State` before; the payload
    // (the event) is captured at sheet-present time so the sheets don't
    // drift if the user pulls-to-refresh while the sheet is open.
    @State private var casinoWithdrawn: Int = 0
    // The live night's transactions (`get_event_transactions`), for
    // everyone: the cash-out rows are tonight's scores, and the host
    // reads the withdrawals to hand out physical chips (V0.47; the
    // dispensed stamp is server-persisted since V0.73).
    @State private var eventTransactions: [EventTransaction] = []
    // V0.51 — per-member working hands for the active casino event.
    // Host sees working hand + bank balance; members see working hand only.
    @State private var workingHands: [WorkingHand] = []
    /// S1.5 — the settle with Undo, and the window that will send it.
    @State private var settle: SettlePhase = .idle
    @State private var settleTask: Task<Void, Never>?
    /// 1.2.5 — "Same time next Tuesday?": the one-tap booking with
    /// Undo, and the window that will send it.
    @State private var booking: NextNightBooking = .idle
    @State private var bookingTask: Task<Void, Never>?
    /// 1.2.5 — the cash-out results of the night recapped ABOVE the
    /// next night's card. The page's chip reads follow the active
    /// night, so once the next night is booked the recap reads its
    /// own night's rows here. Keyed by the recapped night.
    @State private var recapChips: (eventId: UUID, hands: [WorkingHand], transactions: [EventTransaction])?
    /// S1.7 — flips when the awards are dismissed so SwiftUI
    /// re-renders (UserDefaults isn't observed).
    @State private var seasonAwardsDismissedFlip: Bool = false

    // B1.3 — host-only "+ Add an event" CTA in the in-room
    // toolbar. Presented as `.addEvent(seed: nil)` on this page.
    // v1.1 — the season the host just closed from Room settings.
    /// `close_season` opens the next season straight away, so without
    /// this the page would skip the awards card; holding the closed
    /// season lands the host on it until a new night is scheduled.
    @State private var justClosedSeason: Season?

    /// Seat-action error surface. `claimSeat` / `declineSeat` /
    /// `releaseSeat` set `seatActionError` + flip
    /// `showSeatActionError` on failure; the body's `.alert`
    /// presents the message. Driven at the view layer so the
    /// service's `lastError` keeps its existing role and isn't
    /// reshaped by this loop.
    @State private var seatActionError: String?
    @State private var showSeatActionError: Bool = false

    /// S3.3 — the release toast. Holds the event whose seat was
    /// released so "Undo" can put it back. Five seconds, then it
    /// goes.
    @State private var seatReleaseToast: SeatReleaseToast?

    /// C3 (audit 02) — what the last seat action actually did, for the
    /// actions whose server answer is a bare `true` either way. A quiet
    /// one-line toast; no modal, no haptic on a no-op.
    @State private var seatOutcome: SeatOutcomeToast?

    /// S3.6 / P2 (audit 03 C6) — the join code the empty-room invite
    /// shares, as one phase instead of three flags. There is no read RPC
    /// for the live code (only `generate_join_code`), so it is minted on
    /// demand when the host opens a room with nobody in it, and kept for
    /// as long as the hero is up. A retry clears the old error at mint
    /// start rather than at success.
    @State private var inviteCode: InviteCodePhase = .idle

    private var isHost: Bool {
        guard let uid = authService.currentUser?.id else { return false }
        return room.userRole == .host || room.createdBy == uid
    }

    /// S3.6 — true when the room needs friends before it needs a
    /// night: the host is alone (fewer than two members) and the
    /// roster has actually loaded.
    ///
    /// The roster gate matters. Until the roster lands we do not
    /// know the room is empty, so the old CTA stays and a room with
    /// a full table never flashes the invite.
    private var inviteFirst: Bool {
        isHost
            && roomService.hasLoadedMembers(roomId: room.id)
            && roomService.cachedMembers(roomId: room.id).count < 2
    }

    /// S3.6 — the task key for the invite-code mint. It changes when
    /// the room changes and when the hero starts asking for an
    /// invite, which is when a code is worth minting.
    private var inviteHeroTaskKey: String {
        "\(room.id.uuidString)-\(inviteFirst)"
    }

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

    /// Who is hosting, by name: "you" for the host themself. A night
    /// is somebody's invitation, and the page says whose. nil until
    /// the roster has loaded.
    private var hostedByLine: String? {
        if isHost { return "you" }
        return roomService.cachedMembers(roomId: room.id)
            .first(where: { $0.userId == room.createdBy })?
            .displayName
    }

    /// V0.106 — the active event while it is live. Question turns only
    /// exist inside this window, and the window now ends at
    /// `played_at + auto_close_hours`, the same place the server stops
    /// them (audit 01 D14).
    private var questionBoxLiveEvent: Event? {
        guard let event = activeEvent, nightPhase(for: event) == .live else { return nil }
        return event
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

    private var leaderboard: [LeaderboardEntry] {
        roomService.cachedLeaderboard(roomId: room.id)
    }

    /// V0.47 — withdrawals still awaiting physical chip dispensing.
    /// V0.73 — the dispensed filter is now server-persisted
    /// (`meta.dispensed`, stamped by `mark_withdrawal_dispensed`,
    /// migration 073) instead of a local `@State` set that forgot
    /// every acknowledgement on relaunch.
    ///
    /// Only chips someone may still be waiting on: never the host's own
    /// (nobody hands chips to themself), and never a player who has
    /// already cashed out (they had the chips in hand to scan).
    private var pendingWithdrawals: [EventTransaction] {
        guard isHost else { return [] }
        let cashedOut = Set(workingHands.filter(\.isCashedOut).map(\.memberId))
        return eventTransactions.filter {
            $0.kind == "casino_withdrawal"
                && !$0.isDispensed
                && $0.memberId != currentUserId
                && !cashedOut.contains($0.memberId)
        }
    }

    /// A night is being played right now. While it is, the page is
    /// about the game: one-time asks (notifications) wait until after.
    private var isNightLive: Bool {
        guard let event = activeEvent else { return false }
        return nightPhase(for: event) == .live
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
        scrollBody
        .background(Theme.Palette.background.ignoresSafeArea())
        // S3.3 — the release toast. One line of quiet text and one
        // plain-text action, parked at the bottom of the page for
        // five seconds. The Undo window is the point: releasing a
        // seat is instant and reversible.
        .overlay(alignment: .bottom) {
            if let toast = seatReleaseToast {
                SeatReleaseToastView {
                    undoRelease(toast)
                }
                .padding(.horizontal, Theme.Layout.edgePadding)
                // The floating tab bar's glass capsule tops out
                // ~83pt from the screen bottom; the toast clears it.
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    try? await Task.sleep(for: .seconds(5))
                    guard seatReleaseToast?.id == toast.id else { return }
                    withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                        seatReleaseToast = nil
                    }
                }
            }
            if let outcome = seatOutcome {
                SeatOutcomeToastView(message: outcome.message)
                    .padding(.horizontal, Theme.Layout.edgePadding)
                    .padding(.bottom, 96)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: outcome.id) {
                        try? await Task.sleep(for: .seconds(4))
                        guard seatOutcome?.id == outcome.id else { return }
                        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                            seatOutcome = nil
                        }
                    }
            }
        }
        // v1.2.2 S6 T6 — the one Question Box driver for this page,
        // started above the section it feeds (the section only
        // renders once a turn exists, so it can no longer be the
        // thing that starts the polling loop). Covers both surfaces
        // below: the scroll page and the host scoring dashboard,
        // which used to start their own driver each.
        .task(id: questionBoxLiveEvent?.id) {
            guard let event = questionBoxLiveEvent else { return }
            await questionBox.driveLiveEvent(eventId: event.id)
        }
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
            // V0.103 — compact-width only. On iPad (regular width)
            // the sidebar is the one true room navigator; this
            // dropdown duplicated it (Nathan's V1.0 UX review,
            // 2026-09-24). iPhone has no sidebar, so it stays.
            if !allRooms.isEmpty && hSize == .compact {
                ToolbarItem(placement: .topBarLeading) {
                    RoomSwitcherMenu(
                        currentRoom: room,
                        allRooms: allRooms,
                        activeEventByRoom: roomService.activeEventByRoom,
                        onSwitchRoom: onSwitchRoom,
                        onCreateRoom: { presenting = .createRoom }
                    )
                }
            }
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presenting = .addEvent(seed: nil)
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
            // V0.103 — compact-width only. On iPad (regular width)
            // this duplicated the RoomPage toolbar gear for the same
            // RoomSettingsSheet; the RoomPage gear is the survivor
            // and must stay member-visible so members keep a path
            // to notification prefs.
            if hSize == .compact {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presenting = .settings(liveRoom)
                    } label: {
                        Image(systemName: Theme.Icon.gearshape)
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    .accessibilityLabel(Text("Room settings"))
                    .accessibilityHint(Text("Opens settings for \(room.name)"))
                }
            }
        }
        // P2 (audit 03 C1) — ONE sheet for the whole page. Each case
        // carries its own payload, so presenting a second case replaces
        // the first instead of stacking a second presenter on this node.
        .sheet(item: $presenting) { item in
            presentation(for: item)
        }
        .task {
            await refresh()
        }
        // S3.6 — the empty-room invite needs a join code. The key
        // flips once the roster lands and the host turns out to be
        // alone, which is when minting one is worth a round trip.
        .task(id: inviteHeroTaskKey) {
            await mintHeroJoinCode()
        }
        .refreshable {
            await refresh(force: true)
            Haptics.light()
        }
        // Settling while someone still has chips on the table is the
        // one move that can strand their night, so it asks first and
        // names them.
        .confirmationDialog(
            "Settle the night?",
            isPresented: Binding(
                get: { roomConfirm != nil },
                set: { if !$0 { roomConfirm = nil } }
            ),
            titleVisibility: .visible,
            presenting: roomConfirm
        ) { choice in
            switch choice {
            case .settleEarly(let event, _):
                Button("Settle anyway", role: .destructive) { settleNight(event: event) }
                // Not `.cancel`: iOS 26 hides a cancel-role button in a
                // dialog (tap outside instead). The way back is a button
                // you can see.
                Button("Keep playing") {}
            }
        } message: { choice in
            switch choice {
            case .settleEarly(_, let names):
                Text(NightPlan.settleEarlyWarning(names: names))
            }
        }
        // S1.5 — "Night settled." with Undo, for the 5 s before the
        // settle is sent. P2: the same toast stays up while the settle
        // RPC is in flight; Undo is only offered while nothing has been
        // sent (`SettlePhase.showsToast` / `.undoingEvent`).
        .overlay(alignment: .bottom) {
            if settle.showsToast {
                HStack(spacing: Theme.Layout.cardLineGap) {
                    Text("Night settled.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Spacer()
                    if let undoEvent = settle.undoingEvent {
                        Button("Undo") { undoSettle(undoEvent) }
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .accessibilityHint(Text("Puts the night back live"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline, lineWidth: 1))
                )
                .padding(.horizontal, Theme.Layout.edgePadding)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.fade, value: settle.showsToast)
        // 1.2.5 — "Next night booked." with Undo for the 5 s before
        // the night is created; it stays up while the create is in
        // flight. Never at the same time as the settle toast: the
        // booking is only offered once the settle has gone through.
        .overlay(alignment: .bottom) {
            if booking.showsToast {
                HStack(spacing: Theme.Layout.cardLineGap) {
                    Text(NextNightBooking.toastLine)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Spacer()
                    if booking.undoingOffer != nil {
                        Button("Undo") { undoBooking() }
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .accessibilityHint(Text("Takes the next night back off the books"))
                            .accessibilityIdentifier("next-night-undo")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.Palette.surface)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.hairline, lineWidth: 1))
                )
                .padding(.horizontal, Theme.Layout.edgePadding)
                .padding(.bottom, 96)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.fade, value: booking.showsToast)
        .alert("Seat action failed", isPresented: $showSeatActionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(seatActionError ?? "")
        }
    }

    // MARK: - The page's one sheet (P2, audit 03 C1)

    /// Builds the sheet for a `RoomPresentation` case. This is the only
    /// sheet body on the page; the case carries everything the sheet
    /// needs, so the view never has to look at a second flag.
    @ViewBuilder
    private func presentation(for item: RoomPresentation) -> some View {
        switch item {
        case .settings(let presented):
            RoomSettingsSheet(room: presented, onRoomDeleted: {
                // W-04 — pop back to the rooms list; the deleted
                // room is already gone from the service cache.
                dismiss()
            }, onSeasonClosed: { closed in
                Task {
                    await roomService.loadSeasonAwards(seasonId: closed.id, force: true)
                    withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                        justClosedSeason = closed
                    }
                }
            })
            .environmentObject(roomService)
            .environmentObject(casinoService)

        case .editEvent(let event):
            EditEventSheet(event: event)
                .environmentObject(roomService)

        case .addEvent(let seed, let packs):
            AddEventSheet(
                roomId: room.id,
                initialPlayedAt: seed,
                initialPackSlugs: packs,
                onSaved: { _ in
                    presenting = nil
                    justClosedSeason = nil
                    Task { await refresh(force: true) }
                }
            )
            .environmentObject(roomService)

        case .withdraw(let event):
            WithdrawChipsSheet(
                eventId: event.id,
                roomId: room.id,
                cachedBalance: leaderboard
                    .first(where: { $0.userId == currentUserId })
                    .map { Int($0.pointsBalance) },
                onDone: { Task { await refresh(force: true) } }
            )
            .environmentObject(casinoService)
            .environmentObject(authService)

        case .settleScan(let event):
            // V0.50 — vision-first cash-out. Hosts AND members land
            // here from "Cash out: scan your chips", the same surface
            // for everyone. The
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

        case .createRoom:
            // V0.9 Wave 2 Slice 2.2 - inline "+" create-room sheet. Same
            // surface as the Rooms-tab "+" (CreateRoomSheet, owned here
            // so it dismisses cleanly when the user backs out of the
            // menu without a confirmed create).
            CreateRoomSheet()
                .environmentObject(roomService)
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.roomSectionGap) {
                // S1.7 — the season that just closed, for every
                // member, for 7 days or until they tap Done. Its own
                // section: the next night's card stays under it.
                if let season = seasonToCelebrate {
                    let awards = awardsForPrivacy(seasonId: season.id)
                    VStack(spacing: Theme.Layout.cardGroupGap) {
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
                        Button { dismissSeasonAwards(season) } label: {
                            Text("Done")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Done"))
                    }
                    .frame(maxWidth: .infinity)
                }
                // S1.7 (TARS) — the night just settled, while the next
                // night is already on the books: the recap sits above
                // the next night's card for 24h after the settle.
                if let recap = recapAboveNextNight {
                    recapCard(event: recap)
                        .frame(maxWidth: .infinity)
                }
                activeSlot
                    .frame(maxWidth: .infinity)
                // v1.2.2 S6 T5 — the host's unread notes, lifted out
                // of the event card and placed directly after it as
                // their own room-page section. The card is the only
                // box at the top of this page; notes that blur where
                // the event ends were the other half of that blur.
                // The gap above and below comes from the page
                // stack's `roomSectionGap`, the same as every other
                // section here.
                if !unconsumedMemberNotes.isEmpty {
                    UnconsumedMemberNotesSection(
                        room: liveRoom,
                        notes: unconsumedMemberNotes,
                        onDone: { ids in
                            Task { await markMemberNotesConsumed(roomId: room.id, noteIds: ids) }
                        }
                    )
                }
                // V0.106 — Question Box live driver + host fallback.
                // v1.2.2 S6 T6 — added only when there is something
                // to print. It used to be added for every live event,
                // and with no turn yet it renders a zero-height
                // container that still takes a `roomSectionGap` above
                // AND below it: the live card sat 64pt from
                // Standings where every other pair of sections gets
                // 32. The gap between two sections now comes from
                // `roomSectionGap` and nothing else. The driver moved
                // up to `body` (one driver per page).
                if let event = questionBoxLiveEvent,
                   QuestionBoxLiveSection.hasContent(
                       event: event, isHost: isHost, turns: questionBox.turnByEvent
                   ) {
                    QuestionBoxLiveSection(event: event, isHost: isHost)
                }
                // V0.66 — host-only "Chips to dispense" cards during active
                // casino play when withdrawals await dispensing.
                if isNightLive, !pendingWithdrawals.isEmpty {
                    HostWithdrawalsSection(
                        withdrawals: pendingWithdrawals,
                        onDispense: { id in
                            Task {
                                _ = await casinoService.markWithdrawalDispensed(transactionId: id)
                                await loadEventTransactionsIfNeeded()
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
                // covered. The host decides per candidate; the
                // system never decides alone.
                //
                // S3.7 — the card waits for the grace window. While
                // the window is open the host gets one grey line
                // ("Arrivals open at 7:40pm") and no rows: a member
                // who is two minutes late is parking, not a no-show.
                // Inside the window each row offers a grey "Give it
                // back" and a red "Keep" behind a confirmation.
                if let event = activeEvent,
                   isHost,
                   nightPhase(for: event) == .live,
                   liveRoom.depositMode.isEscrow {
                    let candidates = roomService.cachedArrivalCandidates(eventId: event.id)
                    if !candidates.isEmpty {
                        if ArrivalGrace.isOpen(
                            candidates: candidates,
                            playedAt: event.playedAt,
                            graceMinutes: liveRoom.seatDepositGraceMinutes
                        ) {
                            ArrivalCard(
                                room: liveRoom,
                                event: event,
                                candidates: candidates,
                                onGiveBack: { candidate in
                                    Task { await resolveArrivalCandidate(candidate, forfeit: false) }
                                },
                                onKeep: { candidate in
                                    Task { await resolveArrivalCandidate(candidate, forfeit: true) }
                                }
                            )
                            .sectionCard(.standard)
                        } else {
                            // The quiet stand-in for the card. It
                            // sits where the card's own caption line
                            // would sit, so the slot does not jump
                            // when the card arrives.
                            Text(
                                ArrivalGrace.caption(
                                    playedAt: event.playedAt,
                                    graceMinutes: liveRoom.seatDepositGraceMinutes
                                )
                            )
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .padding(.horizontal, Theme.Layout.cardInset)
                        }
                    }
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
                }
                // V0.79 — one-time notification opt-in prompt. Shows
                // once per room (per device) while opt-in is off;
                // after any answer it lives in Room settings only.
                // Lane S2: no longer limited to rooms with nothing
                // scheduled (a member who arrives mid-week was never
                // asked); it steps aside while the post-claim ask shows.
                if !showsClaimReminderAsk,
                   !isNightLive,
                   currentSeason?.status != .ended,
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
                // V0.86 — one-time calendar ask. v1.1 — a post-claim
                // ask under Standings, so it never competes with
                // Claim seat. Gone after the first answer.
                if case .claimed = state,
                   CalendarService.shared.authorizationStatus() == .notDetermined,
                   !CalendarPrompt.hasSeenVoiceLine() {
                    CalendarVoiceLineRow()
                }
                // W-05 — previous-seasons comparison (US-10).
                // Renders only when the room has ended seasons; the
                // section is member-visible (read surface).
                if !roomService.cachedSeasonHistory(roomId: room.id).isEmpty {
                    SeasonsSection(
                        roomId: room.id,
                        youId: currentUserId,
                        rows: roomService.cachedSeasonHistory(roomId: room.id),
                        currentScore: leaderboard.first(where: { $0.userId == currentUserId })?.seasonScore ?? 0,
                        currentNights: currentUserId.flatMap { me in
                            roomService.cachedSeasonGrid(roomId: room.id, seasonId: nil)?.cumulative(for: me)
                        } ?? []
                    )
                }
                CollapsibleSection(
                    title: "How scoring works",
                    caption: "Every game is scored in chips.",
                    isExpanded: $packsExpanded
                ) {
                    ChipRulesSection(room: room)
                        .environmentObject(casinoService)
                }
                MembersSection(room: room)
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
            // v1.2.2 S6 T6 — this is the page's own inset from the
            // screen edges (under the toolbar, above the tab bar), not
            // a gap between two sections, so it stays. Everything
            // between sections comes from the stack's `roomSectionGap`
            // and nothing else.
            .padding(.vertical, Theme.Layout.sectionSpacing)
        }
        // Dense text scrolls under the glass toolbar; the default soft
        // edge left it legible behind the room pill and buttons.
        .scrollEdgeEffectStyle(.hard, for: .top)
        // v1.2 S2 — the floating tab bar's glass capsule tops out
        // ~83pt from the screen bottom while the automatic safe-area
        // inset reserves only the ~34pt home-indicator zone, so the
        // last ~49pt of content rested under the bar. This margin
        // stacks on the automatic inset (safe-area-aware); iPad's
        // sidebar layout just gains end-of-scroll breathing room.
        .contentMargins(.bottom, 64, for: .scrollContent)
    }

    // MARK: - State resolution

    /// C — "has the room loaded yet?" is a question about the STORE,
    /// not about this view instance. `RoomService` owns the room's
    /// load phase: `.idle` before the first fetch, `.loading` while
    /// it runs, `.loaded` once it finished (successfully or not).
    ///
    /// The old view-local `hasLoadedInitialData` flag inferred the
    /// same thing from the shape of the data, which is what pinned a
    /// genuinely-empty room to the spinner forever (the V0.100 bug).
    /// Asking the store removes the inference: a room with no night,
    /// no standings and no briefing is `.loaded` and shows its empty
    /// state, and a pull-to-refresh of a loaded room keeps the phase
    /// at `.loaded` so the spinner never comes back.
    private var state: V0State {
        V0State.resolve(
            hasLoaded: roomService.loadPhase(room.id) == .loaded,
            phase: nightPhase(for: activeEvent),
            activeEvent: activeEvent,
            myRSVP: myRSVP,
            hasWithdrawn: hasWithdrawn
        )
    }

    /// The room's auto-close window, the same one `NightPhaseResolver`
    /// and the server use.
    private func nightPhase(for event: Event?, now: Date = Date()) -> NightPhase {
        NightPhaseResolver.phase(
            for: event,
            autoCloseHours: liveRoom.autoCloseHours,
            now: now
        )
    }

    /// This viewer's chair for a night, from the RSVP, the deposit and
    /// the room's deposit mode (audit 02 C2).
    private func seatPhase(for event: Event) -> SeatPhase {
        SeatPhase.phase(
            rsvp: myRSVP,
            deposit: roomService.cachedMySeatDeposit(eventId: event.id),
            mode: liveRoom.depositMode
        )
    }

    /// "The viewer has played", one definition for the whole page: a
    /// working hand, a casino withdrawal, or a scan. `V0State` and
    /// `NightInput` both read this, so the card and its primary action
    /// cannot disagree (audit 03 D3/D4).
    private var hasWithdrawn: Bool {
        myWorkingHand > 0 || casinoWithdrawn > 0 || myScanState.hasScanned
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
        awardsForPrivacy(seasonId: currentSeason?.id ?? UUID())
    }

    private func awardsForPrivacy(seasonId: UUID) -> [SeasonAward] {
        let all = roomService.cachedSeasonAwards(seasonId: seasonId)
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
                ? "Season \(season.ordinal) is closed. Thanks for showing up."
                : "Season \(season.ordinal) is in the book."
        )
    }

    /// v1.2.2 S6 T5 — the host's unread "Notes for next time".
    ///
    /// It now sits on the page rather than inside the event card,
    /// but it renders in exactly the cases it used to: a host, with
    /// something unread, and an event that has not started. The notes
    /// are pre-event host prep, so they stay off the page once the
    /// night is live or the event has settled — which is what the
    /// three states that render `BriefingSlot` already meant.
    private var unconsumedMemberNotes: [RoomMemberNote] {
        guard isHost else { return [] }
        switch state {
        case .upcoming, .claimed, .declined:
            return roomService.cachedUnconsumedMemberNotes(roomId: room.id)
        default:
            return []
        }
    }

    @ViewBuilder
    private var activeSlot: some View {
        Group {
            switch state {
            case .loading:
                // v1.2.2 S6 T6 — this padding centres the spinner in
                // an otherwise empty page. It is the only child of the
                // stack while it renders, so it distorts no gap
                // between two sections and stays as it is.
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
                    onEdit: isHost ? { presenting = .editEvent(event) } : nil,
                    room: liveRoom,
                    heldDeposit: roomService.cachedMySeatDeposit(eventId: event.id),
                    onCheckIn: { Task { await checkInSeat(eventId: event.id) } },
                    hostedBy: hostedByLine
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
                    onEdit: isHost ? { presenting = .editEvent(event) } : nil,
                    room: liveRoom,
                    heldDeposit: roomService.cachedMySeatDeposit(eventId: event.id),
                    onCheckIn: { Task { await checkInSeat(eventId: event.id) } },
                    hostedBy: hostedByLine
                )
                if showsClaimReminderAsk {
                    ClaimReminderAskRow {
                        remindMeTheMorningOf(eventId: event.id)
                    }
                }
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
                    onEdit: isHost ? { presenting = .editEvent(event) } : nil,
                    room: room,
                    hostedBy: hostedByLine
                )

            case .inPlay(let event):
                liveCard(event: event, headerMode: .inPlay)

            // M1.1 — `.tonightEvent` is the play-just-started moment.
            // Same card as `.inPlay`; only the header differs. The
            // actions come from the night plan (S1.4).
            case .tonightEvent(let event):
                liveCard(event: event, headerMode: .tonightEvent)

            case .justSettled(let event):
                // S1.5 / 1.2.5 — the recap ends on the next night: the
                // host's "Same time next Tuesday?" (or "Plan the next
                // night") is the card's closing line, `RecapClosing`.
                // This state only renders while no future night is
                // known (the room allows one), so it never offers a
                // second upcoming night.
                recapCard(event: event)

            case .readStandings:
                // V0.100 — branch the empty-state copy on host vs
                // member. A freshly-created room (the case the
                // `.loading` bug stranded) lands here for the host
                // with zero events; the previous flat copy was
                // technically correct ("the ledger fills in after
                // your first night") but didn't offer the obvious
                // next action. The host gets the same "+ Add an
                // event" CTA that the in-room toolbar already
                // surfaces; members get the legacy "wait for the
                // host to schedule" copy.
                //
                // S3 T4 — that copy is only true while the room is
                // empty. `StandingsSection` sits further down the
                // same page, so a populated leaderboard rendered the
                // empty-state block ABOVE a real table: "No nights
                // on the books yet" on a room with nights, and the
                // member caption contradicting the rows under it.
                // Now: empty leaderboard keeps today's block; a
                // populated one drops the copy entirely for members
                // (the standings table IS the content) and keeps only
                // the host's "Add an event" action, which stays true
                // at any night count.
                if leaderboard.isEmpty {
                    // v1.2.4 S4.6 — one header style and one rhythm. The
                    // heading is now the app's `SectionTitle`, and the
                    // member's grey line rides the header's accessibility
                    // hint instead of printing under it as a second
                    // hierarchy level. The card's groups sit
                    // `cardGroupGap` apart.
                    VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
                        SectionTitle(text: isHost ? "No nights on the books yet" : "Standings")
                            .padding(.bottom, Theme.Layout.roomHeaderGap)
                            .accessibilityHint(isHost ? "" : "The ledger fills in after your first night.")
                        if isHost {
                            hostHeroActions
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sectionCard(.hero)
                } else if isHost {
                    addEventCTA
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sectionCard(.hero)
                } else {
                    EmptyView()
                }
            }
        }
        .transition(.opacity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: state)
    }

    /// Host-only "Add an event" CTA for the `.readStandings` hero.
    /// S3 T4 — extracted so the populated-leaderboard host path can
    /// render the action alone, without the empty-state title.
    private var addEventCTA: some View {
        Button {
            presenting = .addEvent(seed: nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Theme.Icon.plus)
                Text("Add an event")
            }
        }
        .buttonStyle(PrimaryButtonStyle())
        .padding(.top, 4)
    }

    /// S3.6 — the host's empty-room hero.
    ///
    /// A room with fewer than two members has nobody at the table,
    /// so the first thing the host needs is friends, not a night:
    /// "Invite friends" is the primary (the share sheet, with a join
    /// code minted on demand) and "Add a night" is the grey caption
    /// under it. Once the room has a table, the old "Add an event"
    /// CTA comes back.
    @ViewBuilder
    private var hostHeroActions: some View {
        if inviteFirst {
            inviteFriendsCTA
            Button {
                presenting = .addEvent(seed: nil)
            } label: {
                Text("Add a night")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.labelText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.plain)
            if let message = inviteCode.errorMessage {
                Text(message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        } else {
            addEventCTA
        }
    }

    /// S3.6 — the invite action. A `ShareLink` over the join code,
    /// so inviting is one tap. While the code is being minted (or
    /// when minting failed) the same action mints one instead.
    @ViewBuilder
    private var inviteFriendsCTA: some View {
        if let code = inviteCode.code {
            ShareLink(
                item: inviteShareText(for: code),
                preview: SharePreview("Join my Games Room")
            ) {
                inviteFriendsLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                Task { await mintHeroJoinCode() }
            } label: {
                inviteFriendsLabel
            }
            .buttonStyle(.plain)
            .disabled(inviteCode.isMinting)
        }
    }

    private var inviteFriendsLabel: some View {
        Text("Invite friends")
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(Theme.Palette.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func inviteShareText(for code: String) -> String {
        "Join me in Games Room. Use code \(code) to get started."
    }

    /// S3.6 — mints the join code the invite shares. There is no
    /// read RPC for the live code, so this is the only way to get
    /// one; it is minted once per empty room and then shared.
    @MainActor
    private func mintHeroJoinCode() async {
        guard inviteFirst, inviteCode.code == nil, !inviteCode.isMinting else { return }
        // P2 (audit 03 C6) — the retry clears the previous error HERE,
        // at mint start. It used to clear only on success, so a second
        // attempt showed the old failure for its whole round trip.
        inviteCode = .minting
        do {
            inviteCode = .ready(try await roomService.generateJoinCode(roomId: room.id))
        } catch {
            inviteCode = .failed(InviteCodePhase.failureMessage)
        }
    }

    // MARK: - Data operations

    /// Loads every dependency the V0.8 stage needs in parallel:
    /// the active event, the briefing summary, the leaderboard,
    /// the current member's RSVP, the open attestations, the room
    /// members (for the P1.1 roster surface), and the current
    /// season + awards (for the S1.7 season awards section).
    /// Called from `.task` and `.refreshable`.
    ///
    /// C — the load phase lives in the store (`RoomService`), not in a
    /// view flag: this funnel opens it, the body below fills the
    /// room, and the phase lands on `.loaded` when the body returns
    /// — successfully or not. The phase is per room, and a refresh of
    /// an already-loaded room keeps it `.loaded`, so pull-to-refresh
    /// never puts the spinner back over content the user is reading.
    private func refresh(force: Bool = false) async {
        await roomService.withRoomLoadPhase(roomId: room.id) {
            await loadRoomContent(force: force)
        }
    }

    /// The body of `refresh(force:)` — every loader the room page
    /// needs, in parallel. Split out of `refresh` so the phase wrapper
    /// around it reads as one line instead of a 70-line indent.
    private func loadRoomContent(force: Bool) async {
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
        async let packsLoad: [String] = roomService.loadRoomPacks(roomId: room.id, force: force)
        async let chapterLoad: () = loadChapterLineIfNeeded(force: force)
        async let transactionsLoad: () = loadEventTransactionsIfNeeded(force: force)
        async let workingHandsLoad: () = loadWorkingHandsIfNeeded(force: force)
        async let recapChipsLoad: () = loadRecapChipsIfNeeded()
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
        _ = await (active, board, attestations, briefingLoad, rsvpLoad, membersLoad, seasonLoad, eventsLoad, rsvpGridLoad, packsLoad, chapterLoad, transactionsLoad, workingHandsLoad, recapChipsLoad, tonightStarLoad, notesLoad, arrivalLoad, myDepositLoad)
        Perf.event("refresh end")
        // W2.3 — keep the widget/watch snapshot fresh with the
        // current standings. Best-effort write; the stale-empty
        // rule in `ScoreSnapshot.shouldPersist` keeps a rooms-list
        // refresh from clobbering real standings.
        let topLine = leaderboard.prefix(3)
            .map { "\($0.displayName) \($0.pointsBalance)" }
            .joined(separator: " · ")
        // The one night-phase resolver decides, so the Live Activity and
        // widget stop at the room's auto-close window like the server.
        let isLiveNow = NightPhaseResolver.phase(
            for: activeEvent, autoCloseHours: room.autoCloseHours
        ) == .live
        ScoreSnapshotStore.write(
            roomId: room.id,
            roomName: room.name,
            leaderboardLine: topLine,
            isLive: isLiveNow
        )
        // V0.98 — drive the Live Activity only while the event is
        // in progress (starts at play, ends at settle). The staleDate
        // is the moment the server stops treating the night as live,
        // so a phone that never hears about the settle still ages the
        // scoreboard out instead of pinning it (audit 04 D10).
        ScoreLiveActivityDriver.apply(
            roomId: room.id,
            roomName: room.name,
            leaderboardLine: topLine,
            isLive: isLiveNow,
            staleDate: activeEvent.map {
                LiveActivityRule.staleDate(
                    playedAt: $0.playedAt, autoCloseHours: room.autoCloseHours
                )
            }
        )
    }

    /// 1.2.5 — the cash-out results for the night recapped above the
    /// next night's card. Once the next night is booked the page's
    /// chip reads follow it, and the recap would lose its results.
    private func loadRecapChipsIfNeeded() async {
        if roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id)
        }
        guard let recap = recapAboveNextNight else {
            recapChips = nil
            return
        }
        async let hands = casinoService.loadWorkingHands(eventId: recap.id)
        async let transactions = casinoService.getEventTransactions(eventId: recap.id)
        let (h, t) = await (hands, transactions)
        recapChips = (recap.id, h, t)
    }

    /// Loads the chapter line for the active event so the
    /// ceremonial card renders the written title + call-forward.
    /// No-op when there's no active event.
    private func loadChapterLineIfNeeded(force: Bool = false) async {
        // S1.7 — the recap above the next night reads its own line.
        if let recap = roomService.cachedRecentlySettledEvent(roomId: room.id),
           recap.id != activeEvent?.id {
            await roomService.loadEventChapterLine(eventId: recap.id, force: force)
        }
        guard let event = activeEvent else { return }
        await roomService.loadEventChapterLine(eventId: event.id, force: force)
    }

    /// V0.84 C2 — loads Tonight's Star card for the active event so
    /// the ceremonial-card star section renders. No-op when there's
    /// no active event.
    private func loadTonightStarCardIfNeeded(force: Bool = false) async {
        if let recap = roomService.cachedRecentlySettledEvent(roomId: room.id),
           recap.id != activeEvent?.id {
            await roomService.loadTonightStarCard(eventId: recap.id, force: force)
        }
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

    /// Loads the per-member RSVP rows for the active event so the
    /// briefing slot's seat grid renders claimed chairs. No-op when
    /// there's no active event.
    private func loadRSVPGridIfNeeded(force: Bool = false) async {
        guard let event = activeEvent else { return }
        await roomService.loadEventRSVPs(eventId: event.id, force: force)
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
        let history = await roomService.loadSeasonHistory(roomId: room.id, force: force)
        // v1.2 slice 2c — the active season's grid feeds the
        // Seasons dual trace. Quiet no-op until migration 101.
        if !history.isEmpty {
            await roomService.loadSeasonGrid(roomId: room.id, seasonId: nil, force: force)
        }
        // S1.7 — awards for the season every member is shown (the
        // current season is open again once one closes).
        if let season = seasonToCelebrate, season.id != roomService.cachedCurrentSeason(roomId: room.id)?.id {
            await roomService.loadSeasonAwards(seasonId: season.id, force: force)
        }
    }

    private func loadMembersIfNeeded(force: Bool = false) async {
        // Always re-fetch on refresh so a member who joined after
        // the first paint shows up in the roster without a manual
        // pull-to-refresh.
        await roomService.loadRoomMembers(roomId: room.id, force: force)
    }

    private func loadActiveIfNeeded(force: Bool = false) async {
        // V1.24 (audit F1 + lane S1) — the active-event cache used to
        // freeze the night: the loader only read when the cache was
        // empty, so a night that started after the first paint never
        // appeared and pull-to-refresh could not correct it either.
        // The read now always runs; `force` decides whether the service
        // re-reads the server or serves its own 30s cache.
        // Lane S2: a host's phone tells the server the room's time zone
        // once per install, so server-sent reminders land at local
        // times. Fire and forget; never surfaces an error.
        if isHost {
            AppReconciler.reportRoomTimeZoneOnce(roomId: room.id)
        }
        let event = await roomService.loadActiveEvent(
            roomId: room.id, force: force
        )
        // Notification-etiquette fix (2026-11-04) — reconcile this
        // device's briefing requests for the room's active event
        // against the caller's CURRENT seat state on every room open:
        // claimed members never see claim-your-seat language, declined
        // members get silence, and the on-create prompt fires at most
        // once per (event, user) per install. This replaces the old
        // per-room on-create catch-up (scheduleActiveEventOnCreateIfMissing),
        // which fanned a roster of local requests out on one phone.
        if event != nil {
            await roomService.reconcileBriefing(roomId: room.id)
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
    ///
    /// V1.24 (audit F1) — the active event is re-read when the
    /// refresh is forced, so the pack check below reads tonight's
    /// event and not the one cached at the first paint.
    private func loadEventTransactionsIfNeeded(force: Bool = false) async {
        if force || roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id, force: force)
        }
        // Every night is a chips night: no pack gate.
        guard let event = activeEvent else {
            eventTransactions = []
            return
        }
        eventTransactions = await Perf.span("loadEventTransactions") { await casinoService.getEventTransactions(eventId: event.id) }
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
    ///
    /// V1.24 (audit F1) — a forced refresh re-reads the active
    /// event here too, so the pack check reads tonight's event.
    private func loadWorkingHandsIfNeeded(force: Bool = false) async {
        if force || roomService.cachedActiveEvent(roomId: room.id) == nil {
            await roomService.loadActiveEvent(roomId: room.id, force: force)
        }
        // Every night is a chips night: no pack gate.
        guard let event = activeEvent else {
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
        guard liveRoom.depositMode.isEscrow else { return }
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
    ///
    /// S3.7 — the two Skip buttons are one "Give it back", and
    /// both did the same thing on the server, so the reason is
    /// gone: the waive RPC takes no reason and the mascot copy
    /// has a default line for it.
    private func resolveArrivalCandidate(
        _ candidate: SeatDepositCandidate,
        forfeit: Bool
    ) async {
        guard let event = activeEvent else { return }
        do {
            let outcome: SeatDeposit?
            if forfeit {
                outcome = try await roomService.forfeitSeatDeposit(
                    eventId: event.id, memberId: candidate.userId
                )
            } else {
                outcome = try await roomService.waiveSeatDeposit(
                    eventId: event.id, memberId: candidate.userId, reason: nil
                )
            }
            seatActionError = nil
            if let line = SeatOutcomeCopy.hostResolved(outcome) {
                showSeatOutcome(line)
            } else {
                Haptics.light()
            }
            _ = await roomService.loadLeaderboard(roomId: room.id, force: true)
            await loadArrivalCandidatesIfNeeded(force: true)
        } catch {
            presentSeatError(error)
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
    ///
    /// S3.3 — a full night is not an error dialog: the server
    /// raises `night_full` (migration 113), the optimistic claim
    /// rolls back, and the card says "All N seats are taken."
    private func claimSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .claimed, currentUserId: currentUserId)
        do {
            _ = try await roomService.claimSeat(eventId: eventId)
            seatActionError = nil
            Haptics.success()
            await roomService.eventDidChange(eventId: eventId)
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            if ServerErrorCode.code(in: error) == .nightFull {
                // The counts in the cache are the ones that sent us
                // here: re-read them so the card agrees with the
                // server about how many chairs are gone. With the latch
                // gone, that reload is also what brings the Claim
                // button back once a chair frees up (audit 03 D1).
                await roomService.loadEventRSVPs(eventId: eventId, force: true)
                await roomService.loadBriefing(eventId: eventId, force: true)
                return
            }
            presentSeatError(error)
        }
    }

    /// Lane S2: the reminder ask shows under the claimed state while
    /// the room's notifications are off, until it is tapped.
    private var showsClaimReminderAsk: Bool {
        guard case .claimed = state else { return false }
        return !liveRoom.notificationsEnabled
            && !claimReminderAskTapped
            && !ClaimReminderAsk.isAnswered(roomId: room.id)
    }

    /// Lane S2: "Remind me the morning of". Asks iOS, turns the
    /// room's notifications on through the existing setter and
    /// re-plans this member's reminders for the claimed seat.
    private func remindMeTheMorningOf(eventId: UUID) {
        ClaimReminderAsk.markAnswered(roomId: room.id)
        RoomNotifPrompt.markAnswered(roomId: room.id)
        claimReminderAskTapped = true
        notifPromptDismissed = true
        Task {
            await ClaimReminderAsk.requestAuthorization()
            try? await roomService.setNotificationsEnabled(
                roomId: room.id, enabled: true
            )
            await roomService.reconcileBriefing(eventId: eventId)
            Haptics.light()
        }
    }

    /// Fires `RoomService.upsertEventRSVP(eventId, .declined)`.
    /// Mirror of `claimSeat`.
    /// S3.3 — "Can't make it". Routed through
    /// `RoomService.releaseSeat(eventId:state:.declined)`, which
    /// writes the RSVP through `release_seat` (migration 113): the
    /// decline gives the held deposit back instead of leaving it in
    /// escrow for the host to forfeit. Mirror of `claimSeat`.
    private func declineSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .declined, currentUserId: currentUserId)
        do {
            _ = try await roomService.releaseSeat(eventId: eventId, state: .declined)
            seatActionError = nil
            Haptics.light()
            await roomService.eventDidChange(eventId: eventId)
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            presentSeatError(error)
        }
    }

    /// V0.85 — the "I'm here" reclaim. Fires
    /// `RoomService.checkInSeat(eventId)` (migration 085's
    /// `check_in_seat` RPC); the held deposit returns to the
    /// balance and the cached deposit flips out of `.held` so
    /// the chair card drops the reclaim button. Errors surface
    /// via the shared seat-action alert.
    private func checkInSeat(eventId: UUID) async {
        let before = roomService.cachedMySeatDeposit(eventId: eventId)
        do {
            let after = try await roomService.checkInSeat(eventId: eventId)
            seatActionError = nil
            // The RPC answers `true` whether it returned the deposit or
            // found nothing to do; the reloaded row is what tells the
            // member which happened (audit 02 D3).
            if let line = SeatOutcomeCopy.checkIn(before: before, after: after) {
                showSeatOutcome(line)
            } else {
                Haptics.success()
            }
        } catch {
            presentSeatError(error)
        }
    }

    /// One place for a seat action's failure copy: a token the server
    /// names gets the app's own line, anything else keeps the message
    /// the SDK surfaced.
    private func presentSeatError(_ error: Error) {
        if let code = ServerErrorCode.code(in: error) {
            seatActionError = code.message
        } else {
            seatActionError = (error as NSError).localizedDescription
        }
        showSeatActionError = true
    }

    /// Shows the quiet one-line outcome under the page.
    private func showSeatOutcome(_ message: String) {
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            seatOutcome = SeatOutcomeToast(message: message)
        }
    }

    /// 2026-08-10 feedback round — releases a claimed seat by
    /// flipping the RSVP back to `.unclaimed`, returning the seat to
    /// the open pool.
    ///
    /// S3.3 — the write goes through `release_seat` (migration 113),
    /// so the held deposit comes back with the seat. It used to go
    /// through the plain RSVP upsert, which left the deposit in
    /// escrow until the host forfeited it: the considerate member
    /// got fined for changing their mind.
    ///
    /// The release is instant and undoable: the bottom toast offers
    /// "Undo" for five seconds, and Undo re-claims the seat.
    private func releaseSeat(eventId: UUID) async {
        let previous = roomService.applyOptimisticRSVP(eventId: eventId, state: .unclaimed, currentUserId: currentUserId)
        do {
            _ = try await roomService.releaseSeat(eventId: eventId, state: .unclaimed)
            seatActionError = nil
            Haptics.light()
            await roomService.eventDidChange(eventId: eventId)
            withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                seatReleaseToast = SeatReleaseToast(eventId: eventId)
            }
        } catch {
            _ = roomService.applyOptimisticRSVP(eventId: eventId, state: previous, currentUserId: currentUserId)
            presentSeatError(error)
        }
    }

    /// S3.3 — "Undo" in the release toast puts the seat back. It
    /// goes through the same claim path as the original claim, so a
    /// night that filled up in the meantime says so instead of
    /// quietly doing nothing.
    private func undoRelease(_ toast: SeatReleaseToast) {
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            seatReleaseToast = nil
        }
        Task { await claimSeat(eventId: toast.eventId) }
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
    /// only Casino: presents `.withdraw(event)` so the
    /// `WithdrawChipsSheet` renders. The sheet loads the member's
    /// current balance and submits through
    /// `CasinoService.withdraw(...)`. The full camera/Vision
    /// pipeline is intentionally out of scope for this MVP slice
    /// — see plan section 3 P0.5 for the accepted virtual-only
    /// Casino path.
    private func openWithdraw(event: Event) async {
        presenting = .withdraw(event)
    }

    // MARK: Night plan (chips)

    /// Tonight's chip tally: every claimed seat, plus anyone who took
    /// chips. The one source for the live card's board, the plan's
    /// "who is still playing", and the settle-early warning.
    private func tonightScore(for event: Event) -> TonightScore {
        let members = roomService.cachedMembers(roomId: room.id)
        let names = Dictionary(members.map { ($0.userId, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        let claimed = roomService.cachedEventRSVPs(eventId: event.id)
            .filter { $0.state == .claimed }
            .map(\.memberId)
        return TonightScore.tally(
            hands: workingHands,
            transactions: eventTransactions,
            players: claimed,
            names: names
        )
    }

    /// Where the viewer is in tonight's chip loop. `WorkingHand` owns
    /// the "cashed out" rule.
    private var myChips: MyChips {
        guard let mine = workingHands.first(where: { $0.memberId == currentUserId }) else { return .none }
        if mine.isCashedOut { return .cashedOut }
        return mine.tookChips ? .playing : .none
    }

    /// Every fact the night plan needs, read from the caches.
    private func nightInput(for event: Event) -> NightInput {
        let score = tonightScore(for: event)
        let others = score.rows.filter { $0.memberId != currentUserId }
        return NightInput(
            isHost: isHost,
            phase: nightPhase(for: event),
            iHaveHeldDeposit: seatPhase(for: event).deposit?.status == .held,
            myChips: myChips,
            othersPlaying: others.filter { $0.status == .playing }.map(\.name),
            othersCashedOut: others.contains { $0.net != nil }
        )
    }

    /// One night action as a rendered line on the live card. Every
    /// button carries the line above it that says when to tap it.
    private func nightLine(for action: NightAction, event: Event) -> WitnessSlot.Line? {
        switch action {
        case .claimSeat:
            return nil
        case .checkIn:
            return WitnessSlot.Line(
                title: "I'm here",
                style: .button,
                lead: "Tap when you walk in to get your deposit back.",
                action: { Task { await checkInSeat(eventId: event.id) } }
            )
        case .takeChips:
            if myChips == .playing {
                // The quiet top-up under "Cash out".
                return WitnessSlot.Line(title: "Take more chips", style: .button, action: { presenting = .withdraw(event) })
            }
            return WitnessSlot.Line(
                title: "Take your chips",
                style: .button,
                lead: "Start here. Play anything tonight. Winners get paid in chips.",
                action: { presenting = .withdraw(event) }
            )
        case .cashOut:
            return WitnessSlot.Line(
                title: "Cash out: scan your chips",
                style: .button,
                lead: "Done for the night? Scan everything in front of you.",
                action: { presenting = .settleScan(event) }
            )
        case .waitingForCashOut(let names):
            return WitnessSlot.Line(title: NightPlan.waitingCaption(names: names), style: .caption)
        case .settleNight:
            let stillPlaying = tonightScore(for: event).playing
                .filter { $0.memberId != currentUserId }
                .map(\.name)
            return WitnessSlot.Line(
                title: "Settle the night",
                style: .button,
                lead: stillPlaying.isEmpty ? "Everyone's cashed out. Settle to lock tonight into the standings." : nil,
                action: {
                    if stillPlaying.isEmpty {
                        settleNight(event: event)
                    } else {
                        roomConfirm = .settleEarly(event: event, stillPlaying: stillPlaying)
                    }
                },
                a11yLabel: isHost ? "Settle the night (host)" : nil
            )
        case .planNextNight:
            return WitnessSlot.Line(title: "Plan the next night", style: .button, action: { planNextNight(after: event) })
        }
    }

    /// The live card: tonight's board, the one primary, the quiet line
    /// under it.
    private func liveCard(event: Event, headerMode: WitnessSlot.HeaderMode) -> some View {
        let plan = NightPlan.plan(for: nightInput(for: event))
        let secondaries = plan.secondaries.compactMap { nightLine(for: $0, event: event) }
        let inHand = myChips == .none ? nil : myWorkingHand
        // P2 (audit 03 C2) — a failed settle is this card's own line,
        // scoped to the night it failed on, and the line is the retry.
        let settleFailedHere = isHost && settle.failedEventId == event.id
        return WitnessSlot(
            event: event,
            attestations: openAttestations,
            primary: plan.primary.flatMap { nightLine(for: $0, event: event) },
            secondaries: secondaries,
            isHero: true,
            headerMode: headerMode,
            workingHand: inHand,
            hasScanned: myScanState.hasScanned,
            scannedValue: myScanState.scannedValue,
            note: settleFailedHere ? (settle.failedMessage ?? SettlePhase.failureMessage) : plan.caption,
            noteAction: settleFailedHere ? { settleNight(event: event) } : nil,
            tonight: tonightScore(for: event),
            currentUserId: currentUserId
        )
    }

    // MARK: Season awards + recap sections (S1.7)

    /// S1.7 — every ended season the page knows about: the one the
    /// host just closed here, the current season if it has ended,
    /// and the room's ended seasons from the history read.
    private var endedSeasons: [Season] {
        var seasons: [Season] = []
        if let closed = justClosedSeason {
            seasons.append(closed.endedAt == nil
                ? Season(id: closed.id, roomId: closed.roomId, ordinal: closed.ordinal,
                         subtitle: closed.subtitle, status: .ended,
                         startedAt: closed.startedAt, endedAt: Date())
                : closed)
        }
        if let current = currentSeason, current.status == .ended {
            seasons.append(current)
        }
        for row in roomService.cachedSeasonHistory(roomId: room.id) {
            seasons.append(Season(
                id: row.seasonId, roomId: room.id, ordinal: row.ordinal,
                subtitle: row.subtitle, status: .ended,
                startedAt: row.startedAt, endedAt: row.endedAt
            ))
        }
        return seasons
    }

    /// S1.7 — the season whose awards the page shows: the most
    /// recently ended one, within 7 days, not dismissed here.
    private var seasonToCelebrate: Season? {
        _ = seasonAwardsDismissedFlip
        return SeasonAwardsWindow.seasonToShow(
            endedSeasons,
            now: Date(),
            isDismissed: { UserDefaults.standard.bool(forKey: SeasonAwardsWindow.dismissedKey(seasonId: $0)) }
        )
    }

    /// S1.7 — "Done" on the awards: gone for this member, this device.
    private func dismissSeasonAwards(_ season: Season) {
        UserDefaults.standard.set(true, forKey: SeasonAwardsWindow.dismissedKey(seasonId: season.id))
        if justClosedSeason?.id == season.id { justClosedSeason = nil }
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            seasonAwardsDismissedFlip.toggle()
        }
    }

    /// S1.7 (TARS) — the settled night that renders as its own section
    /// above the next night's card. nil when the active event is the
    /// settled night itself (`.justSettled` renders it as the slot).
    private var recapAboveNextNight: Event? {
        NightPlan.recapAboveNextNight(
            recent: roomService.cachedRecentlySettledEvent(roomId: room.id),
            active: activeEvent,
            now: Date(),
            autoCloseHours: liveRoom.autoCloseHours
        )
    }

    /// The settled night's recap card. Shared by `.justSettled` and
    /// the recap section above the next night.
    private func recapCard(event: Event) -> some View {
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
                : nil,
            currentUserId: currentUserId,
            hostedBy: hostedByLine,
            results: recapResults(for: event),
            closing: recapClosing(for: event),
            closingNote: booking.failedMessage,
            onBookSameTime: { offer in bookSameTime(offer) },
            onPickAnotherTime: { offer in
                presenting = .addEvent(seed: offer.playedAt, packs: offer.packSlugs)
            },
            onPlanNextNight: { planNextNight(after: event) },
            onClaimNextSeat: {
                guard let next = activeEvent, next.id != event.id else { return }
                Task { await claimSeat(eventId: next.id) }
            }
        )
    }

    /// How the night went. The chip reads are loaded for the page's
    /// active night; when the recap IS that night it carries them, and
    /// when the recap sits above the next night it reads its own rows
    /// (`recapChips`).
    private func recapResults(for event: Event) -> TonightScore? {
        if event.id == activeEvent?.id { return tonightScore(for: event) }
        guard let chips = recapChips, chips.eventId == event.id else { return nil }
        let members = roomService.cachedMembers(roomId: room.id)
        let names = Dictionary(members.map { ($0.userId, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        return TonightScore.tally(
            hands: chips.hands,
            transactions: chips.transactions,
            players: [],
            names: names
        )
    }

    /// 1.2.5 — the recap's last line. The next night when one is on the
    /// books (or the host's booking is pending), else the host's
    /// "Same time next Tuesday?", else "Plan the next night".
    private func recapClosing(for event: Event) -> RecapClosing {
        let now = Date()
        let timeZone = liveRoom.timeZone
        let hasFuture = NextNightOffer.hasFutureNight(
            active: activeEvent, settledId: event.id, now: now,
            autoCloseHours: liveRoom.autoCloseHours
        )
        // The closing line names a night that has not started yet; a
        // next night already under way has its own card below.
        let booked: Event? = hasFuture && nightPhase(for: activeEvent, now: now) == .upcoming ? activeEvent : nil
        let offer = NextNightOffer.offer(
            settled: event,
            isHost: isHost,
            hasFutureNight: hasFuture,
            settleInFlight: settle.showsToast,
            now: now,
            timeZone: timeZone
        )
        let canPlan = !hasFuture && NightPlan.plan(for: nightInput(for: event)).primary == .planNextNight
        return RecapClosing.resolve(
            isHost: isHost,
            nextNightAt: booked?.playedAt ?? booking.pendingOffer?.playedAt,
            nextNightIsReal: booked != nil,
            myRSVPOnNext: booked.map { roomService.cachedRSVP(eventId: $0.id) },
            offer: offer,
            canPlan: canPlan,
            timeZone: timeZone
        )
    }

    /// 1.2.5 — "Same time next Tuesday?". Optimistic: the recap reads
    /// "Next: Tue 17 Nov, 7pm" at once and "Next night booked." offers
    /// Undo for 5 s. Only then does the night go to the server, so a
    /// night the host takes back never reaches the table.
    private func bookSameTime(_ offer: NextNightOffer) {
        guard !booking.isCommitting else { return }
        bookingTask?.cancel()
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await commitBooking(offer)
        }
        bookingTask = task
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            booking = booking.reduce(.begin(offer))
        }
    }

    /// Undo inside the window: nothing was sent.
    private func undoBooking() {
        bookingTask?.cancel()
        bookingTask = nil
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            booking = booking.reduce(.undo)
        }
    }

    /// The create itself, once the Undo window has passed.
    private func commitBooking(_ offer: NextNightOffer) async {
        booking = booking.reduce(.commitStarted)
        do {
            let newId = try await roomService.addEvent(
                roomId: room.id,
                name: offer.name,
                playedAt: offer.playedAt,
                packSlugs: offer.packSlugs
            )
            await roomService.eventDidChange(eventId: newId)
            Haptics.success()
            bookingTask = nil
            // Read the new night before the pending line goes, so the
            // recap's "Next: ..." never blinks out and back.
            await refresh(force: true)
            withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                booking = booking.reduce(.commitSucceeded)
            }
        } catch {
            bookingTask = nil
            if ServerErrorCode.code(in: error) == .oneUpcomingNight {
                // A night is on the books after all: show it.
                await refresh(force: true)
                withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                    booking = booking.reduce(.alreadyBooked)
                }
            } else {
                withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                    booking = booking.reduce(.commitFailed(NextNightBooking.failureMessage))
                }
            }
        }
    }

    /// S1.5 / P2 (audit 03 C2) — "Settle the night". Optimistic: the
    /// cached night reads as settled at once (the recap renders) and
    /// "Night settled." offers Undo for 5 s. Only after 5 s without Undo
    /// does the settle go to the server; the toast then stays up through
    /// `.committing`, and a failure lands on the live card as a retry.
    private func settleNight(event: Event) {
        // An in-flight RPC owns the phase; sending the same night twice
        // is the one thing this machine must not do.
        guard !settle.isCommitting else { return }
        // A second settle replaces the first: the old 5 s window must
        // not fire against the new one.
        settleTask?.cancel()
        roomService.setCachedSettledAt(eventId: event.id, Date())
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await commitSettle(event: event)
        }
        settleTask = task
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            settle = settle.reduce(.begin(event))
        }
    }

    /// S1.5 — Undo: the night goes back live and nothing is sent. Only
    /// offered inside the 5 s window (`SettlePhase.undoingEvent`).
    private func undoSettle(_ event: Event) {
        settleTask?.cancel()
        settleTask = nil
        roomService.setCachedSettledAt(eventId: event.id, nil)
        withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
            settle = settle.reduce(.undo)
        }
    }

    /// S1.5 — the settle itself, once the Undo window has passed.
    private func commitSettle(event: Event) async {
        settle = settle.reduce(.commitStarted(event.id))
        do {
            _ = try await roomService.settleEvent(eventId: event.id)
            Haptics.success()
            settleTask = nil
            withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                settle = settle.reduce(.commitSucceeded(event.id))
            }
            ScoreLiveActivityDriver.endNight(roomId: room.id)
            async let active: Event? = roomService.loadActiveEvent(roomId: room.id, force: true)
            async let board: [LeaderboardEntry] = roomService.loadLeaderboard(roomId: room.id, force: true)
            async let season: () = loadSeasonIfNeeded(force: true)
            _ = await (active, board, season)
        } catch {
            roomService.setCachedSettledAt(eventId: event.id, nil)
            withAnimation(reduceMotion ? nil : Theme.Motion.fade) {
                settle = settle.reduce(.commitFailed(event.id, SettlePhase.failureMessage))
            }
        }
    }

    /// S1.5 — "Plan the next night": AddEventSheet seeded 7 days
    /// after tonight, same time.
    private func planNextNight(after event: Event) {
        presenting = .addEvent(
            seed: NextNightOffer.sameTimeNextWeek(after: event.playedAt, timeZone: liveRoom.timeZone),
            packs: event.packSlugs
        )
    }
}

// MARK: - Briefing slot

private struct BriefingSlot: View {
    let event: Event
    let briefing: BriefingSummary?
    let myRSVP: MemberRSVPState
    let onClaim: () -> Void
    let onDecline: () -> Void
    /// V0.84 C5 — the room the briefing belongs to. Read for the
    /// seat grid's room id and the deposit trigger. The host's
    /// "Notes for next time" section, which also used to read the
    /// mascot name off this, is a page section now (S6 T5).
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
    /// V0.85 — the caller's seat deposit for the event, or nil.
    /// A held deposit renders the "I'm here" reclaim button on
    /// the chair card; nil keeps the claimed state as it was.
    let heldDeposit: SeatDeposit?
    /// V0.85 — the "I'm here" tap. Returns the held deposit
    /// instantly; the reclaim IS the check-in. Wired up only
    /// when the parent passes a non-nil callback.
    let onCheckIn: (() -> Void)?
    /// "Hosted by Nathan": the night has a person behind it.
    let hostedBy: String?
    // V0.79 — notification toggle params removed. Preferences moved
    // to the one-time RoomNotifPromptCard (main room page) and
    // RoomSettingsSheet's "My notifications" section.
    /// v1.2.2 S6 T3 — the event's Currently Into rows, for the
    /// brought-by caption under a claimed seat (S6 T4). Read from
    /// the root `environmentObject`, as `ClaimedCardAskField` does.
    @EnvironmentObject private var questionBox: QuestionBoxService
    /// 1.2.5 Task 3 — the room's board, for `newcomerLines`.
    @EnvironmentObject private var roomService: RoomService

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
        heldDeposit: SeatDeposit? = nil,
        onCheckIn: (() -> Void)? = nil,
        hostedBy: String? = nil
    ) {
        self.hostedBy = hostedBy
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
        self.heldDeposit = heldDeposit
        self.onCheckIn = onCheckIn
    }

    /// The night's phase, read from the room's own auto-close window.
    private var nightPhase: NightPhase {
        NightPhaseResolver.phase(for: event, autoCloseHours: room.autoCloseHours)
    }

    /// This member's chair, from the three facts the server keeps.
    private var seatPhase: SeatPhase {
        SeatPhase.phase(
            rsvp: myRSVP,
            deposit: heldDeposit,
            mode: room.depositMode
        )
    }

    /// S3.3 — a table has a fixed number of chairs. The count comes from
    /// the server's briefing summary; the seat-grid rows are the
    /// fallback while the summary is still loading.
    ///
    /// C3 (audit 03 D1) — this is derived, never latched. A `night_full`
    /// refusal reloads the briefing, so the moment a chair frees up the
    /// Claim button comes back without the page being recreated.
    private var seatAvailability: SeatAvailability {
        SeatAvailability.compute(
            rsvp: myRSVP,
            seatsClaimed: max(
                briefing?.seatsClaimed ?? 0,
                rsvps.filter { $0.state == .claimed }.count
            ),
            maxSeats: event.maxSeats
        )
    }

    private var isNightFull: Bool { seatAvailability == .full }

    /// 1.2.5 Task 3 — "Sam's first night. Give them a job: ...". Host
    /// only, before the night only, at most two. `NewcomerJob` owns
    /// every rule; this only hands it the facts.
    private var newcomerLines: [String] {
        let board = roomService.cachedLeaderboard(roomId: room.id)
        return NewcomerJob.lines(
            isHost: isHost,
            viewerId: currentUserId,
            phase: nightPhase,
            seats: rsvps.map {
                NewcomerJob.Seat(memberId: $0.memberId, displayName: $0.displayName,
                                 state: $0.state, claimedAt: $0.claimedAt)
            },
            isFirstNight: { BroughtBy.isFirstNight($0, board: board) }
        )
    }

    var body: some View {
        // v1.2.2 S6 T2 — the card body is ONE stack on two spacing
        // steps and nothing else: groups sit `cardGroupGap` apart,
        // and the lines that belong together inside the header
        // block sit `cardLineGap` apart. The ad-hoc `.padding(.top,
        // N)` nudges that used to sit between groups are gone —
        // this stack's spacing is the only gap a group boundary
        // gets.
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            // (1) header block — title, date, place. These lines
            // belong together, so they sit `cardLineGap` apart.
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text(event.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)

                // v1.2 S2 — seat count lives in the tile grid below.
                // "Tonight", "Tomorrow", "In 3 days" in front of the
                // date, so nobody has to work out how far away it is.
                HStack(spacing: Theme.Layout.cardLineGap) {
                    if let when = NightWhen.label(playedAt: event.playedAt, now: Date()) {
                        Text(when)
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                        Text("·")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .accessibilityHidden(true)
                    }
                    Text("\(event.playedAt, format: .dateTime.weekday().day().month().hour().minute())")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                .accessibilityElement(children: .combine)

                if let venue = event.venue, !venue.isEmpty {
                    Text(venue)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.labelText)
                }
                if let hostedBy {
                    Text("Hosted by \(hostedBy)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            // (2) description — what the host wants said about the night.
            if let hostNote = event.hostNote, !hostNote.isEmpty {
                Text(hostNote)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.bodyMuted)
            }

            // (3) "Edit details" — W2.4 member-side event edit.
            // Host-only: the parent passes `onEdit` for the host
            // and nil for everyone else. The affordance sits with
            // the briefing content, not in a settings tab.
            if let onEdit {
                Button(action: onEdit) {
                    HStack(spacing: Theme.Layout.cardLineGap) {
                        Image(systemName: Theme.Icon.infoCircle)
                            .accessibilityHidden(true)
                        Text("Edit details")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
            }

            // 2026-08-10 feedback round — the seat grid is the
            // "chairs coloured in" visual indicator: claimed seats
            // render filled with the member's initial, open seats
            // render as outline chairs, the current user's seat is
            // highlighted. Renders whenever the event has a
            // maxSeats count, even before the per-member RSVP rows
            // load (the grid then shows all-open seats).
            if event.maxSeats > 0 {
                // (4) the seat grid. V0.107 — the room id rides in so a
                // claimed seat's VoiceOver label can name who brought the
                // member (spec §2, A8).
                //
                // v1.2 S2 — aggregate claimant caption deleted; the
                // Who's-coming list below names every claimant.
                SeatGridRow(maxSeats: event.maxSeats, roomId: room.id,
                            rsvps: rsvps, currentUserId: currentUserId)
            }

            // (4b) 1.2.5 Task 3 — the host's newcomer job lines. Plain
            // grey text, no card, no button; empty for everyone else.
            let newcomers = newcomerLines
            if !newcomers.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                    ForEach(newcomers, id: \.self) { line in
                        Text(line)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("newcomer-job")
            }

            // (5) actions — one group per RSVP state. v1.2 S2 — one
            // primary per card state; the decline is a plain-text
            // secondary, never an outlined peer.
            switch myRSVP {
            case .unclaimed:
                VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
                    // S3.3 — a full night says so. The claim
                    // button is gone (there is no chair to take)
                    // and a plain grey line takes its place. The
                    // decline below stays: saying "I can't make it"
                    // is still the right answer on a full table.
                    if isNightFull {
                        Text("All \(event.maxSeats) seats are taken.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    } else {
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
                    }
                    // v1.2.2 S6 T2 — the decline is a caption-grey
                    // text button centred under the full-width
                    // primary, same action and same accessibility
                    // label as before. It used to be a
                    // `TrailingTextAction`, which right-aligned it
                    // with a chevron while everything else on the
                    // card was left-aligned. That component stays
                    // untouched — the other card states still use
                    // it.
                    Button(action: onDecline) {
                        Text("Can't make it")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Can't make it"))
                }

            case .claimed:
                VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
                    // v1.2.2 S6 T2 — icon and its own label belong together,
                    // so they sit `cardLineGap` apart (was an ad-hoc 6).
                    HStack(spacing: Theme.Layout.cardLineGap) {
                        Image(systemName: Theme.Icon.checkmarkCircleFill)
                            .foregroundStyle(Theme.Palette.accent)
                        Text("You're in.")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    // V0.106 — the one optional ask (spec §3): Currently
                    // Into when stale/empty, else the Question Box field.
                    // Inline after the claim; claiming never waits on it.
                    if event.playedAt > Date() {
                        ClaimedCardAskField(roomId: room.id, eventId: event.id)
                    }
                    // V0.85 — the reclaim. A held deposit renders
                    // the "I'm here" button: one tap returns the
                    // deposit and records attendance itself. The
                    // member wants their chips back, so no nagging
                    // is ever needed.
                    //
                    // V0.91 amend — gate on `seatDepositTrigger ==
                    // .escrow` as well. When the host flips
                    // deposits off mid-event, an existing held row
                    // stays in `seat_deposits.status = 'held'` (we
                    // never auto-return on a toggle), but the
                    // reclaim UI must disappear — the room is no
                    // longer running the escrow, the "I'm here" tap
                    // has nothing to return, and a stuck button on
                    // a claimed seat is naked debt.
                    // 2026-09-02 fix — check-in is a PHYSICAL arrival action:
                    // the button exists only once the event has actually
                    // started (playedAt <= now). Before that a claimed seat
                    // shows only "Release my seat" — you can't walk in two
                    // days early.
                       if case .held(let deposit) = seatPhase,
                       nightPhase == .live,
                       let onCheckIn {
                        // v1.2.4 S4.6 — the explainer and the button it
                        // explains are one group, so they sit
                        // `cardLineGap` apart instead of a full
                        // `cardGroupGap` away from each other.
                        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                            Text("Tap when you walk in and your deposit comes straight back.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                            Button(action: onCheckIn) {
                                Text("I'm here. Reclaim \(deposit.amount) CC")
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .accessibilityLabel(Text("Check in and reclaim the \(deposit.amount) CC seat deposit"))
                        }
                    }
                    // 2026-08-10 feedback round — a claimed seat is
                    // not terminal: the member can release it and
                    // the seat returns to the open pool.
                    // v1.2 S2 — plain-text secondary; the reclaim
                    // above is this state's only primary.
                    if let onRelease {
                        TrailingTextAction(title: "Release my seat", action: onRelease)
                    }
                }

            case .declined:
                V0StateReEntryPills(
                    onReAccept: onReAccept ?? {},
                    onReDecline: onReDecline ?? {}
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v1.2.4 S4.4 — one card shape. The slot used to draw its own
        // chrome (radius 14, 1pt hairline) on top of its content; it
        // is now a `sectionCard`, so the briefing card, the live card
        // and every other card on the room page share one radius, one
        // stroke weight and one fill.
        .sectionCard(isHero ? .hero : .standard)
        .appearTransition()
        // v1.2.2 S6 T3 — the "Who's coming" list that used to sit
        // here also owned the load of the event's Currently Into
        // rows. The rows still drive the brought-by caption, which
        // S6 T4 moves into the seat popover, so the load moves up
        // onto the card that owns the event: `currentlyIntoLine`
        // then reads the cached dictionary, exactly as before.
        .task(id: event.id) { await questionBox.loadEventCurrentlyInto(eventId: event.id) }
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
        // v1.2 S2 — one primary per card state: Re-accept carries
        // the fill; Re-decline is the trailing text secondary.
        // v1.2.4 S4.6 — the declined state's groups sit
        // `cardGroupGap` apart (the ad-hoc 8 was neither step).
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            Text("You said you can\'t make it.")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.secondaryText)
            Button(action: onReAccept) {
                Text("Re-accept")
            }
            .buttonStyle(PrimaryButtonStyle())
            TrailingTextAction(title: "Re-decline", action: onReDecline)
        }
    }
}

/// v1.2 S2 — the plain grey text action every card state uses for
/// its non-primary verb. Exactly one brass-filled primary per card
/// state; everything else on the card is this.
///
/// v1.2.4 S4.3 — the card's secondary is now the app's one
/// secondary style: a centred grey caption with no chevron and no
/// chrome, sitting under the primary. The old trailing-aligned
/// chevron version put this action at the card's right edge while
/// the unclaimed card centred the same verb, so a one-tap state
/// change moved the secondary across the card. The component stays
/// (call sites are unchanged) and now renders `SecondaryTextAction`.
private struct TrailingTextAction: View {
    let title: String
    let action: () -> Void

    var body: some View {
        SecondaryTextAction(title: title, action: action)
    }
}

// MARK: - Seat release toast (S3.3)

/// S3.3 — the state behind the "Seat released." toast. The token
/// makes every release its own toast, so releasing twice in a row
/// restarts the five-second Undo window instead of keeping the old
/// one on screen.
private struct SeatReleaseToast: Identifiable {
    let eventId: UUID
    let id: UUID = UUID()
}

/// C3 (audit 02) — the quiet line after a seat action whose result the
/// member could not otherwise tell apart from a no-op.
private struct SeatOutcomeToast: Identifiable {
    let message: String
    let id: UUID = UUID()
}

private struct SeatOutcomeToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.cardInset)
            .padding(.vertical, Theme.Layout.cardLineGap)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Theme.Palette.hairline, lineWidth: 1)
            )
    }
}

/// S3.3 — the bottom toast after a seat is released. Quiet by
/// default: one line of text and one plain-text action, no chrome
/// beyond a hairline. The Undo window (five seconds) belongs to
/// the caller.
private struct SeatReleaseToastView: View {
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Theme.Layout.cardLineGap) {
            Text("Seat released.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText)
            Spacer(minLength: Theme.Layout.cardLineGap)
            Button(action: onUndo) {
                Text("Undo")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Undo the seat release"))
        }
        .padding(.horizontal, Theme.Layout.cardInset)
        .padding(.vertical, Theme.Layout.cardLineGap)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.Palette.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Unconsumed member notes (V0.84 C5 — host pre-event)

/// V0.84 C5 — host-only section for the room's unread member
/// notes. Per the spec: for each note — "<MascotName>: <Member> left a
/// note for next time." + the note text (body font). After render
/// (onAppear of section), host taps "Done reading" ⇒
/// `markMemberNotesConsumed` with the listed ids.
///
/// v1.2.2 S6 T5 — this used to sit inside the event card, under the
/// RSVP buttons, which made the card taller and blurred where the
/// event ended. It is now a room-page section directly after the
/// card: the same `SectionTitle` header every other section on this
/// page uses, the header's `roomHeaderGap`, the rows on the page
/// background rather than the card background, and its space above
/// and below from the page stack's `roomSectionGap`.
private struct UnconsumedMemberNotesSection: View {
    let room: Room
    let notes: [RoomMemberNote]
    let onDone: ([UUID]) -> Void

    /// Stable ids used by the "Done reading" CTA. Captured on
    /// `onAppear` so we don't re-snapshot every render.
    @State private var capturedIds: [UUID] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Notes for next time")
                .padding(.bottom, Theme.Layout.roomHeaderGap)
            // A note's two lines belong together (`cardLineGap`, as
            // they were before); the notes themselves are groups, so
            // they sit `cardGroupGap` apart, and "Done reading" takes
            // the same step off the last note rather than the ad-hoc
            // 10 this block used before.
            VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
                ForEach(notes, id: \.id) { note in
                    VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                        Text("\(room.mascotName): \(note.memberDisplayName) left a note for next time.")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                        Text(note.noteText)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                }
                // v1.2 S2 — "Done reading" is a plain tertiary text
                // action; it still marks the notes consumed.
                Button(action: { onDone(capturedIds) }) {
                    Text("Done reading")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if capturedIds.isEmpty {
                capturedIds = notes.map(\.id)
            }
        }
    }
}

// MARK: - Seat grid row (2026-08-10 feedback round)

/// The "chairs coloured in" seat indicator on the briefing slot.
/// Renders `maxSeats` cells: claimed seats show the member's
/// initial, open seats render an outline chair, and the current
/// user's seat is tinted with the brass accent. The grid adapts
/// its column count to the seat total so 4, 6, and 8-seat tables
/// all read cleanly.
///
/// v1.2 S2 — flattened: tiles render directly on the card
/// background with hairline rules between them; no per-cell box
/// chrome and the outer edge stays open (the card is the box).
private struct SeatGridRow: View {
    let maxSeats: Int
    /// V0.107 — the room the event belongs to. Read for the roster
    /// (to resolve the anchor) and the room's brought-by switch.
    let roomId: UUID
    let rsvps: [EventRSVP]
    let currentUserId: UUID?
    @EnvironmentObject private var roomService: RoomService
    /// v1.2.2 S6 T4 — the event's Currently Into rows, for the seat
    /// popover's caption. The event card owns the load
    /// (`BriefingSlot.task`); this reads the same cached dictionary
    /// the removed who's-coming list read, so the staleness rule
    /// V0.106 shipped is unchanged.
    @EnvironmentObject private var questionBox: QuestionBoxService

    /// v1.2.2 S6 T4 — whose seat popover is open. One at a time: a
    /// grid of buttons all sharing one presenter reads as "the grid
    /// is open", not "this seat is open". The binding per cell is
    /// built from this id.
    @State private var popoverMemberId: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// D1 — "do I hold a claimed seat?", answered by the roster. The
    /// grid used to keep a `justClaimed` flag in `@State` and clear it
    /// 500 ms later from a detached `Task`; the roster already knows
    /// whose seat this is, so the flag was a second copy of the truth
    /// waiting to go stale. One answer, one owner: the rsvps.
    private var mySeatClaimed: Bool {
        guard let me = currentUserId else { return false }
        return rsvps.contains { $0.memberId == me && $0.state == .claimed }
    }

    private var columnCount: Int { SeatGrid.columnCount(for: maxSeats) }

    private var rowCount: Int {
        Int(ceil(Double(maxSeats) / Double(columnCount)))
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: 0),
            count: columnCount
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(SeatGrid.cells(maxSeats: maxSeats, rsvps: rsvps)) { cell in
                seatCell(cell)
                    .padding(.vertical, 10)
                    .overlay(alignment: .trailing) {
                        if hasTrailingHairline(cell.id) {
                            Rectangle()
                                .fill(Theme.Palette.hairline)
                                .frame(width: 0.5)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if hasBottomHairline(cell.id) {
                            Rectangle()
                                .fill(Theme.Palette.hairline)
                                .frame(height: 0.5)
                        }
                    }
            }
        }
        // D1 — the roster is the animation input. When it changes, the
        // grid cross-fades to the new arrangement instead of the view
        // deciding when to celebrate.
        .animation(reduceMotion ? nil : Theme.Motion.fade, value: rsvps)
    }

    /// Vertical rule after every cell that is not in the last
    /// column; horizontal rule under every cell that is not in the
    /// last row. Contiguous cells join into full grid lines.
    private func hasTrailingHairline(_ index: Int) -> Bool {
        (index + 1) % columnCount != 0
    }

    private func hasBottomHairline(_ index: Int) -> Bool {
        index / columnCount < rowCount - 1
    }

    @ViewBuilder
    private func seatCell(_ cell: SeatGrid.Cell) -> some View {
        if let rsvp = cell.rsvp {
            let isYours = rsvp.memberId == currentUserId
            // v1.2.2 S6 T4 — a claimed seat is a button: tapping it
            // opens who claimed it and who brought them. The cell
            // keeps its chair-and-initial look, so the button style
            // is plain. Open seats below stay non-interactive — an
            // empty chair has nobody to talk about.
            Button {
                Haptics.light()
                popoverMemberId = rsvp.memberId
            } label: {
                // v1.2.4 S4.6 — the chair and its initial are two
                // lines of one cell: `cardLineGap` (4), not the
                // ad-hoc 3.
                VStack(spacing: Theme.Layout.cardLineGap) {
                    Image(systemName: Theme.Icon.chairFill)
                        .font(Theme.Typography.body)
                        .foregroundStyle(isYours ? Theme.Palette.accent : Theme.Palette.bodyMuted)
                        .accessibilityHidden(true)
                    Text(initial(for: rsvp.displayName))
                        .font(Theme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(isYours ? Theme.Palette.accent : Theme.Palette.labelText)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .overlay {
                    // D1 — the burst hangs off the roster, not off a
                    // timer: it rides the cell that carries my claim.
                    if isYours && mySeatClaimed {
                        ConfettiBurst()
                    }
                }
                .animation(reduceMotion ? nil : Theme.Motion.popIn, value: isYours)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(accessibilityLabel(for: rsvp)))
            .accessibilityIdentifier("seat-\(rsvp.displayName)")
            .popover(
                isPresented: Binding(
                    get: { popoverMemberId == rsvp.memberId },
                    set: { if !$0 { popoverMemberId = nil } }
                )
            ) {
                seatPopover(for: rsvp)
                    // iPhone would turn this into a sheet by default;
                    // the room asks for a popover so it stays anchored
                    // to the seat that was tapped.
                    .presentationCompactAdaptation(.popover)
            }
        } else {
            VStack(spacing: Theme.Layout.cardLineGap) {
                Image(systemName: Theme.Icon.chair)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .accessibilityElement()
            .accessibilityLabel(Text("open seat"))
        }
    }

    /// v1.2.2 S6 T4 — the popover: the member's name, then the grey
    /// caption the who's-coming list used to carry. Same inputs, same
    /// order, same wording (`BroughtBy` owns the wording); only the
    /// place it is read from changed.
    private func seatPopover(for rsvp: EventRSVP) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            Text(rsvp.displayName)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            if let line = caption(for: rsvp) {
                Text(line)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .accessibilityIdentifier("seat-popover-\(rsvp.displayName)")
            }
        }
        .padding(Theme.Layout.cardInset)
    }

    /// Anchor · first night · Currently Into, all optional. Same four
    /// inputs the removed `WhosComingList` used, so nothing about the
    /// wording or the staleness rule changes — only the surface.
    private func caption(for rsvp: EventRSVP) -> String? {
        return BroughtBy.caption(
            anchorName: roomService.anchorName(forUserId: rsvp.memberId, roomId: roomId),
            firstNight: isFirstNight(rsvp.memberId),
            currentlyInto: questionBox.currentlyIntoLine(eventId: rsvp.eventId, memberId: rsvp.memberId),
            enabled: roomService.cachedShowBroughtBy(roomId: roomId)
        )
    }

    /// First night = no settled session in this room yet, so the
    /// leaderboard's all-time `sessionsPlayed` is 0 (spec §4). A
    /// member missing from the board means it has not loaded on this
    /// path yet: treat that as "not a newcomer" rather than calling
    /// the whole room first-night on a cold open.
    private func isFirstNight(_ userId: UUID) -> Bool {
        BroughtBy.isFirstNight(userId, board: roomService.cachedLeaderboard(roomId: roomId))
    }

    private func initial(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "·" }
        return String(first).uppercased()
    }

    /// V0.107 — the anchor rides in the label, not on the chair:
    /// "Sam's seat, with Alex, claimed". The chair cell itself is
    /// an initial, so there is nowhere else to put it (spec §2).
    /// `BroughtBy.seatLabel` owns the wording and the room-switch
    /// check, so switching it off drops the anchor here exactly the
    /// way it drops it from the caption under the grid (A7).
    private func accessibilityLabel(for rsvp: EventRSVP) -> String {
        let isYours = rsvp.memberId == currentUserId
        let owner = isYours ? "your seat" : "\(rsvp.displayName)'s seat"
        let seat = BroughtBy.seatLabel(
            name: owner,
            anchorName: roomService.anchorName(forUserId: rsvp.memberId, roomId: roomId),
            enabled: roomService.cachedShowBroughtBy(roomId: roomId)
        )
        return "\(seat), claimed"
    }
}

// MARK: - Witness slot (at-play)

private struct WitnessSlot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// M1.1 — header title differentiates `.tonightEvent`
    /// ("The night has started") from `.inPlay`
    /// ("The game is on"). The same `WitnessSlot`
    /// component renders both — only the title changes.
    enum HeaderMode { case inPlay, tonightEvent }

    /// S1.4 — one line of the night plan. The primary renders as the
    /// full-width accent button (or a grey caption when it is a
    /// state, not an action); secondaries render as grey caption
    /// text centred under it, the same styling as "Can't make it".
    struct Line {
        enum Style: Equatable { case button, caption }
        let title: String
        let style: Style
        /// Grey caption directly above the primary (the check-in
        /// explainer). Ignored on secondaries.
        var lead: String? = nil
        var action: () -> Void = {}
        /// fx30 — the VoiceOver label when it differs from the title
        /// (the host's "Score a round" reads "(host)" so the sweep and
        /// VoiceOver can tell it apart).
        var a11yLabel: String? = nil
    }

    let event: Event
    let attestations: [OpenAttestationSummary]
    /// S1.4 — the one thing to do next. `nil` renders no action.
    let primary: Line?
    /// S1.4 — every other action, grey and quiet.
    let secondaries: [Line]
    let isHero: Bool
    var headerMode: HeaderMode = .inPlay
    /// V0.46 — working hand (withdrawn chips) surfaced in the
    /// hero badge. nil = don't render (CAH / not-yet-withdrawn).
    var workingHand: Int? = nil
    /// V0.72 (072) — the current member has already scanned their
    /// chips this session.
    var hasScanned: Bool = false
    /// V0.72 (072) — the member's latest scanned value, when known.
    var scannedValue: Int? = nil
    /// S1.5 — grey caption under the primary ("Couldn't settle.
    /// Try again.").
    var note: String? = nil
    /// P2 (audit 03 C2) — when set, the note is the retry: the same
    /// grey line, tappable. nil keeps it plain text.
    var noteAction: (() -> Void)? = nil
    /// Tonight's chip board. nil hides the block.
    var tonight: TonightScore? = nil
    var currentUserId: UUID? = nil

    var body: some View {
        // v1.2.2 S6 T7 — same rule `BriefingSlot` follows (S6 T2):
        // the card body is ONE stack on two spacing steps and
        // nothing else. Groups (header, working-hand badge, the
        // attestation rows, the primary CTA, each secondary CTA)
        // sit `cardGroupGap` apart; lines that belong together
        // inside a group sit `cardLineGap`. The ad-hoc
        // `.padding(.top, N)` nudges that used to sit at those
        // group boundaries are gone — this stack's spacing is the
        // only gap a group boundary gets.
        //
        // The header is ONE line today ("The night has started",
        // "The game is on", "Count what's on the table"), so it has
        // no `cardLineGap` step to show. It rides the full card
        // width, leading-aligned, exactly where a multi-line
        // header block would start.
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            Text(headerTitle)
                .font(Theme.Typography.title.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                // v1.2.4 S4.7 — the pill is gone. The live card carries
                // no chips: the state is a plain accent caption, so its
                // text starts on the card's leading edge like every
                // other line in the card.
                if hasScanned, let scannedValue, scannedValue == workingHand {
                    // icon and its own label belong together, so
                    // they sit `cardLineGap` apart (was an ad-hoc 6).
                    HStack(spacing: Theme.Layout.cardLineGap) {
                        Image(systemName: Theme.Icon.checkmarkCircleFill)
                        Text("Cashed out: \(scannedValue) in chips")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityLabel(Text("Cashed out with \(scannedValue) in chips"))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                } else {
                    HStack(spacing: Theme.Layout.cardLineGap) {
                        Image(systemName: Theme.Icon.handPointUpFill)
                        Text("Chips in hand: \(workingHand)")
                    }
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityLabel(Text("Chips in hand: \(workingHand)"))
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }

            if let tonight {
                TonightBoard(score: tonight, currentUserId: currentUserId)
            }

            if !attestations.isEmpty {
                // v1.2.4 S4.7 — the readings are list rows, the same
                // shape as the system banner: each one takes the
                // page's `roomRowInset`, a hairline separates two of
                // them, and the stack's own spacing is 0 so the
                // hairline touches neither row.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(attestations) { s in
                        HStack(spacing: Theme.Layout.cardLineGap) {
                            Text(s.contextLabel)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Spacer()
                            Text(s.visionAmountPoints >= 0 ? "+\(s.visionAmountPoints)" : "\(s.visionAmountPoints)")
                                .font(Theme.Typography.mono)
                                .foregroundStyle(s.visionAmountPoints >= 0 ? Theme.Palette.accent : Theme.Palette.secondaryText)
                        }
                        .padding(.vertical, Theme.Layout.roomRowInset)
                        if s.id != attestations.last?.id {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
            }

            if let primary {
                VStack(spacing: Theme.Layout.cardLineGap) {
                    if let lead = primary.lead {
                        Text(lead)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    switch primary.style {
                    case .button:
                        Button(action: primary.action) {
                            Text(primary.title)
                                .font(Theme.Typography.body.weight(.semibold))
                                .foregroundStyle(Theme.Palette.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.Palette.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .contentTransition(.opacity)
                                .animation(Theme.Motion.fade, value: primary.title)
                        }
                        .pressScale()
                        // fx30 — the primary keeps the line's own
                        // VoiceOver label (the host's "(host)").
                        .accessibilityLabel(Text(primary.a11yLabel ?? primary.title))
                    case .caption:
                        Text(primary.title)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(Text(primary.title))
                    }
                }
            }

            if let note {
                if let noteAction {
                    // P2 — a failed settle's line is the retry, so it is
                    // a button that looks exactly like the caption.
                    Button(action: noteAction) {
                        Text(note)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(note)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }

            // S1.4 — secondaries: grey caption text centred under
            // the primary, never a second tinted button (02-workflows
            // #19).
            if !secondaries.isEmpty {
                VStack(spacing: Theme.Layout.cardLineGap) {
                    ForEach(secondaries.indices, id: \.self) { i in
                        let line = secondaries[i]
                        Button(action: line.action) {
                            Text(line.title)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.secondaryText)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .disabled(line.style == .caption)
                        // fx30 — a line may carry its own VoiceOver
                        // label (the host's "Score a round (host)").
                        .accessibilityLabel(Text(line.a11yLabel ?? line.title))
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // v1.2.4 S4.4 — one card shape, same change as the briefing
        // card above: the live card's own radius-14 / 1pt-stroke
        // chrome is gone and the card is a `sectionCard` like every
        // other card on the page.
        .sectionCard(isHero ? .hero : .standard)
        .appearTransition()
        // V0.70 — drive the working-hand badge pop-in and the
        // secondary CTAs' fade-in from one place. Closures aren't
        // Equatable, so the secondary CTAs track the Bool of the
        // optional, not the closure itself.
        .animation(reduceMotion ? Theme.Motion.fade : Theme.Motion.popIn, value: workingHand)
        .animation(Theme.Motion.fade, value: secondaries.map(\.title))
    }

    /// M1.1 — copy variant for the witness header. Each variant
    /// carries the V0.8 brief's intent: `.tonightEvent` is
    /// play-just-started (no withdrawals yet), `.inPlay` is the
    /// canonical mid-game copy.
    private var headerTitle: String {
        switch headerMode {
        case .inPlay:       return "The game is on"
        case .tonightEvent: return "The night has started"
        }
    }
}

// MARK: - Tonight's board (the live card's scoreboard)

/// Who is up tonight, in chips, on the live card everyone at the table
/// looks at. The headline answers the question out loud ("Alex is up
/// 40"); each row says where that player is: a net once they have
/// cashed out, "Playing" while their chips are on the table.
private struct TonightBoard: View {
    let score: TonightScore
    let currentUserId: UUID?
    /// The recap's version: "How the night went", cashed-out rows only.
    var isFinal: Bool = false

    private var rows: [TonightScore.Row] {
        isFinal ? score.cashedOut : score.rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: isFinal ? "How the night went" : "Tonight")
                Spacer()
                if !isFinal, let progress = score.progressCaption {
                    Text(progress)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            HStack(spacing: Theme.Layout.cardLineGap) {
                if !score.leaders.isEmpty {
                    Image(systemName: Theme.Icon.crownFill)
                        .accessibilityHidden(true)
                }
                Text(score.headline)
            }
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(score.leaders.isEmpty ? Theme.Palette.primaryText : Theme.Palette.accent)
            .contentTransition(.opacity)
            if !rows.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().overlay(Theme.Palette.hairline) }
                        boardRow(row)
                    }
                }
            }
        }
        .animation(Theme.Motion.fade, value: score)
    }

    private func boardRow(_ row: TonightScore.Row) -> some View {
        let isLeader = score.leaders.contains(row)
        return HStack(spacing: Theme.Layout.cardInset) {
            Text(row.name)
                .font(Theme.Typography.body.weight(isLeader ? .semibold : .regular))
                .foregroundStyle(Theme.Palette.primaryText)
                .lineLimit(1)
            if row.memberId == currentUserId {
                Text("you")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Palette.accent)
            }
            Spacer()
            switch row.status {
            case .cashedOut(let net):
                Text(net > 0 ? "+\(net)" : net < 0 ? "−\(-net)" : "0")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(net > 0 ? Theme.Palette.scoreUp : net < 0 ? Theme.Palette.scoreDown : Theme.Palette.secondaryText)
                    .contentTransition(.numericText())
            case .playing:
                Text("Playing")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            case .noChips:
                Text("No chips yet")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.tertiaryText)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText(row, isLeader: isLeader)))
    }

    private func accessibilityText(_ row: TonightScore.Row, isLeader: Bool) -> String {
        switch row.status {
        case .cashedOut(let net):
            let amount = net >= 0 ? "up \(net)" : "down \(-net)"
            return "\(row.name), cashed out, \(amount) tonight\(isLeader ? ", leading" : "")"
        case .playing:
            return "\(row.name), still playing"
        case .noChips:
            return "\(row.name), no chips yet"
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
    var currentUserId: UUID? = nil
    /// "Hosted by Nathan".
    var hostedBy: String? = nil
    /// How the night went, once anyone cashed out. nil hides it.
    var results: TonightScore? = nil
    /// 1.2.5 — how the recap ends: the next night, the host's
    /// "Same time next Tuesday?", or "Plan the next night".
    var closing: RecapClosing = .none
    /// A failed booking's one line, shown over the prompt (the retry).
    var closingNote: String? = nil
    var onBookSameTime: ((NextNightOffer) -> Void)? = nil
    var onPickAnotherTime: ((NextNightOffer) -> Void)? = nil
    var onPlanNextNight: (() -> Void)? = nil
    var onClaimNextSeat: (() -> Void)? = nil

    /// V0.84 C2 — host-only. Presents `TonightStarCallSheet`.
    @State private var showingCallSheet = false

    /// V0.84 C5 — local UI state for the one-line drop text field.
    @State private var memberNoteDraft: String = ""

    /// Settled date and next-episode teaser on ONE caption tier,
    /// so the header stops saying the same thing in two type sizes.
    /// `nil` when the event has neither.
    private var settledCaption: String? {
        // The recap only lives for a day, so "settled 30 minutes ago"
        // was bookkeeping. It says whose night it was instead.
        var parts: [String] = []
        if let hostedBy {
            parts.append("Hosted by \(hostedBy)")
        }
        if let teaser = chapterLine?.nextEpisodeTeaser, !teaser.isEmpty {
            parts.append("Next: \(teaser)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// V0.84 C2 — host-only. `nil` unless the host actually has a
    /// pick to make; drives whether "Make a call" renders at all.
    private var canMakeACall: Bool {
        isHost && onTonightStarPick != nil && !hostPickMembers.isEmpty
    }

    /// V0.84 C2 — host-only caption-size action that opens
    /// `TonightStarCallSheet`. Rendered inside `TonightStarSection`'s
    /// label row when there is a star, on its own trailing row when
    /// there isn't. No chrome of its own — same type scale, same grey.
    ///
    /// v1.2.4 S4.3 — the trailing chevron is gone and the action is
    /// the app's one secondary style: a centred grey caption, no
    /// chrome. The `make-a-call` identifier stays for the UI sweep.
    private var makeACallAction: (() -> Void)? {
        guard canMakeACall else { return nil }
        return { showingCallSheet = true }
    }

    private var makeACallButton: some View {
        SecondaryTextAction(title: "Make a call") { showingCallSheet = true }
            .accessibilityIdentifier("make-a-call")
    }

    /// V0.84 C5 — the one-line drop renders for a member once the
    /// next-morning window is open and they have not answered it.
    private var showsMemberNote: Bool {
        !isHost && memberNoteWindowOpen && memberNotePromptVisible
            && onSubmitMemberNote != nil && onSkipMemberNote != nil
    }

    /// 1.2.5 — the recap's blocks, in order.
    private var sections: [RecapSection] {
        RecapLayout.placingGlad(in: RecapLayout.sections(
            star: RecapLayout.star(for: tonightStarCard),
            canMakeACall: canMakeACall,
            hasResults: !(results?.cashedOut.isEmpty ?? true),
            showsMemberNote: showsMemberNote,
            closing: closing
        ))
    }

    @ViewBuilder
    private func sectionView(_ section: RecapSection) -> some View {
        switch section {
        case .star:
            // Tonight's Star: the host's pick (or the chip-swing
            // winner) and their line. The host's "Make a call" rides
            // the label row so the quote gets the full card width.
            if let card = tonightStarCard {
                VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
                    TonightStarSection(card: card, onMakeACall: makeACallAction)
                    // S3 T3 — the foot line only earns its place when
                    // it says something the name above it doesn't.
                    if !card.heroFootLine.contains(card.memberDisplayName) {
                        Text(card.heroFootLine)
                            .font(Theme.Typography.caption.italic())
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                }
            }
        case .makeACall:
            // v1.2.4 S4.3 — with no star to sit beside, the action is
            // the app's one secondary style on its own row.
            makeACallButton
        case .glad:
            // 1.2.5 Task 4: "Glad you came", under Tonight's Star.
            GladYouCameSection(event: event, viewerId: currentUserId)
        case .results:
            if let results {
                TonightBoard(score: results, currentUserId: currentUserId, isFinal: true)
            }
        case .memberNote:
            // V0.84 C5 — member-only, next-morning window (≥12h after
            // settle), not yet answered. A self-contained subview.
            if let onSubmitMemberNote, let onSkipMemberNote {
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
        case .closing:
            closingView
        }
    }

    /// 1.2.5 — the recap's last line. One primary at most, and at most
    /// one grey caption under it.
    @ViewBuilder
    private var closingView: some View {
        switch closing {
        case .nextNight(let line, let claim):
            VStack(spacing: Theme.Layout.cardLineGap) {
                Text(line)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("recap-next-night")
                if claim, let onClaimNextSeat {
                    SecondaryTextAction(title: RecapClosing.claimYourSeat, action: onClaimNextSeat)
                        .accessibilityIdentifier("recap-claim-seat")
                }
            }
        case .bookSameTime(let offer):
            VStack(spacing: Theme.Layout.cardLineGap) {
                if let closingNote {
                    Text(closingNote)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { onBookSameTime?(offer) } label: {
                    Text(offer.prompt)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .pressScale()
                .accessibilityIdentifier("same-time-next-week")
                SecondaryTextAction(title: NextNightOffer.pickAnotherTime) {
                    onPickAnotherTime?(offer)
                }
                .accessibilityIdentifier("pick-another-time")
            }
        case .planNextNight:
            Button { onPlanNextNight?() } label: {
                Text(RecapClosing.planNextNightTitle)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .pressScale()
        case .none:
            EmptyView()
        }
    }

    var body: some View {
        // v1.2.2 S6 T7 — the card rhythm `BriefingSlot` uses (S6 T2):
        // groups (header block, Tonight's Star, the one-line drop,
        // the mascot foot line) sit `cardGroupGap` apart, and the
        // lines that belong together inside the header block sit
        // `cardLineGap` apart. The ad-hoc `20` / `6` are gone — this
        // stack's spacing is the only gap a group boundary gets.
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            // (1) header block — title and the settled-date / teaser
            // caption, which read as one caption tier.
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text(chapterLine?.title ?? event.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.primaryText)

                if let settledCaption {
                    Text(settledCaption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)

            // 1.2.5 — the recap's order is `RecapLayout` (peak-end):
            // the host's Tonight's Star first, the cash-out results as
            // they are (loss stays real), and the next night last, so
            // the night is remembered by a person and by what comes
            // next rather than by a number.
            // Keyed by section, not position: the Glad section holds a
            // live Undo and must survive results arriving above it.
            ForEach(sections, id: \.self) { section in
                sectionView(section)
            }
        }
        .sheet(isPresented: $showingCallSheet) {
            if let onTonightStarPick {
                TonightStarCallSheet(
                    members: hostPickMembers,
                    currentCard: tonightStarCard,
                    onSave: onTonightStarPick
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
/// Renders the winner (display name) plus the host's `custom_text`
/// when present. The category line (mascot voice, or the plain
/// chip-swing fallback) sits at the card's foot via `heroFootLine`.
private struct TonightStarSection: View {
    let card: TonightStarCard
    /// V0.84 C2 — host-only. When non-nil, "Make a call" rides
    /// trailing on the label row so the quote below keeps the full
    /// card width. `nil` for members and for a host with nobody to
    /// pick.
    var onMakeACall: (() -> Void)?

    var body: some View {
        // v1.2.4 S4.6 — the section's header is now the app's
        // `SectionTitle` (one header style for every section), and the
        // card's lines sit `cardLineGap` apart.
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Tonight's Star")
                if let onMakeACall {
                    Spacer(minLength: 12)
                    // v1.2.4 S4.3 — the trailing chevron is gone: the
                    // action wears the app's one secondary look (grey
                    // caption, no chrome) whether it rides this label
                    // row or stands on its own.
                    Button(action: onMakeACall, label: {
                        Text("Make a call")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .multilineTextAlignment(.center)
                    })
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("make-a-call")
                }
            }
            HStack(spacing: Theme.Layout.cardLineGap) {
                Image(systemName: "star.fill")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent)
                    .accessibilityHidden(true)
                Text(card.memberDisplayName)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
            }
            .accessibilityElement(children: .combine)
            if let custom = card.customText, !custom.isEmpty {
                Text("“\(custom)”")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.bodyMuted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // `.contain` rather than `.combine`: the label row now hosts
        // the host's "Make a call", and combining would fold that
        // button out of the accessibility tree.
        .accessibilityElement(children: .contain)
    }
}

private extension TonightStarCard {
    var heroFootLine: String {
        if let category = overrideCategory {
            return category.mascotLine(winnerName: memberDisplayName)
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
        // v1.2.4 S4.6 — the prompt's groups sit `cardGroupGap` apart,
        // the field takes the app's `fieldInset`, and Send is the
        // app's one primary button with Skip as the grey caption
        // under it.
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            Text("Anything you want the room to know next time?")
                .font(Theme.Typography.body.italic())
                .foregroundStyle(Theme.Palette.labelText)
            TextField(
                "",
                text: $draft,
                prompt: Text("One line for the host")
                    .foregroundStyle(Theme.Palette.tertiaryText)
            )
            .textFieldStyle(.plain)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText)
            .padding(Theme.Layout.fieldInset)
            .overlay(RoundedRectangle(cornerRadius: Theme.Layout.smallRadius).stroke(Theme.Palette.hairline, lineWidth: 0.5))
            VStack(spacing: 0) {
                Button(action: onSubmit) {
                    Text("Send")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                // v1.2.4 S4.3 — the skip wears the app's one secondary
                // look: a grey caption, no chrome.
                // v1.2.4 S4.6 — it now sits under the primary button,
                // which is where the app's one secondary-action shape
                // lives.
                SecondaryTextAction(title: "Skip", action: onSkip)
            }
        }
    }
}

// MARK: - Tonight's Star call sheet (V0.84 C2 host)

/// V0.84 C2 — host-only. "Make a call" on the ceremonial card opens
/// this sheet: pick a member, pick a reason (custom needs a line),
/// Save. Mirrors `PackPayoutSheet`'s shape (NavigationStack + Form +
/// Cancel/Save toolbar).
private struct TonightStarCallSheet: View {
    let members: [Member]
    let onSave: (UUID, TonightStarOverrideCategory, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var memberId: UUID?
    @State private var category: TonightStarOverrideCategory
    @State private var customText: String

    init(members: [Member], currentCard: TonightStarCard?, onSave: @escaping (UUID, TonightStarOverrideCategory, String?) -> Void) {
        self.members = members
        self.onSave = onSave
        let current = members.first { $0.userId == currentCard?.memberId }
            ?? members.first { $0.displayName == currentCard?.memberDisplayName }
        _memberId = State(initialValue: current?.userId)
        _category = State(initialValue: currentCard?.overrideCategory ?? .bestPlay)
        _customText = State(initialValue: currentCard?.customText ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Member") {
                    Picker("Member", selection: $memberId) {
                        ForEach(members, id: \.userId) { member in
                            Text(member.displayName).tag(Optional(member.userId))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section("Reason") {
                    Picker("Reason", selection: $category) {
                        ForEach(TonightStarOverrideCategory.allCases, id: \.self) { cat in
                            Text(cat.shortLabel).tag(cat)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if category == .custom {
                        TextField("Custom line", text: $customText)
                    }
                }
            }
            .textCase(nil)
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Tonight's Star")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let memberId else { return }
                        onSave(memberId, category, category == .custom ? trimmedCustomText : nil)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    private var trimmedCustomText: String {
        customText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        memberId != nil && (category != .custom || !trimmedCustomText.isEmpty)
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
        // v1.2.4 S4.6 — the card's rhythm. Groups sit `cardGroupGap`
        // apart (the card's own inset token, `cardInset`, was being
        // used as a gap and made them 20 apart), the header's two
        // lines sit `cardLineGap` apart, and the four ad-hoc 4pt
        // bumps are gone: the stack's spacing owns the rhythm now.
        VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text("Season \(season.ordinal) is closed")
                    .font(Theme.Typography.title.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                if !season.subtitle.isEmpty {
                    Text(season.subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }

            if sortedAwards.isEmpty {
                Text("Awards haven't been declared yet.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.secondaryText)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sortedAwards.enumerated()), id: \.element.id) { idx, award in
                        awardView(for: award, at: idx)
                        if idx != sortedAwards.count - 1 {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                                // Start the hairline under the row
                                // text, past the icon column, so the
                                // award names and the rule share a
                                // left edge.
                                .padding(.leading, Theme.Layout.rowIconWidth + Theme.Layout.cardInset)
                        }
                    }
                }
            }

            // V0.53 — share the member's own stat card. The card is
            // generated on the member's device and shared through the
            // system share sheet; the app never broadcasts it.
            if let statCard {
                let cardImage = renderImage(for: statCard)
                ShareLink(
                    item: ShareableImage(image: cardImage),
                    preview: SharePreview(
                        "\(statCard.memberName), Season \(statCard.seasonOrdinal)",
                        image: Image(uiImage: cardImage)
                    )
                ) {
                    Label("Share my season card", systemImage: "square.and.arrow.up")
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }

            if let endedAt = season.endedAt {
                Text("Closed \(endedAt, format: .relative(presentation: .named))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: Theme.Layout.cardInset) {
            Image(systemName: symbol)
                .font(Theme.Typography.body)
                .foregroundStyle(award.awardType.isPrivate
                    ? Theme.Palette.secondaryText
                    : Theme.Palette.accent)
                .frame(width: Theme.Layout.rowIconWidth)
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                HStack(spacing: Theme.Layout.cardLineGap) {
                    Text(award.recipientDisplayName)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("·")
                        .foregroundStyle(Theme.Palette.tertiaryText)
                    Text(award.awardType.displayName)
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(award.awardType.isPrivate
                            ? Theme.Palette.secondaryText
                            : Theme.Palette.accent)
                }
                if let caption = award.caption, !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
            }
            Spacer()
        }
        // v1.2.4 S4.6 — the award row takes the page's row inset
        // (`roomRowInset`), the same as every other list row.
        .padding(.vertical, Theme.Layout.roomRowInset)
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
        // v1.2.4 S4.6 — the banner's rows are list rows: each one takes
        // the page's `roomRowInset`, the icon sits `cardInset` from its
        // text, and the row's two lines sit `cardLineGap` apart. The
        // stack's own spacing is 0 so the hairline between two rows
        // touches neither of them.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(events) { event in
                HStack(spacing: Theme.Layout.cardInset) {
                    Image(systemName: iconFor(event.kind))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.secondaryText)
                    VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                        Text(event.kind.displayName)
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(payloadDescription(for: event))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                    }
                    Spacer()
                    Button {
                        onDismiss(event.id)
                    } label: {
                        Image(systemName: Theme.Icon.xmark)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .accessibilityLabel(Text("Dismiss"))
                }
                .padding(.vertical, Theme.Layout.roomRowInset)
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
        // v1.2.4 S4.6 — one header style for every section: the title
        // is the app's `SectionTitle`, and it sits `roomHeaderGap`
        // above its first row.
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(text: "Hand out chips")
                .padding(.bottom, Theme.Layout.roomHeaderGap)

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

    /// One quiet line per player waiting on chips: "Alex 200" and a
    /// plain "Handed over" the host taps once the chips are in their
    /// hands. It sits under the live card, so it never out-shouts it.
    private func row(txn: EventTransaction) -> some View {
        HStack(spacing: Theme.Layout.cardInset) {
            Text(txn.memberDisplayName)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText)
            Text("\(abs(txn.amountPoints))")
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.secondaryText)
            Spacer()
            Button {
                Haptics.light()
                onDispense(txn.id)
            } label: {
                Text("Handed over")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Handed \(txn.memberDisplayName) \(abs(txn.amountPoints)) in chips"))
        }
        .padding(.vertical, Theme.Layout.cardLineGap)
    }
}

// MARK: - Standings section (always-on, below the slot)

/// Slice 2a (Hearth) — the flat section title: small, grey,
/// sentence case. Hierarchy comes from type, not a card.
struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typography.caption.weight(.semibold))
            .foregroundStyle(Theme.Palette.labelText)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct StandingsSection: View {
    let entries: [LeaderboardEntry]
    let currentUserId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The two numbers on every row are labelled once, here,
            // over their own columns: what you won or lost the last
            // night you played, and your season total.
            HStack(alignment: .firstTextBaseline, spacing: Theme.Layout.cardInset) {
                SectionTitle(text: "Standings")
                Spacer()
                HStack(spacing: Theme.Layout.cardLineGap) {
                    Text("Last time")
                        .frame(width: LeaderboardRow.deltaColumnWidth, alignment: .trailing)
                    Text("Season")
                        .frame(minWidth: LeaderboardRow.scoreColumnWidth, alignment: .trailing)
                }
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Palette.secondaryText)
                .accessibilityHidden(true)
                Color.clear.frame(width: LeaderboardRow.chevronWidth, height: 1)
            }
            .padding(.bottom, Theme.Layout.roomHeaderGap)
            ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                if idx > 0 { Divider().overlay(Theme.Palette.hairline) }
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

// MARK: - How scoring works (chips)

/// The whole scoring system in three lines, on the room page where
/// a first-timer can find it. Every night runs the same loop: take
/// chips, play anything (winners are paid in chips), scan your chips
/// at the end. The host's one setting is what each chip colour is
/// worth.
private struct ChipRulesSection: View {
    let room: Room
    @EnvironmentObject private var casinoService: CasinoService
    @State private var editor: PackEditor?

    private var isHost: Bool { room.userRole == .host }

    private let steps: [(icon: String, title: String, detail: String)] = [
        (Theme.Icon.handPointUpFill, "Take your chips", "Everyone takes chips from the bank when they arrive."),
        (Theme.Icon.crownFill, "Play anything", "Any game you like. Winners get paid out in chips."),
        (Theme.Icon.checkmarkCircleFill, "Cash out", "At the end, scan the chips in front of you. What you won or lost goes into the standings."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                if index > 0 { Divider().overlay(Theme.Palette.hairline) }
                HStack(alignment: .top, spacing: Theme.Layout.cardInset) {
                    Text("\(index + 1)")
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: Theme.Layout.rowIconWidth, alignment: .leading)
                    VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                        Text(step.title)
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text(step.detail)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Theme.Layout.roomRowInset)
                .accessibilityElement(children: .combine)
            }
            if isHost {
                Divider().overlay(Theme.Palette.hairline)
                Button {
                    editor = .casinoConfig
                } label: {
                    HStack(spacing: Theme.Layout.cardInset) {
                        Image(systemName: Theme.Icon.sliderHorizontal3)
                            .foregroundStyle(Theme.Palette.secondaryText)
                            .frame(width: Theme.Layout.rowIconWidth, alignment: .leading)
                        Text("Chip values")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Image(systemName: Theme.Icon.chevronRight)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(.vertical, Theme.Layout.roomRowInset)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text("Set what each chip colour is worth"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editor) { item in
            switch item {
            case .casinoConfig:
                RoomSettingsCasinoSheet(roomId: room.id, showsDoneButton: true)
                    .environmentObject(casinoService)
            }
        }
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
    /// member to share. `nil` until the Members plus is tapped.
    @Binding var inviteCode: String?
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
        VStack(alignment: .leading, spacing: 0) {
            if hasInviteContent {
                inviteSection
                Divider().overlay(Theme.Palette.hairline)
            }
            let members = roomService.cachedMembers(roomId: room.id)
            if members.isEmpty {
                Text("No members yet. Share your join code to get the table set.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .padding(.vertical, Theme.Layout.roomRowInset)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { idx, member in
                        memberRow(member)
                        if idx != members.count - 1 {
                            Divider().overlay(Theme.Palette.hairline)
                        }
                    }
                }
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

    /// Whether anything sits above the roster: a reward, a minted
    /// code, the host's tier-2 queue or the member's tier-3 field.
    private var hasInviteContent: Bool {
        if let rewards = inviteRewards, rewards.friendsJoined > 0 { return true }
        if inviteCode != nil { return true }
        if isHost {
            return roomService.cachedMembers(roomId: room.id).contains { $0.inviteTier == 2 }
        }
        return !otherRoomMembers().isEmpty
    }

    /// V0.55 — the invite affordance on the roster. The mint itself
    /// is the Members header plus (v1.2.1). Host sees the tier-2
    /// approval queue (one-tap remove); member sees a tier-3
    /// invitee-scoped code field.
    @ViewBuilder
    private var inviteSection: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        .font(Theme.Typography.monoSemibold)
                        .foregroundStyle(Theme.Palette.accent)
                    Spacer()
                    // V0.76 — native share sheet with a prefilled
                    // message, so inviting is one tap (not copy-paste).
                    ShareLink(
                        item: "Join me in Games Room. Use code \(code) to get 200 pts to start!",
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
                        // S3.6 — this button copies, so it wears the
                        // copy mark. It used to wear a plus circle,
                        // which read as "mint another code".
                        Image(systemName: "doc.on.doc")
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .accessibilityLabel(Text("Copy invite code"))
                }
                .padding(.vertical, 12)
            }

            if isHost {
                tierTwoApprovalQueue
            } else {
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
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text("Your invite paid off")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(rewards.friendsJoined == 1
                     ? "1 friend joined, +\(rewards.totalReward) pts"
                     : "\(rewards.friendsJoined) friends joined, +\(rewards.totalReward) pts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 12)
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
                    .foregroundStyle(Theme.Palette.secondaryText)
                ForEach(tierTwo) { member in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(member.displayName)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            // V0.107 — "via Alex" under the name, so
                            // the host can place a newcomer before
                            // they say anything (spec §2, A6). The
                            // same grey as the briefing caption, and
                            // gone with the room switch (A7). nil
                            // when nobody brought them.
                            if let via = BroughtBy.viaLabel(
                                anchorName: roomService.anchorName(for: member, roomId: room.id),
                                enabled: roomService.cachedShowBroughtBy(roomId: room.id)
                            ) {
                                Text(via)
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.secondaryText)
                            }
                        }
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
            .padding(.vertical, 12)
        }
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
                    .foregroundStyle(Theme.Palette.secondaryText)
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
                            .foregroundStyle(inviteeUserId == nil ? Theme.Palette.secondaryText : Theme.Palette.primaryText)
                        Spacer()
                        Image(systemName: Theme.Icon.chevronDown)
                            .accessibilityHidden(true)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Palette.tertiaryText)
                    }
                    .padding(.vertical, 12)
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
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Layout.buttonRadius))
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
        HStack(spacing: Theme.Layout.cardInset) {
            // Avatar placeholder — the V0.8 brief deliberately
            // surfaces a monogram (initials) rather than a photo so
            // the roster renders without a media dependency.
            Circle()
                .fill(Theme.Palette.accent.opacity(0.18))
                .frame(width: Theme.Layout.rowIconWidth, height: Theme.Layout.rowIconWidth)
                .overlay(
                    Text(initials(for: member.displayName))
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                )
            VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
                Text(member.displayName)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(member.role == .host ? "Host" : "Member")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, Theme.Layout.roomRowInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(member.displayName), \(member.role == .host ? "host" : "member")"))
    }

    private func initials(for name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }
}

// MARK: - Collapsible section (V0.40)

/// v1.2.2 S6 T6 — one header style for every room-page section.
/// Packs and Members print their title with `SectionTitle`, exactly
/// as Standings and Seasons print theirs, sit the same distance above
/// their content (`roomHeaderGap`), and put their trailing controls on
/// the title's row. The grey sentence that used to sit under the title
/// is gone from the page; it is not deleted — it moved into the
/// toggle's accessibility hint, so it is still read out.
private struct CollapsibleSection<Content: View, Accessory: View>: View {
    let title: String
    /// v1.2.2 S6 T6 — no longer rendered. Kept as the toggle's
    /// accessibility hint so the section keeps its one-line
    /// description for anyone who cannot see the header.
    let caption: String
    @Binding var isExpanded: Bool
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(
        title: String,
        caption: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.caption = caption
        self._isExpanded = isExpanded
        self.accessory = accessory()
        self.content = content()
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.roomHeaderGap) {
            // v1.2.2 S6 T6 — trailing controls sit centred on the
            // title's row, the same row Standings and Seasons use.
            // (They used to sit on the title's baseline, which only
            // lined up while the header still carried a second line.)
            HStack(alignment: .center, spacing: 12) {
                Button(action: toggle) {
                    HStack(alignment: .center) {
                        SectionTitle(text: title)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(title))
                .accessibilityHint(hint)

                accessory

                Button(action: toggle) {
                    Image(systemName: isExpanded ? Theme.Icon.chevronUp : Theme.Icon.chevronDown)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Palette.tertiaryText)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .accessibilityHidden(true)
            }

            if isExpanded {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// v1.2.2 S6 T6 — "Tap to expand/collapse" was the whole hint,
    /// which left the caption with nowhere to live once the visible
    /// line came off. It rides along here instead of being deleted.
    private var hint: Text {
        let action = isExpanded ? "Tap to collapse." : "Tap to expand."
        guard !caption.isEmpty else { return Text(action) }
        return Text("\(action) \(caption)")
    }
}

// MARK: - Members section (v1.2.1)

/// Members with the invite as a plus on the header. Owns the minted
/// code so the plus can open the section and show it in one tap.
private struct MembersSection: View {
    let room: Room
    @EnvironmentObject private var roomService: RoomService
    @State private var isExpanded = false
    @State private var inviteCode: String?
    @State private var inviteError: String?
    @State private var showInviteError = false

    var body: some View {
        CollapsibleSection(
            title: "Members",
            caption: "Everyone with a seat at the table.",
            isExpanded: $isExpanded,
            accessory: {
                Button(action: invite) {
                    Image(systemName: Theme.Icon.plus)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // v1.2.2 S6 T6 — still full 44pt tap target, but
                // only the glyph's height counts toward the header,
                // so Members' row is as tall as Packs' now that both
                // are one title line.
                .padding(.vertical, -16)
                .accessibilityLabel(Text("Invite a friend"))
                .accessibilityIdentifier("members-invite")
            }
        ) {
            MemberRosterReadOnly(room: room, inviteCode: $inviteCode)
        }
        .alert("Invite failed", isPresented: $showInviteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(inviteError ?? "")
        }
    }

    /// The pre-1.2.1 "Invite a friend" row's action, unchanged: mint
    /// a code (tier 1 for the host, tier 2 for a member). Opens the
    /// section so the code row is on screen.
    private func invite() {
        withAnimation(.easeInOut(duration: 0.18)) { isExpanded = true }
        Task {
            do {
                inviteCode = try await roomService.generateInviteCode(roomId: room.id, inviteeUserId: nil)
            } catch {
                inviteError = error.localizedDescription
                showInviteError = true
            }
        }
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
        // V0.95 C — give the voice a face. The footer caption is
        // Tally's line; the face beside it is Tally's expression,
        // computed from the SAME room-state resolution the caption
        // flavour comes from (V0.94 hard invariant #2: voice and
        // face agree). Async surface only — the footer is the
        // sanctioned placement per the V0.94 spec; never rendered
        // inside an in-play control surface.
        HStack(alignment: .top, spacing: 10) {
            MascotFaceView(
                parameters: MascotFaceEngine.compute(
                    personality: room.mascotPersonality,
                    ideology: room.mascotPoliticalIdeology,
                    state: resolvedRoomState
                ),
                size: Self.faceSize
            )
            .accessibilityLabel(Text(
                "\(room.mascotName) the mascot, \(resolvedRoomState.rawValue) room state"
            ))

            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
                // 2026-08-10 feedback round — the caption was cut off at
                // one line. The mascot comment is the room's voice; let
                // it wrap so the whole comment is readable.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // V0.70 — the mascot "speaks" when its caption changes.
        // `.id(caption)` forces SwiftUI to treat each new line
        // as a different view so the transition fires; the
        // attached fade animation drives the cross-fade. The face
        // participates in the same transition (whole unit fades),
        // which also covers the room-state changes that drive it.
        .id(caption)
        .transition(.opacity.combined(with: .offset(y: 4)))
        .animation(Theme.Motion.fade, value: caption)
        // V0.81 — kick the LLM task whenever the snapshot the
        // caption depends on changes. The id collapses to the
        // same string for a given (kind, members, leaderboard,
        // withdrawn) tuple, so SwiftUI only re-fires the task
        // when something actually shifts — not on every parent
        // re-render.
        //
        // V0.95 — no nil-reset: the previous LLM caption stays
        // visible while the new one generates, and swaps in-place
        // only when it differs (cross-fade above). A nil reset
        // here caused a template-flash on every state tick —
        // reads as flicker during live events.
        .task(id: footerTaskKey) {
            await refreshLLMCaption()
        }
    }
    /// V0.95 C — footer face render size. Small enough to sit
    /// beside a wrapping caption without dominating the column;
    /// large enough (≥ avatar threshold) that the brow
    /// calligraphy reads without the avatar-scale widening.
    private static let faceSize: CGFloat = 48

    /// V0.95 C — the `RoomState` the footer face renders against.
    /// Derived from the same live data the caption's `footerKind`
    /// uses (active event, leaderboard, working hand), plus the
    /// event rounds for comeback/streak flavour. Mirrors
    /// `MascotFaceEngine`'s resolver ordering. Pure; recomputed on
    /// re-render — the engine is total + deterministic, so this is
    /// cheap. Voice and face agree because both read this one
    /// resolution of the room.
    private var resolvedRoomState: RoomState {
        // Dispute surface doesn't reach the footer's data plane;
        // nothing here can open one. Documented non-input.
        let openDispute = false

        let rounds = activeEvent.map {
            roomService.cachedEventRounds(eventId: $0.id)
        } ?? []

        // Newest-first by roundIndex (monotonic per event), same
        // walk `MascotEngine.recentWinners` uses.
        let sortedRounds = rounds.sorted { $0.roundIndex > $1.roundIndex }
        func roundWinner(_ round: EventRound) -> UUID? {
            for entry in round.entries {
                if case let .bool(isWinner)? = entry.meta["winner"], isWinner {
                    return entry.memberId
                }
            }
            return nil
        }
        let lastWinner = sortedRounds.first.flatMap(roundWinner)
        let previousWinner = sortedRounds.dropFirst().first.flatMap(roundWinner)
        let lastRoundFlippedLeader: Bool
        if let last = lastWinner, let previous = previousWinner {
            lastRoundFlippedLeader = last != previous
        } else {
            lastRoundFlippedLeader = false
        }

        // Consecutive wins: the count of most-recent rounds all won
        // by the same member (streak flavour fires at ≥ 3).
        var consecutiveWins = 0
        if let streakOwner = lastWinner {
            for round in sortedRounds {
                if roundWinner(round) == streakOwner {
                    consecutiveWins += 1
                } else {
                    break
                }
            }
        }

        // Leader margin from the season scoreboard (RPC already
        // sorts by season score DESC).
        let scores = leaderboard.map { Int($0.seasonScore) }
        let leaderMargin = scores.count >= 2 ? scores[0] - scores[1] : (scores.count == 1 ? scores[0] : 0)

        let lastSessionDaysAgo = daysSinceLastPlay

        return RoomStateInputs.resolve(
            RoomStateInputs(activeEvent: activeEvent.map {
                    .init(playedAt: $0.playedAt, settledAt: $0.settledAt)
                }, activeEventSettled: activeEvent?.settledAt != nil, withdrawnAmount: withdrawnAmount, leaderMargin: leaderMargin, lastRoundFlippedLeader: lastRoundFlippedLeader, consecutiveWins: consecutiveWins, openDispute: openDispute, lastSessionDaysAgo: lastSessionDaysAgo)
        )
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
            // S4 T2 - the room page already prints the room name as
            // its large navigation title, so the switcher used to
            // say it a second time. Icon-only now; the name stays
            // reachable on `accessibilityValue` below.
            Image(systemName: "chevron.up.chevron.down")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.labelText)
        }
        .accessibilityLabel(Text("Switch room"))
        .accessibilityValue(Text(currentRoom.name))
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .scaleEffect(appeared || reduceMotion ? 1 : 0.97)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.2, dampingFraction: 0.8), value: isPressed)
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