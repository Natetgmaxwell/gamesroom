import Supabase
import SwiftUI

struct RoomDetailView: View {
    let room: Room
    let allRooms: [Room]
    let onDismiss: () -> Void
    let onSwitchRoom: (Room) -> Void
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hSize

    private var isRegularWidth: Bool { hSize == .regular }
    private var contentPadding: CGFloat { Theme.Layout.gutter(for: hSize) }
    private var cardCornerRadius: CGFloat {
        hSize == .regular
            ? 22
            : Theme.SectionCard.standard.cornerRadius
    }
    private var cardHorizontalPadding: CGFloat { Theme.Layout.cardInset(for: hSize) }
    @State private var members: [RoomMember] = []
    @State private var isLoadingMembers = true
    @State private var membersErrorMessage: String?
    @State private var refreshErrorMessage: String?
    @State private var deleteEventErrorMessage: String?
    @State private var leaveRoomErrorMessage: String?
    @State private var showGenerateCode = false
    @State private var showLeaveConfirm = false
    @State private var showSwitcher = false
    @State private var showRoomSettings = false
    @State private var packs: [RoomPack] = []
    @State private var isLoadingPacks = true
    @State private var packLoadError: String?
    @State private var activeEvent: ActiveEvent?
    @State private var eventSeats: [EventSeat] = []
    @State private var eventWithdrawals: [CasinoWithdrawal] = []
    @State private var eventTransactions: [EventTransaction] = []
    @State private var pastEvents: [PastEvent] = []
    @State private var isLoadingActive = true
    @State private var isLoadingSeats = false
    @State private var isLoadingPast = true
    @State private var showAddEvent = false
    @State private var showDeleteEventConfirm = false
    @State private var showEditEventDate = false
    @State private var editingEventDate = Date()
    @State private var isSavingEventDate = false
    @State private var eventDateErrorMessage: String?
    @State private var selectedPastEvent: PastEvent?
    @State private var showCasinoPanel = false
    @State private var showWithdrawal = false
    @State private var showMemberScan = false
    @State private var liveRoom: Room?
    @State private var memberNotes: [MemberNote] = []
    @State private var isLoadingMemberNotes = false
    @State private var briefingNarration: String?
    @State private var isLoadingBriefingNarration = false
    @State private var openAttestations: [OpenAttestationSummary] = []
    @State private var showingAttest: OpenAttestationSummary?
    @State private var leaderboard: [LeaderboardEntry] = []
    @State private var isLoadingLeaderboard = false
    @StateObject private var casinoService = CasinoService()

    private var isHost: Bool {
        guard let userId = authService.currentUser?.id else { return false }
        return room.createdBy == userId
    }

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

    private var currentMember: RoomMember? {
        guard let userId = currentUserId else { return nil }
        return members.first(where: { $0.id == userId })
    }

    private var currentWithdrawalTotal: Int {
        guard let userId = currentUserId else { return 0 }
        return eventWithdrawals
            .filter { $0.memberId == userId }
            .reduce(0) { $0 + $1.pointsWithdrawn }
    }

    private var hasAnyWithdrawal: Bool {
        eventTransactions.contains { $0.kind == "casino_withdrawal" }
    }

