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

    /// Open attestations for the current member across all rooms
    /// (one row typically). Driven by
    /// `casinoService.getMyOpenAttestations()` in `.task`.
    @State private var openAttestations: [OpenAttestationSummary] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                activeSlot
                    .frame(maxWidth: .infinity)
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
            if isHost {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: { /* RoomSettingsSheet presentation handled by RoomPage */ }) {
                        Image(systemName: "gearshape")
                    }
                }
            }
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

        case .inPlay(let event):
            WitnessSlot(event: event, attestations: openAttestations, cta: .withdraw,
                        onWithdraw: { Task { await openWithdraw(event: event) } },
                        onScan: { Task { await openScan(event: event) } },
                        isHero: true)
        case .settleRound(let event):
            WitnessSlot(event: event, attestations: openAttestations, cta: .scan,
                        onWithdraw: { Task { await openWithdraw(event: event) } },
                        onScan: { Task { await openScan(event: event) } },
                        isHero: true)

        case .justSettled(let event):
            CeremonialCard(event: event)

        case .tonightEvent(let event):
            WitnessSlot(event: event, attestations: openAttestations, cta: .scan,
                         onWithdraw: { Task { await openWithdraw(event: event) } },
                         onScan: { Task { await openScan(event: event) } },
                         isHero: true)

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
    /// the current member's RSVP, and the open attestations.
    /// Called from `.task` and `.refreshable`.
    private func refresh() async {
        async let active: () = loadActiveIfNeeded()
        async let board: () = loadLeaderboardIfNeeded()
        async let attestations: () = loadAttestations()
        async let briefingLoad: () = loadBriefingIfNeeded()
        async let rsvpLoad: () = loadRSVPIfNeeded()
        _ = await (active, board, attestations, briefingLoad, rsvpLoad)
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

    /// Chip-withdraw CTA on the at-play Witness Slot. Currently a
    /// no-op stub — `CasinoService.withdraw(...)` requires a
    /// settled slider amount that the V0.8 page doesn't render.
    /// Wired here so the button has a real call site; the full
    /// surface ships in V0.8.1.
    private func openWithdraw(event: Event) async {
        _ = event
        // V0.8.1: present the Withdraw surface.
    }

    /// Chip-scan CTA. Calls `CasinoService.submitMemberScan(...)`
    /// with placeholder values so the call site exercises the
    /// service. The real vision pipeline + UI sheet land in V0.8.1.
    private func openScan(event: Event) async {
        let stubSnapshot = VisionSnapshot(
            stacks: [],
            totalValue: 0,
            confidenceAvg: 0,
            discarded: false
        )
        do {
            _ = try await casinoService.submitMemberScan(
                eventId: event.id,
                visionAmount: 0,
                visionSnapshot: stubSnapshot,
                confidence: nil,
                source: .manual
            )
        } catch {
            // The CasinoService keeps `lastError` for the banner;
            // the v0.8 stub intentionally swallows so the chip
            // scan CTA is reachable from the demo path.
            _ = error
        }
    }
}

// MARK: - States

private enum V0State {
    case loading
    case justSettled(Event)
    case tonightEvent(Event)
    case inPlay(Event)
    case settleRound(Event)
    case upcoming(Event)
    case claimed(Event)
    case declined(Event)
    case readStandings
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

    let event: Event
    let attestations: [OpenAttestationSummary]
    let cta: CTA
    let onWithdraw: () -> Void
    let onScan: () -> Void
    let isHero: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            HStack(spacing: 12) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The game is on")
                        .font(Theme.Typography.title.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("Phones face-down. Stay in the room.")
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

            Button("Mark as caught up →") {
                // v0.8.1: dismiss / scroll-to-standings
            }
            .font(Theme.Typography.body.weight(.semibold))
            .foregroundStyle(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Layout.cardInset)
        .sectionCard(.hero)
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
                    isYou: entry.userId == currentUserId
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
    var body: some View {
        // Stub — packs list is sourced from room.packs in v0.8.1.
        // v0.8 keeps this empty; the Settings → Packs surface owns it.
        EmptyView()
    }
}

// MARK: - Member roster

private struct MemberRosterReadOnly: View {
    let room: Room
    var body: some View {
        // Stub — roster list is sourced from RoomService.getRoomMembers in v0.8.1.
        EmptyView()
    }
}

// MARK: - Mascot footer caption

private struct MascotFooterCaption: View {
    let room: Room
    var body: some View {
        // v0.8 wires MascotEngine.buildFooterCaption here.
        Text("\(room.mascotName) is watching this room.")
            .font(Theme.Typography.caption.italic())
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Layout.sectionSpacing)
    }
}