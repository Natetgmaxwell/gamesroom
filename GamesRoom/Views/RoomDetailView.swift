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
//    3. .tonightEvent       — activeEvent present, playedAt ≤ now,
//                              no withdrawals for casino
//    4. .inPlay             — activeEvent.isLive && withdrawals exist
//    5. .settleRound        — host finalized, not all members scanned
//    6. .upcoming           — playedAt > now, RSVP == .unclaimed
//    7. .claimed            — playedAt > now, RSVP == .claimed
//    8. .declined           — playedAt > now, RSVP == .declined
//    9. .readStandings      — no active event, no recent settle
//
//  This view does not own data loading. It reads the active event,
//  the briefing summary, the open attestations, and the leaderboard
//  from RoomService + CasinoService. The data layer is stubbed for
//  v0.8 — the wiring of RPCs happens in v0.8.1.
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

    // Stub state — replaced by real RPC fetches in v0.8.1.
    @State private var activeEvent: Event? = nil
    @State private var briefing: BriefingSummary? = nil
    @State private var myRSVP: MemberRSVPState = .unclaimed
    @State private var openAttestations: [OpenAttestationSummary] = []
    @State private var leaderboard: [LeaderboardEntry] = []

    private var isHost: Bool {
        guard let uid = authService.currentUser?.id else { return false }
        return room.userRole == .host || room.createdBy == uid
    }

    private var currentUserId: UUID? {
        authService.currentUser?.id
    }

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
            let isCasino = event.packSlug == nil ? false : true
            _ = isCasino // pack slug is not part of Event in v0.8 stub
            if isSettled,
               let s = event.settledAt,
               s > Date().addingTimeInterval(-86_400),
               activeEvent == nil || true {
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

        case .upcoming(let event):  BriefingSlot(event: event, briefing: briefing, myRSVP: myRSVP, onClaim: { Task { await claimSeat() } }, onDecline: { Task { await declineSeat() } }, isHero: true)
        case .claimed(let event):   BriefingSlot(event: event, briefing: briefing, myRSVP: .claimed, onClaim: {}, onDecline: {}, isHero: true)
        case .declined(let event):  BriefingSlot(event: event, briefing: briefing, myRSVP: .declined, onClaim: {}, onDecline: {}, isHero: true)

        case .inPlay(let event):    WitnessSlot(event: event, attestations: openAttestations, cta: .withdraw, isHero: true)
        case .settleRound(let event): WitnessSlot(event: event, attestations: openAttestations, cta: .scan, isHero: true)

        case .justSettled(let event): CeremonialCard(event: event)

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

    // MARK: - Data operations (stubs for v0.8)

    private func refresh() async {
        // v0.8 stubs — the RPCs that back these live in v0.8.1.
        // For now, the page renders empty states for everything
        // except room metadata + the pack shelf + roster, which
        // are derived from the in-hand `Room` value alone.
        _ = briefing
        _ = leaderboard
        _ = activeEvent
    }

    private func claimSeat() async {
        // Calls `upsert_event_rsvp(event_id, member_id, state := 'claimed')`
        // via SupabaseClient. Migration 033 hasn't shipped to live DB
        // yet, so the rpc returns nothing — stub for v0.8.
        myRSVP = .claimed
    }

    private func declineSeat() async {
        myRSVP = .declined
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

// MARK: - Witness slot (at-play)

private struct WitnessSlot: View {
    enum CTA { case withdraw, scan }

    let event: Event
    let attestations: [OpenAttestationSummary]
    let cta: CTA
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
                Button {
                    // V0.8.1: CasinoService.withdraw(eventId, amount)
                } label: {
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
                Button {
                    // V0.8.1: present ChipScanView sheet
                } label: {
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
            ForEach(Array(entries.enumerated()), id: \.element.id) { _, entry in
                LeaderboardRow(
                    rank: rankFor(entry),
                    entry: entry,
                    isSelf: entry.userId == currentUserId
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