    private var memberNamesById: [UUID: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0.displayName) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                roomHeader
                Divider()
                    .background(Theme.hairline)
                activeSection
                    .frame(maxWidth: .infinity)
                attestBannerSection
                leaderboardSection
                pastSection
                memberNotesSection
                packsSection
                Spacer().frame(height: 24)
            }
        }
        // iOS 26 default: floating scroll indicator that auto-hides.
        // Explicit `.automatic` so the page renders the same regardless
        // of any container-level default changes.
        .scrollIndicators(.automatic)
        .refreshable {
            await refresh()
        }
        .overlay(alignment: .top) {
            if let refreshError = refreshErrorMessage {
                BannerOverlay(message: refreshError, onDismiss: {
                    refreshErrorMessage = nil
                }, kind: .error)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: refreshErrorMessage)
        .navigationTitle((liveRoom ?? room).name)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { showRoomSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: showRoomSettings)
                }
            }
        }
        // Apple-standard 16pt horizontal margin for ScrollView content.
        // One source of truth — applies to every section header, card,
        // and the room subtitle strip below the nav bar. Picked up
        // from the iOS standard `Form` and `List` row margins.
        .contentMargins(.horizontal, 16, for: .scrollContent)
        .background(Theme.background)
        .safeAreaInset(edge: .bottom) {
            bottomToolbar
        }
        .task {
            await refresh()
        }
        .sheet(isPresented: $showGenerateCode) {
            GenerateCodeView(roomId: room.id) {
                showGenerateCode = false
            }
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showSwitcher) {
            RoomSwitcherMenu(
                currentRoomId: room.id,
                rooms: allRooms,
                isHost: isHost,
                onSelect: { selected in
                    showSwitcher = false
                    if selected.id != room.id {
                        onSwitchRoom(selected)
                    }
                },
                onSettings: { showRoomSettings = true },
                onCreateRoom: { }
            )
        }
        .sheet(isPresented: $showRoomSettings) {
            RoomSettingsSheet(room: liveRoom ?? room) {
                showRoomSettings = false
                Task { try? await loadRoom() }
            }
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showAddEvent) {
            AddEventSheet(
                roomId: room.id,
                packs: packs,
                hostCalendarEnabled: (liveRoom ?? room).calendarAutoAddHost,
                mascotName: (liveRoom ?? room).mascotName,
                mascotPersonality: (liveRoom ?? room).mascotPersonality,
                mascotIdeology: (liveRoom ?? room).mascotPoliticalIdeology,
                mascotHosting: (liveRoom ?? room).mascotApiKey.map { MascotEngine.HostingConfig(apiKey: $0) },
                socialNarrationEnabled: (liveRoom ?? room).socialNarrationEnabled
            ) {
                showAddEvent = false
                Task {
                    await loadActive()
                    await loadPast()
                }
            }
            .environmentObject(roomService)
        }
        .sheet(isPresented: $showEditEventDate) {
            editEventDateSheet
        }
        .sheet(isPresented: $showCasinoPanel) {
            CasinoPanelView(
                room: liveRoom ?? room,
                members: members,
                isHost: isHost,
                activeEvent: activeEvent
            )
            .environmentObject(casinoService)
        }
        .sheet(isPresented: $showWithdrawal) {
            if let event = activeEvent, let member = currentMember {
                WithdrawalView(
                    room: liveRoom ?? room,
                    sessionId: event.id,
                    currentBalance: member.pointsBalance
                ) {
                    showWithdrawal = false
                    Task {
                        // Refresh just the things affected by the
                        // withdrawal so the user sees the change
                        // immediately. Swallow errors — they will be
                        // surfaced on the next manual refresh.
                        var failures: [String] = []
                        await loadMembersSafely(into: &failures)
                        await loadActiveSafely(into: &failures)
                        await loadLeaderboardSafely(into: &failures)
                    }
                }
                .environmentObject(casinoService)
                .environmentObject(authService)
            }
        }
        .sheet(isPresented: $showMemberScan) {
            if let event = activeEvent {
                ChipScanView(
                    room: liveRoom ?? room,
                    sessionId: event.id
                ) {
                    showMemberScan = false
                    Task {
                        await loadActive()
                    }
                }
                .environmentObject(casinoService)
                .environmentObject(authService)
            }
        }
        .sheet(item: $selectedPastEvent) { event in
            EventDetailView(
                event: event,
                room: liveRoom ?? room,
                members: members,
                packs: packs
            )
            .environmentObject(roomService)
        }
        .sheet(item: $showingAttest) { summary in
            MemberSettlementAttestView(summary: summary) {
                showingAttest = nil
                Task { await refresh() }
            }
            .environmentObject(casinoService)
            .environmentObject(authService)
        }
        .confirmationDialog(
            "Delete event?",
            isPresented: $showDeleteEventConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete event", role: .destructive) {
                Task { await deleteActiveEvent() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This cannot be undone.")
        }
    }

    // MARK: - Header

    /// Thin subtitle strip beneath the navigation title. Carries
    /// mascot identity and the current user's live balance — both
    /// are state about the user, not chrome about the room. The
    /// room title itself lives in the navigation bar.
    private var roomHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text((liveRoom ?? room).mascotName)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            if currentUserId != nil, let member = currentMember, member.pointsBalance != 0 {
                HStack(spacing: 4) {
                    Text("\(member.pointsBalance) pts")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.accent)
                }
            }
            Spacer()
            if allRooms.count >= 2 {
                Button(action: { showSwitcher = true }) {
                    HStack(spacing: 4) {
                        Text("Switch")
                            .font(.system(size: 12, weight: .medium))
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    // MARK: - Active Event

    @ViewBuilder
    private var activeSection: some View {
        // Section header is shown whenever there's content below it
        // (active event OR a host-only empty-state CTA). Non-hosts in
        // an empty room see nothing — they shouldn't be told "no event,"
        // that's noise.
        let hostSeesHeader = activeEvent != nil || isHost

        if hostSeesHeader {
            VStack(alignment: .leading, spacing: 0) {
                if activeEvent != nil {
                    HStack {
                        Text("Tonight")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                        Spacer()
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 4)
                }

                if isLoadingActive {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else if let event = activeEvent {
                    if isRegularWidth {
                        activeEventIPad(event)
                    } else {
                        activeEventIPhone(event)
                    }
                } else if isHost {
                    // No event + host. The whole card IS the CTA.
                    // Same warm-tinted treatment as the active event so
                    // the host's primary action always reads as the
                    // page's focal point.
                    hostCreateEventCard
                        .padding(.top, 24)
                }
            }
        }
    }

    /// Empty-state CTA for hosts with no active event. Mirrors the
    /// active event card's warm-tinted hero treatment so the host's
    /// "next thing to do" is never visually subordinate to the
    /// sections below.
    private var hostCreateEventCard: some View {
        Button(action: { showAddEvent = true }) {
            HStack(spacing: 14) {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create tonight's game")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Pick the game, time, and who's playing")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(16)
            .sectionCard()
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: UUID())
    }

    // MARK: - V0.29 Attestation Banner

    @ViewBuilder
    private var attestBannerSection: some View {
        if let summary = openAttestations.first(where: { $0.roomId == room.id }) {
            Button {
                showingAttest = summary
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your P&L: \(summary.visionAmountPoints >= 0 ? "+" : "")\(summary.visionAmountPoints)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.primaryText)
                        Text("Tap to confirm or adjust. \(openAttestations.count > 1 ? "(\(openAttestations.count) open)" : "")")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Theme.accent.opacity(0.1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Theme.accent.opacity(0.4), lineWidth: 1)
                        )
                )
                .padding(.top, 16)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Leaderboard (V0.31)

    @ViewBuilder
    private var leaderboardSection: some View {
        // Hide the section entirely when empty. A room with no members
        // doesn't need a label telling the user that.
        if !leaderboard.isEmpty || isLoadingLeaderboard {
            VStack(alignment: .leading, spacing: 0) {
                // Section header sits OUTSIDE the card so the card itself
                // holds only data — the same convention the active event
                // card uses for "Tonight" header above.
                HStack {
                    Text("Standings")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                    if let totalSessions = leaderboard.map({ $0.sessionsPlayed }).max(), totalSessions > 0 {
                        Text("\(totalSessions) session\(totalSessions == 1 ? "" : "s") played")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .padding(.top, 24)
                .padding(.bottom, 8)

                if isLoadingLeaderboard && leaderboard.isEmpty {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .sectionCard()
                } else if !leaderboard.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(leaderboardRanked.enumerated()), id: \.element.id) { idx, entry in
                            LeaderboardRow(
                                rank: rankForIndex(idx, entry: entry),
                                entry: entry,
                                isSelf: entry.userId == currentUserId,
                                withdrawAction: withdrawAction(for: entry)
                            )
                            if idx < leaderboardRanked.count - 1 {
                                Divider()
                                    .background(Theme.hairline.opacity(0.5))
                                    .padding(.leading, contentPadding)
                            }
                        }
                    }
                    .sectionCard()
                }
            }
        }
    }

    // MARK: - Mascot Footer (V0.32, V0.34)
    //
    // The mascot voice used to live as a standalone caption below the
    // leaderboard. As of V0.34 it moved inside the active event card
    // as a footer line — "Borat's take on tonight's game." The
    // standalone caption is gone; the engine call is inlined into
    // `activeEventIPhone` directly.

    /// Withdraw is shown on the standings row for the current user
    /// when an active casino event is running. Mirrors the old
    /// MemberRow behavior so live balances stay first-class.
    private func withdrawAction(for entry: LeaderboardEntry) -> (() -> Void)? {
        guard entry.userId == currentUserId,
              activeEvent?.packSlug == "casino",
              (activeEvent?.playedAt ?? .distantFuture) <= Date() else {
            return nil
        }
        return { showWithdrawal = true }
    }

    /// Members sorted with the host first (rank "—"), then the rest
    /// by season_score desc. The SQL already orders this way; this
    /// is here for safety + to expose the host as a separate section
    /// if we want to.
    private var leaderboardRanked: [LeaderboardEntry] {
        // The RPC already returns host first, then season_score desc.
        // We trust that order. If the data ever comes back unsorted
        // (e.g. local fixtures), this is the place to add a sort.
        leaderboard
    }

    /// Rank: 1, 2, 3... for non-host members in order. The host gets
    /// no rank (LeaderboardRow renders "—" for them).
    private func rankForIndex(_ idx: Int, entry: LeaderboardEntry) -> Int {
        if entry.isHost { return 0 }
        // Count how many non-host entries precede this one in the
        // ranked array, plus one. (The host is always at index 0
        // when present, so non-host indices shift by 1.)
        let hostCount = leaderboardRanked.prefix(idx).filter { $0.isHost }.count
        return idx - hostCount
    }

    // MARK: - Briefing Card (V0.26)

    // MARK: - Briefing Card (V0.26, REMOVED in V0.34)
    //
    // The briefing card used to render a separate "Briefing" section
    // with the mascot's narration about an upcoming event. As of V0.34
    // it was removed because it duplicated the active event card's
    // mascot voice (the footer line in the active event card) AND it
    // duplicated the date + seat count metadata already shown in the
    // card. The single source of truth for mascot voice is now
    // `MascotFooterView` inside the active event card.

    @ViewBuilder
    private func activeEventIPad(_ event: ActiveEvent) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Two columns: event metadata on the left, action buttons on
            // the right. Each column flexes to fill its share of the row
            // so the active event card grows with the canvas instead of
            // clamping each side at a fixed iPhone-shaped 480pt.
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    eventHeaderBlock(event)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                eventActionsBlock(event)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Mascot voice lives inside the active event card as a
            // footer line — same convention as iPhone.
            Divider()
                .background(Theme.hairline.opacity(0.5))
            MascotFooterView(
                mascotName: (liveRoom ?? room).mascotName,
                roomName: (liveRoom ?? room).name,
                personality: (liveRoom ?? room).mascotPersonality,
                ideology: (liveRoom ?? room).mascotPoliticalIdeology,
                context: buildMascotContext(),
                hosting: (liveRoom ?? room).mascotApiKey.map { MascotEngine.HostingConfig(apiKey: $0) }
            )

            if isHost && hasAnyWithdrawal {
                EventTransactionsView(
                    transactions: eventTransactions,
                    memberNamesById: memberNamesById
                )
            }
        }
        .padding(20)
        .sectionCard(.hero)
    }

    @ViewBuilder
    private func activeEventIPhone(_ event: ActiveEvent) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Compact header: event name + combined metadata line
            HStack(alignment: .firstTextBaseline) {
                Text(event.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if isHost {
                    Menu {
                        Button("Edit date") {
                            editingEventDate = event.playedAt
                            eventDateErrorMessage = nil
                            showEditEventDate = true
                        }
                        Button("Delete event", role: .destructive) {
                            showDeleteEventConfirm = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 32, height: 32)
                    }
                }
            }

            Text("\(humanDate(event.playedAt)) · \(event.seatCount) of \(event.maxSeats) seats")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)

            SeatGridView(
                claimedSeats: eventSeats,
                maxSeats: event.maxSeats
            )

            activeEventActionView(event)

            // Mascot voice lives inside the active event card as a
            // footer line — "Borat's take on tonight's game." Same
            // engine call as the standalone footer caption, but now
            // anchored to the event it comments on.
            Divider()
                .background(Theme.hairline.opacity(0.5))
            MascotFooterView(
                mascotName: (liveRoom ?? room).mascotName,
                roomName: (liveRoom ?? room).name,
                personality: (liveRoom ?? room).mascotPersonality,
                ideology: (liveRoom ?? room).mascotPoliticalIdeology,
                context: buildMascotContext(),
                hosting: (liveRoom ?? room).mascotApiKey.map { MascotEngine.HostingConfig(apiKey: $0) }
            )

            if isHost && hasAnyWithdrawal {
                EventTransactionsView(
                    transactions: eventTransactions,
                    memberNamesById: memberNamesById
                )
            }
        }
        .padding(16)
        .sectionCard(.hero)
    }

    @ViewBuilder
    private func mascotBubbleView() -> some View {
        MascotBubble(
            mascotName: (liveRoom ?? room).mascotName,
            roomName: (liveRoom ?? room).name,
            personality: (liveRoom ?? room).mascotPersonality,
            ideology: (liveRoom ?? room).mascotPoliticalIdeology,
            context: buildMascotContext(),
            hosting: (liveRoom ?? room).mascotApiKey.map { MascotEngine.HostingConfig(apiKey: $0) }
        )
    }

    @ViewBuilder
    private func eventHeaderBlock(_ event: ActiveEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(event.name)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .foregroundStyle(Theme.primaryText)

            if isHost {
                Button(action: {
                    editingEventDate = event.playedAt
                    eventDateErrorMessage = nil
                    showEditEventDate = true
                }) {
                    Text(formattedDate(event.playedAt))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
                .buttonStyle(.plain)
            } else {
                Text(formattedDate(event.playedAt))
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
            }

            HStack(spacing: 4) {
                Text("Seats:")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                Text("\(event.seatCount)/\(event.maxSeats)")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func eventActionsBlock(_ event: ActiveEvent) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            SeatGridView(
                claimedSeats: eventSeats,
                maxSeats: event.maxSeats
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            activeEventActionView(event)

            if isHost {
                Button("Delete event", role: .destructive) {
                    showDeleteEventConfirm = true
                }
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.6))
            }
        }
    }

    private var editEventDateSheet: some View {
        NavigationStack {
            Form {
                Section("Date & time") {
                    DatePicker("When", selection: $editingEventDate)
                }

                if let eventDateErrorMessage {
                    Section {
                        Text(eventDateErrorMessage)
                            .font(.system(size: 13))
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .navigationTitle("Edit event date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showEditEventDate = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await saveEventDate() } }
                        .disabled(isSavingEventDate)
                }
            }
        }
    }


    @ViewBuilder
    private var pastSection: some View {
        // Hide the section entirely when empty. A room with no history
        // doesn't need a label telling the user that.
        if !pastEvents.isEmpty || isLoadingPast {
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                if isLoadingPast {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .sectionCard()
                } else if !pastEvents.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(pastEvents) { event in
                            Button(action: { selectedPastEvent = event }) {
                                pastEventRow(event)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Task { await deletePastEvent(event) }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: UUID())
                        }
                    }
                    .sectionCard()
                }
            }
        }
    }

    private func pastEventRow(_ event: PastEvent) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(event.name)
                .font(.system(size: 17, weight: .regular, design: .serif))
                .foregroundStyle(Theme.primaryText)

            HStack {
                Text(formattedDate(event.playedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)

                Spacer()

                if let winnerName = event.winnerDisplayName {
                    Text(winnerText(event: event, winnerName: winnerName))
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                } else {
                    Text("\u{2014}")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func winnerText(event: PastEvent, winnerName: String) -> String {
        guard let scoringType = event.scoringType else {
            return "\(winnerName) won"
        }

        switch scoringType {
        case "withdraw_return":
            if let score = event.winnerScore {
                let netted = score
                let returned = netted >= 0 ? netted + 10 : 10
                let withdrawn = 10
                return "\(winnerName) netted \(netted >= 0 ? "+" : "")\(netted) (withdrew \(withdrawn), returned \(returned))"
            }
            return "\(winnerName) won"
        default:
            if let score = event.winnerScore {
                return "\(winnerName) won with \(score) point\(score == 1 ? "" : "s")"
            }
            return "\(winnerName) won"
        }
    }

    // MARK: - Member Notes (host-only, V0.26)

    @ViewBuilder
    private var memberNotesSection: some View {
        let currentRoom = liveRoom ?? room
        if isHost && currentRoom.socialPreferencesEnabled && !memberNotes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Notes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 24)
                    .padding(.bottom, 8)

                if isLoadingMemberNotes {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(memberNotes) { note in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                                if !note.socialText.isEmpty {
                                    Text(note.socialText)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.primaryText)
                                }
                                if !note.conversationPrompt.isEmpty {
                                    Text(note.conversationPrompt)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.secondaryText)
                                        .italic()
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Packs

    @ViewBuilder
    private var packsSection: some View {
        // Hide the section entirely when empty. Pack management
        // lives in settings — no need for an empty placeholder
        // on the room page.
        if !packs.isEmpty || isLoadingPacks || packLoadError != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Game packs")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                    Spacer()
                }
                .padding(.top, 24)
                .padding(.bottom, 8)

                if isLoadingPacks {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .sectionCard()
                } else if let packLoadError {
                    Text(packLoadError)
                        .font(.system(size: 14))
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(.vertical, 8)
                        .sectionCard()
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(packs.enumerated()), id: \.element.id) { _, pack in
                            Button(action: {
                                if pack.slug == "casino" {
                                    showCasinoPanel = true
                                }
                            }) {
                                HStack {
                                    Text(pack.displayName)
                                        .font(.system(size: 17, weight: .regular, design: .serif))
                                        .foregroundStyle(Theme.primaryText)
                                    Spacer()
                                    if pack.slug == "casino" {
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(Theme.secondaryText)
                                    }
                                    if isHost && pack.slug != "casino" {
                                        Button(action: { Task { try? await removePack(pack) } }) {
                                            Text("\u{00D7}")
                                                .font(.system(size: 17, weight: .medium))
                                                .foregroundStyle(Theme.secondaryText)
                                        }
                                    }
                                }
                            }
                            .sensoryFeedback(.impact(weight: .light), trigger: UUID())
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                    }
                    .sectionCard()
                }
            }
        }
    }

    // MARK: - Bottom Toolbar

    private var bottomToolbar: some View {
        HStack {
            Spacer()

            if (liveRoom ?? room).userRole == .member {
                Button(action: { showLeaveConfirm = true }) {
                    Text("Leave")
                        .font(.system(size: 15))
                        .foregroundStyle(.red.opacity(0.85))
                }
                .sensoryFeedback(.impact(weight: .light), trigger: UUID())
            }
        }
        // Toolbar sits outside the ScrollView's contentMargins, so it
        // needs its own edge padding. 16pt matches the rest of the page.
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        // No background. The toolbar is fully transparent so the iOS
        // tab bar's own translucent chrome (and the content scrolling
        // behind it) shows through cleanly. Adding any background —
        // solid color OR material — competes visually with the tab bar.
    }

    // MARK: - Helpers

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Compact, human-readable phrasing for active-event metadata.
    /// Future events get a "when" phrasing ("Tonight 8:00 PM"); past
    /// events are out of scope here — that's `relativeDate(_:)` for
    /// Step 7 (the past events list).
    private func humanDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        let time = timeFormatter.string(from: date)

        if calendar.isDateInToday(date) {
            return "Today, \(time)"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow, \(time)"
        }
        if date > now {
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEE, MMM d"
            return "\(dayFormatter.string(from: date)) · \(time)"
        }
        return formattedDate(date)
    }

    private func buildMascotContext() -> MascotEngine.RoomContext {
        let daysSinceLastEvent: Int? = {
            guard let lastEvent = pastEvents.first else { return nil }
            let interval = Date().timeIntervalSince(lastEvent.playedAt)
            return max(0, Int(interval / 86400))
        }()
        return MascotEngine.RoomContext(
            activeEventTitle: activeEvent?.name,
            lastEventDaysAgo: daysSinceLastEvent,
            memberCount: members.count,
            memberNames: members.map(\.displayName),
            standingsTopThree: []
        )
    }

    // MARK: - Data Loading

    private func refresh() async {
        // Each loader can throw; we collect one consolidated message so
        // the user knows SOMETHING failed (vs. silently losing data).
        // The previous behavior — each loader swallowing errors via
        // `(try? ...) ?? []` — meant pull-to-refresh on a flaky network
        // appeared to empty out the room.
        var failures: [String] = []

        await loadRoomSafely(into: &failures)
        await loadMembersSafely(into: &failures)
        await loadPacksSafely(into: &failures)
        await loadActiveSafely(into: &failures)
        await loadPastSafely(into: &failures)
        if isHost && (liveRoom ?? room).socialPreferencesEnabled {
            await loadMemberNotesSafely(into: &failures)
        }
        if (liveRoom ?? room).socialNarrationEnabled, let event = activeEvent, event.playedAt > Date() {
            await loadBriefingNarration()
        }
        // V0.29 — pull the member's open attestations. Banner shows if any.
        // `getMyOpenAttestations` is non-throwing (it swallows errors
        // internally), so we just await it directly.
        openAttestations = await casinoService.getMyOpenAttestations()
        // V0.31 — season leaderboard
        await loadLeaderboardSafely(into: &failures)

        if !failures.isEmpty {
            // Pick the most user-relevant failure if multiple
            if failures.contains("members") || failures.contains("leaderboard") {
                refreshErrorMessage = "Couldn't refresh standings. Pull again to retry."
            } else {
                refreshErrorMessage = "Refresh hit a snag (\(failures.joined(separator: ", "))). Try again."
            }
        } else {
            refreshErrorMessage = nil
        }
    }

    // MARK: - Refresh-error-safe loader wrappers
    //
    // Each wraps a loader in try/catch and reports into a shared
    // failures list. They intentionally preserve any state already
    // loaded — a partial failure should NOT blank out the screen.

    private func loadRoomSafely(into failures: inout [String]) async {
        do {
            try await loadRoom()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            failures.append("room details")
        }
    }

    private func loadMembersSafely(into failures: inout [String]) async {
        do {
            try await loadMembersOrThrow()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            failures.append("members")
        }
    }

    private func loadPacksSafely(into failures: inout [String]) async {
        do {
            try await loadPacksOrThrow()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            packLoadError = "Couldn't load game packs. Pull again to retry."
            failures.append("packs")
        }
    }

    private func loadActiveSafely(into failures: inout [String]) async {
        do {
            try await loadActiveOrThrow()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            failures.append("active event")
        }
    }

    private func loadPastSafely(into failures: inout [String]) async {
        do {
            try await loadPastOrThrow()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            failures.append("past events")
        }
    }

    private func loadMemberNotesSafely(into failures: inout [String]) async {
        await loadMemberNotesOrThrow()
    }

    private func loadLeaderboardSafely(into failures: inout [String]) async {
        do {
            try await loadLeaderboardOrThrow()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            // User-initiated cancellation (e.g. they pulled to refresh
            // again before the previous one finished, or navigated
            // away). Don't surface as a failure — it's not a real error.
            return
        } catch {
            failures.append("leaderboard")
        }
    }

    /// Throwing variants of the loaders. These wrap the underlying
    /// service calls so we can surface errors to the refresh wrapper
    /// instead of silently swallowing them.
    private func loadRoom() async throws {
        let rooms: [Room] = try await SupabaseClientProvider.shared
            .rpc("get_my_rooms")
            .execute()
            .value
        if let updated = rooms.first(where: { $0.id == room.id }) {
            self.liveRoom = updated
        }
    }

    private func loadMembersOrThrow() async throws {
        let rows: [RoomMember] = try await SupabaseClientProvider.shared
            .rpc("get_room_members", params: ["p_room_id": room.id])
            .execute()
            .value
        self.members = rows
        self.membersErrorMessage = nil
    }

    private func loadPacksOrThrow() async throws {
        isLoadingPacks = true
        defer { isLoadingPacks = false }
        self.packs = try await roomService.loadPacks(roomId: room.id)
        self.packLoadError = nil
    }

    private func loadActiveOrThrow() async throws {
        isLoadingActive = true
        defer { isLoadingActive = false }
        guard let event = try await roomService.loadActiveEventThrowing(roomId: room.id) else {
            activeEvent = nil
            eventSeats = []
            eventWithdrawals = []
            eventTransactions = []
            return
        }
        activeEvent = event
        isLoadingSeats = true
        eventSeats = try await roomService.loadEventSeatsThrowing(eventId: event.id)
        eventWithdrawals = try await loadWithdrawalsThrowing(for: event)
        if event.packSlug == "casino" {
            eventTransactions = try await roomService.loadEventTransactionsThrowing(eventId: event.id)
        } else {
            eventTransactions = []
        }
        isLoadingSeats = false

        let currentRoom = liveRoom ?? room
        if currentRoom.briefing48hEnabled && event.playedAt > Date() {
            await NotificationDispatcher.shared.scheduleBriefingTrio(
                eventId: event.id,
                eventName: event.name,
                playedAt: event.playedAt,
                mascotName: currentRoom.mascotName,
                briefingNarration: briefingNarration
            )
        }
    }

    private func loadPastOrThrow() async throws {
        isLoadingPast = true
        defer { isLoadingPast = false }
        self.pastEvents = try await roomService.loadPastEventsThrowing(roomId: room.id)
    }

    private func loadMemberNotesOrThrow() async {
        isLoadingMemberNotes = true
        defer { isLoadingMemberNotes = false }
        // The current `loadMemberNotes` swallows errors internally via
        // `(try? ...) ?? []`. We don't have a throwing variant yet; the
        // safe wrapper still serves its purpose by capturing network
        // failures if we add one later. For now this is a pass-through.
        self.memberNotes = await roomService.loadMemberNotes(roomId: room.id)
    }

    private func loadLeaderboardOrThrow() async throws {
        isLoadingLeaderboard = true
        defer { isLoadingLeaderboard = false }
        self.leaderboard = try await roomService.loadLeaderboardThrowing(roomId: room.id)
    }

    private func loadWithdrawalsThrowing(for event: ActiveEvent) async throws -> [CasinoWithdrawal] {
        guard event.packSlug == "casino",
              event.playedAt <= Date(),
              let userId = currentUserId else { return [] }
        return try await roomService.loadWithdrawals(
            eventId: event.id,
            userId: userId,
            sincePlayedAt: event.playedAt
        )
    }

    private func removePack(_ pack: RoomPack) async {
        do {
            try await roomService.removePack(roomId: room.id, packSlug: pack.slug)
            packLoadError = nil
            packs.removeAll { $0.id == pack.id }
        } catch {
            packLoadError = (error as NSError).localizedDescription
        }
    }

    private func leaveRoom() async {
        do {
            try await roomService.leaveRoom(roomId: room.id)
            await MainActor.run {
                onDismiss()
            }
        } catch {
            let detail = (error as NSError).localizedDescription
            await MainActor.run {
                leaveRoomErrorMessage = "Could not leave: \(detail)"
            }
        }
    }

    private func loadActive() async {
        do { try await loadActiveOrThrow() } catch {}
    }

    private func loadPast() async {
        do { try await loadPastOrThrow() } catch {}
    }

    private func deleteActiveEvent() async {
        guard let event = activeEvent else { return }
        do {
            try await roomService.deleteEvent(eventId: event.id)
            deleteEventErrorMessage = nil
            await loadActive()
            await loadPast()
        } catch {
            deleteEventErrorMessage = "Could not delete event: \((error as NSError).localizedDescription)"
        }
    }

    private func deletePastEvent(_ event: PastEvent) async {
        do {
            try await roomService.deleteEvent(eventId: event.id)
            deleteEventErrorMessage = nil
            await loadPast()
        } catch {
            deleteEventErrorMessage = "Could not delete event: \((error as NSError).localizedDescription)"
        }
    }

    private func saveEventDate() async {
        guard let event = activeEvent else { return }
        isSavingEventDate = true
        eventDateErrorMessage = nil
        defer { isSavingEventDate = false }
        do {
            try await roomService.updateEventPlayedAt(
                eventId: event.id,
                playedAt: editingEventDate
            )
            showEditEventDate = false
            await loadActive()
        } catch {
            eventDateErrorMessage = (error as NSError).localizedDescription
        }
    }

    private func loadBriefingNarration() async {
        guard let event = activeEvent, event.playedAt > Date() else {
            briefingNarration = nil
            return
        }
        guard !isLoadingBriefingNarration else { return }
        isLoadingBriefingNarration = true
        defer { isLoadingBriefingNarration = false }
        let currentRoom = liveRoom ?? room
        let ctx = MascotEngine.BriefingContext(
            eventName: event.name,
            playedAt: event.playedAt,
            venue: nil,
            packNames: packs.map(\.displayName),
            attendingMemberNames: eventSeats.map(\.displayName),
            hostNote: nil,
            conversationPrompts: memberNotes.compactMap {
                $0.conversationPrompt.isEmpty ? nil : $0.conversationPrompt
            }
        )
        briefingNarration = await MascotEngine.shared.generateBriefingNarration(
            mascotName: currentRoom.mascotName,
            roomName: currentRoom.name,
            personality: currentRoom.mascotPersonality,
            ideology: currentRoom.mascotPoliticalIdeology,
            context: ctx,
            hosted: currentRoom.mascotApiKey.map { MascotEngine.HostingConfig(apiKey: $0) }
        )
    }

    @ViewBuilder
    private func activeEventActionView(_ event: ActiveEvent) -> some View {
        if event.playedAt > Date() {
            if let userId = currentUserId {
                seatClaimOrStatusView(
                    isClaimed: eventSeats.contains { $0.userId == userId },
                    onClaim: { Task { try? await claimSeat() } },
                    onRelease: { Task { try? await releaseSeat() } }
                )
            }
        } else if event.packSlug == "casino" {
            if hasAnyWithdrawal {
                if isHost {
                    hostCashOutActionView
                } else if let member = currentMember {
                    if currentWithdrawalTotal > 0 {
                        VStack(spacing: 8) {
                            withdrawalStatusView(member: member, withdrawn: currentWithdrawalTotal)
                            scanChipsActionView
                        }
                    } else {
                        withdrawalActionView
                    }
                }
            } else {
                if isHost {
                    hostCasinoEmptyState
                } else {
                    memberCasinoEmptyState
                }
            }
        }
    }

    private var hostCasinoEmptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
            Text("Waiting for players to take chips.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
        }
        .padding(.vertical, 14)
        .padding(.horizontal, cardHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(Theme.cardSurface)
        )
    }

    private var memberCasinoEmptyState: some View {
        // This is the primary action for a member during a live casino
        // event — render as a button, not as passive informational text.
        Button(action: { showWithdrawal = true }) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Withdraw chips to play")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text("Convert your points into chips for the table")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.accent)
            )
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .medium), trigger: UUID())
    }

    private var withdrawalActionView: some View {
        Button(action: { showWithdrawal = true }) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 18, weight: .semibold))
                Text("Withdraw chips")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(Theme.primaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(Theme.accent)
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: UUID())
    }

    private func withdrawalStatusView(member: RoomMember, withdrawn: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're in")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                Text("\(withdrawn) chips / \(member.pointsBalance) points")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button("Withdraw more") { showWithdrawal = true }
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, cardHorizontalPadding)
        .background(
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .fill(.green.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: cardCornerRadius)
                .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
        )
    }

    private var hostCashOutActionView: some View {
        Button(action: { showCasinoPanel = true }) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack.badge.play.fill")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("View per-member scans")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Live board; finalize when everyone is done")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, cardHorizontalPadding)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(Theme.accent.opacity(0.85))
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: UUID())
    }

    private var scanChipsActionView: some View {
        Button(action: { showMemberScan = true }) {
            HStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 20, weight: .semibold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Scan your chips")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Use the room's vision API to count your stack")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
            }
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, cardHorizontalPadding)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(Theme.accent)
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: UUID())
    }

    @ViewBuilder
    private func seatClaimOrStatusView(
        isClaimed: Bool,
        onClaim: @escaping () -> Void,
        onRelease: @escaping () -> Void
    ) -> some View {
        if isClaimed {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.green)
                Text("You're in")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.green)
                Spacer()
                Button("Release", action: onRelease)
                    .font(.system(size: 13))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .padding(.vertical, 14)
            .padding(.horizontal, cardHorizontalPadding)
            .background(
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(.green.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
            )
        } else {
            Button(action: onClaim) {
                HStack(spacing: 10) {
                    Image(systemName: "chair.fill")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Claim your seat")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Theme.primaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: cardCornerRadius)
                        .fill(Theme.accent)
                )
            }
            .sensoryFeedback(.impact(weight: .medium), trigger: UUID())
        }
    }

    private func claimSeat() async {
        guard let event = activeEvent else { return }
        do {
            try await roomService.claimSeat(eventId: event.id)
            isLoadingSeats = true
            eventSeats = await roomService.loadEventSeats(eventId: event.id)
            isLoadingSeats = false
        } catch {
            // silent
        }
    }

    private func releaseSeat() async {
        guard let event = activeEvent else { return }
        do {
            try await roomService.releaseSeat(eventId: event.id)
            isLoadingSeats = true
            eventSeats = await roomService.loadEventSeats(eventId: event.id)
            isLoadingSeats = false
        } catch {
            // silent
        }
    }
}

struct RoomMember: Identifiable, Codable, Hashable {
    let userId: UUID
    let displayName: String
    let role: String
    let pointsBalance: Int
    let seasonScore: Int

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case role
        case pointsBalance = "points_balance"
        case seasonScore = "season_score"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        displayName = try c.decode(String.self, forKey: .displayName)
        role = try c.decode(String.self, forKey: .role)
        pointsBalance = try c.decode(Int.self, forKey: .pointsBalance)
        seasonScore = try c.decodeIfPresent(Int.self, forKey: .seasonScore) ?? 0
    }
}
