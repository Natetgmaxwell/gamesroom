//
//  InMemorySweepSeeds.swift
//  GamesRoom
//
//  V1.2.1 design-audit sweep (branch polish/audit-harness).
//
//  Seed states for `ScreenshotSweepTests` (the phone 16-state
//  screenshot matrix), split out of `InMemoryRoomStore.init` so the
//  main file — already over the repo's pre-commit token cap — does
//  not grow. Reachable ONLY through the existing screenshot seam:
//  `InMemoryRoomStore.init` calls `applyAuditSweepSeeds` from the
//  `default:` arm of its `-screenshots-state=` switch, which is
//  itself gated on `-screenshots-bypass-auth`; the method no-ops
//  for keys it does not know and production (Release) builds never
//  parse the argument list at all. No production data paths,
//  views, or networking are touched.
//
//  Keys (each drives one capture in the audit matrix):
//    briefing           `.upcoming` two days out with three claimed
//                       seats, Sam brought by Alex at tier 2, and a
//                       board that gives Sam zero nights — the
//                       brought-by caption's full line
//                       ("with Alex · first night · into Bouldering").
//    tonight-live       `.tonightEvent` witness hero; Question Box
//                       disabled so the V0.106 opener turn cannot
//                       cover the slot with the reader card.
//    score-live         Live single-winner night (Monopoly Deal) so
//                       the host's "Score a round" opens
//                       HostScoreEntrySheet — the phone form of the
//                       scoring surface (the full HostScoringDashboard
//                       chrome is iPad-regular-width only by design).
//    chip-scan          Casino primary pack WITH a single-winner
//                       side pack (V0.95 event-level pack_slugs):
//                       `eventHasSingleWinnerPack()` renders the
//                       host CTA and `openHostScore`'s
//                       `.withdrawReturn` branch routes it to
//                       `ChipScanSheet` — the one phone path to the
//                       casino vision-settle sheet that needs no
//                       live withdrawal RPC.
//    settled-rich       `.justSettled` over an audit-rich roster:
//                       five standings rows with mixed green/red
//                       last-night deltas, a comeback arc (Jordan),
//                       a blowout (Host +580), and a mocking-case
//                       Tonight's Star quote.
//    member-idle        No active event; pairs with the existing
//                       `-screenshots-as-member` launch argument for
//                       the member's `.readStandings` view.
//    upcoming-partial   `.upcoming` with a 3-of-6 seat grid and
//                       fresh Currently Into lines under Who's
//                       Coming.
//    claim-card         `.upcoming`, caller unclaimed, 2-of-6 grid —
//                       the Claim-seat card itself.

//    night-arrivals     S1.8. Live Monopoly Deal night, host view,
//                       five seats claimed and 2 of 5 arrived: Sam,
//                       Jordan and Mike still hold their deposits, so
//                       the host's arrival card lists them.
//    night-chips        A chips night half cashed out: the host and
//                       Alex scanned in (Alex up 40), Sam still
//                       playing. The host's card
//                       waits on Sam, "Settle the night" under it.
//    night-settled      S1.8. The night settled 30 minutes ago:
//                       `.justSettled` (CeremonialCard) with the
//                       host's "Plan the next night" under it.
//    recap-next-night   1.2.5. The night settled 30 minutes ago and the
//                       next one is already booked (next Friday): the
//                       recap sits above the next night's card, opens
//                       on the host's Tonight's Star (Alex), keeps the
//                       cash-out results, and ends on "Next: Fri ...".
//                       Pair with `-screenshots-as-member` for the
//                       member's "Claim your seat".
//

import Foundation

extension InMemoryRoomStore {

    /// Applies one audit-sweep seed state. Called only from the
    /// `default:` arm of the screenshot-state switch in
    /// `InMemoryRoomStore.init` (i.e. behind
    /// `-screenshots-bypass-auth`); no-ops for unknown keys so the
    /// V0.92 default behaviour is preserved.
    func applyAuditSweepSeeds(key: String, carwoola: Room, carwoolaEvent: Event) {
        let alex = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sam = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let questionBoxOff = QuestionBoxSettings(
            enabled: false, showAuthor: false, houseDeck: true,
            cadenceMinutes: 20, speakingLight: true
        )

        func liveEvent(
            name: String,
            packSlug: String,
            packSlugs: [String] = []
        ) -> Event {
            Event(id: carwoolaEvent.id, roomId: carwoola.id, name: name, playedAt: Date().addingTimeInterval(-1_500), createdAt: carwoolaEvent.createdAt, venue: carwoolaEvent.venue, hostNote: carwoolaEvent.hostNote, maxSeats: carwoolaEvent.maxSeats, settledAt: nil, sessionId: nil, packSlugs: packSlugs, packSlug: packSlug)
        }

        func upcomingEvent() -> Event {
            Event(id: carwoolaEvent.id, roomId: carwoola.id, name: carwoolaEvent.name, playedAt: sweepNextFridayEvening(), createdAt: carwoolaEvent.createdAt, venue: carwoolaEvent.venue, hostNote: carwoolaEvent.hostNote, maxSeats: carwoolaEvent.maxSeats, settledAt: nil, sessionId: carwoolaEvent.sessionId, packSlug: carwoolaEvent.packSlug, eventCalendarIdentifier: nil, hiddenFromUserIds: [])
        }

        switch key {
        case "briefing":
            // V0.107 — the pre-V0.107 briefing seed (a night two days
            // out → `.upcoming`) plus the four rows a
            // brought-by caption reads. Each one is load-bearing:
            //   rsvps         claimed seats, so the seat grid shows
            //                 who is in
            //   seedInvite    Sam came in with Alex, at tier 2 (the
            //                 tier the host queue lists)
            //   leaderboard   Sam at zero sessions — "first night" is
            //                 read off the board's `sessions_played`,
            //                 so with no board nobody reads as new
            //   currentlyInto Sam's own fresh words, so the caption's
            //                 third part renders too
            let brief = upcomingEvent()
            events[carwoola.id] = [brief]
            rsvps[brief.id] = [
                carwoola.createdBy: .claimed,
                alex: .claimed,
                sam: .claimed
            ]
            seedInvite(roomId: carwoola.id, userId: sam, invitedBy: alex, inviteTier: 2)
            // Re-point the board at the roster's stable ids. The
            // seeded carwoola board carries throwaway UUIDs on its
            // member rows, so no row can match `Member.userId` and
            // "first night" would read false for everyone. The host
            // row stays as seeded: in screenshot mode that row IS the
            // caller, and the room header reads their score from it.
            var board = leaderboards[carwoola.id] ?? []
            board.removeAll { !$0.isHost }
            board.append(
                LeaderboardEntry(
                    userId: alex,
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
                )
            )
            board.append(
                LeaderboardEntry(
                    userId: sam,
                    displayName: "Sam",
                    role: "member",
                    pointsBalance: 0,
                    seasonScore: 0,
                    sessionsPlayed: 0,
                    // nil reads "claimed a seat, never played".
                    lastSessionAt: nil,
                    lastSessionDelta: 0,
                    trajectory: []
                )
            )
            leaderboards[carwoola.id] = board
            questionBox.currentlyInto[carwoola.id] = [
                alex: CurrentlyInto(
                    text: "Learning the banjo",
                    updatedAt: Date().addingTimeInterval(-2 * 86_400)
                ),
                sam: CurrentlyInto(
                    text: "Bouldering",
                    updatedAt: Date().addingTimeInterval(-86_400)
                )
            ]

        case "tonight-live":
            events[carwoola.id] = [liveEvent(
                name: carwoolaEvent.name,
                packSlug: carwoolaEvent.packSlug
            )]
            questionBox.settings[carwoola.id] = questionBoxOff

        case "score-live":
            events[carwoola.id] = [liveEvent(
                name: "Monopoly Deal Night",
                packSlug: "monopoly_deal"
            )]
            questionBox.settings[carwoola.id] = questionBoxOff

        case "chip-scan":
            events[carwoola.id] = [liveEvent(
                name: carwoolaEvent.name,
                packSlug: "casino",
                packSlugs: ["casino", "monopoly_deal"]
            )]
            questionBox.settings[carwoola.id] = questionBoxOff

        case "settled-rich":
            let settled = Event(id: carwoolaEvent.id, roomId: carwoola.id, name: carwoolaEvent.name, playedAt: Date().addingTimeInterval(-10_800), createdAt: carwoolaEvent.createdAt, venue: carwoolaEvent.venue, hostNote: carwoolaEvent.hostNote, maxSeats: carwoolaEvent.maxSeats, settledAt: Date().addingTimeInterval(-1_800), sessionId: carwoolaEvent.sessionId, packSlug: carwoolaEvent.packSlug)
            events[carwoola.id] = [settled]
            // How the night went: everyone cashed out (the host up 60,
            // Alex up 40, Sam down 30), so the recap carries results.
            let host = carwoola.createdBy
            SweepChipSeeds.shared.set(
                eventId: settled.id,
                hands: [
                    WorkingHand(memberId: host, displayName: "Host", workingHand: 260, pointsBalance: 1_260, hasScanned: true, scannedValue: 260),
                    WorkingHand(memberId: alex, displayName: "Alex", workingHand: 240, pointsBalance: 1_020, hasScanned: true, scannedValue: 240),
                    WorkingHand(memberId: sam, displayName: "Sam", workingHand: 170, pointsBalance: 710, hasScanned: true, scannedValue: 170),
                ],
                transactions: [
                    EventTransaction(id: UUID(), memberId: host, memberDisplayName: "Host", kind: "casino_settlement", amountPoints: 60, createdAt: Date().addingTimeInterval(-2_000)),
                    EventTransaction(id: UUID(), memberId: alex, memberDisplayName: "Alex", kind: "casino_settlement", amountPoints: 40, createdAt: Date().addingTimeInterval(-2_000)),
                    EventTransaction(id: UUID(), memberId: sam, memberDisplayName: "Sam", kind: "casino_settlement", amountPoints: -30, createdAt: Date().addingTimeInterval(-2_000)),
                ]
            )
            chapterLines[settled.id] = ChapterLine(
                id: UUID(),
                roomId: carwoola.id,
                sessionId: settled.id,
                title: "Felix held the table",
                nextEpisodeTeaser: "Saturday suits tourney",
                writtenAt: Date().addingTimeInterval(-1_800)
            )
            tonightStarCards[settled.id] = TonightStarCard(
                memberId: alex,
                memberDisplayName: "Alex",
                overrideCategory: .custom,
                customText: "Read the whole table all night.",
                source: "host_pick"
            )
            leaderboards[carwoola.id] = [
                LeaderboardEntry(
                    userId: carwoola.createdBy,
                    displayName: "Host",
                    role: "host",
                    pointsBalance: 1_820,
                    seasonScore: 1_820,
                    sessionsPlayed: 15,
                    lastSessionAt: Date().addingTimeInterval(-3_600),
                    lastSessionDelta: 580,
                    trajectory: [
                        SessionDelta(sessionId: UUID(), delta: 120),
                        SessionDelta(sessionId: UUID(), delta: -40),
                        SessionDelta(sessionId: UUID(), delta: 90),
                        SessionDelta(sessionId: UUID(), delta: 580)
                    ]
                ),
                LeaderboardEntry(
                    userId: alex,
                    displayName: "Alex",
                    role: "member",
                    pointsBalance: 980,
                    seasonScore: 980,
                    sessionsPlayed: 12,
                    lastSessionAt: Date().addingTimeInterval(-3_600),
                    lastSessionDelta: 180,
                    trajectory: [
                        SessionDelta(sessionId: UUID(), delta: 60),
                        SessionDelta(sessionId: UUID(), delta: 180)
                    ]
                ),
                LeaderboardEntry(
                    userId: sam,
                    displayName: "Sam",
                    role: "member",
                    pointsBalance: 740,
                    seasonScore: 740,
                    sessionsPlayed: 10,
                    lastSessionAt: Date().addingTimeInterval(-3_600),
                    lastSessionDelta: -60,
                    trajectory: [
                        SessionDelta(sessionId: UUID(), delta: -60)
                    ]
                ),
                LeaderboardEntry(
                    userId: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                    displayName: "Jordan",
                    role: "member",
                    pointsBalance: 610,
                    seasonScore: 610,
                    sessionsPlayed: 9,
                    lastSessionAt: Date().addingTimeInterval(-3_600),
                    lastSessionDelta: 240,
                    trajectory: [
                        SessionDelta(sessionId: UUID(), delta: -180),
                        SessionDelta(sessionId: UUID(), delta: -120),
                        SessionDelta(sessionId: UUID(), delta: -90),
                        SessionDelta(sessionId: UUID(), delta: 240)
                    ]
                ),
                LeaderboardEntry(
                    userId: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                    displayName: "Mike",
                    role: "member",
                    pointsBalance: 180,
                    seasonScore: 180,
                    sessionsPlayed: 8,
                    lastSessionAt: Date().addingTimeInterval(-3_600),
                    lastSessionDelta: -210,
                    trajectory: [
                        SessionDelta(sessionId: UUID(), delta: -210),
                        SessionDelta(sessionId: UUID(), delta: -150),
                        SessionDelta(sessionId: UUID(), delta: -80)
                    ]
                )
            ]

        case "member-idle":
            events[carwoola.id] = []

        case "upcoming-partial":
            let partial = upcomingEvent()
            events[carwoola.id] = [partial]
            rsvps[partial.id] = [
                carwoola.createdBy: .claimed,
                alex: .claimed,
                sam: .claimed
            ]
            briefings[partial.id] = BriefingSummary(
                eventId: partial.id,
                roomId: carwoola.id,
                seatsTotal: 6,
                seatsClaimed: 3,
                seatsDeclined: 0,
                seatsUnclaimed: 3
            )
            questionBox.currentlyInto[carwoola.id] = [
                carwoola.createdBy: CurrentlyInto(
                    text: "Rewatching The Sopranos",
                    updatedAt: Date().addingTimeInterval(-86_400)
                ),
                alex: CurrentlyInto(
                    text: "Learning the banjo",
                    updatedAt: Date().addingTimeInterval(-2 * 86_400)
                )
            ]

        case "claim-card":
            let claimable = upcomingEvent()
            events[carwoola.id] = [claimable]
            rsvps[claimable.id] = [
                alex: .claimed,
                sam: .claimed
            ]
            briefings[claimable.id] = BriefingSummary(
                eventId: claimable.id,
                roomId: carwoola.id,
                seatsTotal: 6,
                seatsClaimed: 2,
                seatsDeclined: 0,
                seatsUnclaimed: 4
            )

        case "night-arrivals":
            // S1.8 — 2 of 5 at the table. Escrow arrival: a claimed
            // seat whose deposit is still held has not arrived.
            let jordan = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
            let mike = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
            seedExtraMember(roomId: carwoola.id, userId: jordan, displayName: "Jordan")
            seedExtraMember(roomId: carwoola.id, userId: mike, displayName: "Mike")
            let night = liveEvent(
                name: "Monopoly Deal Night",
                packSlug: "monopoly_deal",
                packSlugs: ["monopoly_deal"]
            )
            events[carwoola.id] = [night]
            rsvps[night.id] = [
                carwoola.createdBy: .claimed,
                alex: .claimed,
                sam: .claimed,
                jordan: .claimed,
                mike: .claimed
            ]
            for waiting in [sam, jordan, mike] {
                seedHeldDeposit(eventId: night.id, memberId: waiting, amount: 50)
            }
            questionBox.settings[carwoola.id] = questionBoxOff

        case "night-chips":
            // Chips night, mid-way: the host and Alex have cashed out
            // (Alex up 40, the host up 20), Sam still has chips on the
            // table.
            // The host's card waits on Sam; "Settle the night" is the
            // quiet line under it.
            let host = carwoola.createdBy
            let night = liveEvent(
                name: "Friday Chips",
                packSlug: "casino",
                packSlugs: ["casino", "monopoly_deal"]
            )
            events[carwoola.id] = [night]
            rsvps[night.id] = [host: .claimed, alex: .claimed, sam: .claimed]
            SweepChipSeeds.shared.set(
                eventId: night.id,
                hands: [
                    WorkingHand(memberId: host, displayName: "Host", workingHand: 220, pointsBalance: 1_220, hasScanned: true, scannedValue: 220),
                    WorkingHand(memberId: alex, displayName: "Alex", workingHand: 240, pointsBalance: 1_020, hasScanned: true, scannedValue: 240),
                    WorkingHand(memberId: sam, displayName: "Sam", workingHand: 200, pointsBalance: 540),
                ],
                transactions: [
                    EventTransaction(id: UUID(), memberId: host, memberDisplayName: "Host", kind: "casino_withdrawal", amountPoints: -200, createdAt: Date().addingTimeInterval(-1_400)),
                    EventTransaction(id: UUID(), memberId: alex, memberDisplayName: "Alex", kind: "casino_withdrawal", amountPoints: -200, createdAt: Date().addingTimeInterval(-1_400)),
                    EventTransaction(id: UUID(), memberId: sam, memberDisplayName: "Sam", kind: "casino_withdrawal", amountPoints: -200, createdAt: Date().addingTimeInterval(-1_400)),
                    EventTransaction(id: UUID(), memberId: host, memberDisplayName: "Host", kind: "casino_settlement", amountPoints: 20, createdAt: Date().addingTimeInterval(-300)),
                    EventTransaction(id: UUID(), memberId: alex, memberDisplayName: "Alex", kind: "casino_settlement", amountPoints: 40, createdAt: Date().addingTimeInterval(-200)),
                ]
            )
            questionBox.settings[carwoola.id] = questionBoxOff

        case "night-settled":
            // S1.8 — just settled: the recap, and the host plans the
            // next night (none is scheduled yet).
            let live = liveEvent(
                name: "Monopoly Deal Night",
                packSlug: "monopoly_deal",
                packSlugs: ["monopoly_deal"]
            )
            let settled = live.withSettledAt(Date().addingTimeInterval(-1_800))
            events[carwoola.id] = [settled]
            chapterLines[settled.id] = ChapterLine(
                id: UUID(),
                roomId: carwoola.id,
                sessionId: settled.id,
                title: "Alex took three on the trot",
                nextEpisodeTeaser: nil,
                writtenAt: Date().addingTimeInterval(-1_800)
            )

        case "recap-next-night":
            let settled = Event(id: carwoolaEvent.id, roomId: carwoola.id, name: carwoolaEvent.name, playedAt: Date().addingTimeInterval(-10_800), createdAt: carwoolaEvent.createdAt, venue: carwoolaEvent.venue, hostNote: carwoolaEvent.hostNote, maxSeats: carwoolaEvent.maxSeats, settledAt: Date().addingTimeInterval(-1_800), sessionId: carwoolaEvent.sessionId, packSlug: carwoolaEvent.packSlug)
            let next = Event(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a7")!, roomId: carwoola.id, name: EventDefaultName.name(for: sweepNextFridayEvening()), playedAt: sweepNextFridayEvening(), createdAt: Date().addingTimeInterval(-1_500), venue: carwoolaEvent.venue, hostNote: nil, maxSeats: 6, settledAt: nil, sessionId: nil, packSlug: "casino")
            events[carwoola.id] = [settled, next]
            briefings[next.id] = BriefingSummary(
                eventId: next.id,
                roomId: carwoola.id,
                seatsTotal: 6,
                seatsClaimed: 0,
                seatsDeclined: 0,
                seatsUnclaimed: 6
            )
            let host = carwoola.createdBy
            SweepChipSeeds.shared.set(
                eventId: settled.id,
                hands: [
                    WorkingHand(memberId: host, displayName: "Host", workingHand: 260, pointsBalance: 1_260, hasScanned: true, scannedValue: 260),
                    WorkingHand(memberId: alex, displayName: "Alex", workingHand: 240, pointsBalance: 1_020, hasScanned: true, scannedValue: 240),
                    WorkingHand(memberId: sam, displayName: "Sam", workingHand: 170, pointsBalance: 710, hasScanned: true, scannedValue: 170),
                ],
                transactions: [
                    EventTransaction(id: UUID(), memberId: host, memberDisplayName: "Host", kind: "casino_settlement", amountPoints: 60, createdAt: Date().addingTimeInterval(-2_000)),
                    EventTransaction(id: UUID(), memberId: alex, memberDisplayName: "Alex", kind: "casino_settlement", amountPoints: 40, createdAt: Date().addingTimeInterval(-2_000)),
                    EventTransaction(id: UUID(), memberId: sam, memberDisplayName: "Sam", kind: "casino_settlement", amountPoints: -30, createdAt: Date().addingTimeInterval(-2_000)),
                ]
            )
            chapterLines[settled.id] = ChapterLine(
                id: UUID(),
                roomId: carwoola.id,
                sessionId: settled.id,
                title: "Felix held the table",
                nextEpisodeTeaser: nil,
                writtenAt: Date().addingTimeInterval(-1_800)
            )
            tonightStarCards[settled.id] = TonightStarCard(
                memberId: alex,
                memberDisplayName: "Alex",
                overrideCategory: .custom,
                customText: "Read the whole table all night.",
                source: "host_pick"
            )
            questionBox.settings[carwoola.id] = questionBoxOff

        default:
            break
        }
    }
}

/// Upcoming sweep event: next Friday 7:30 pm local, at least a day out,
/// so captures read like a real games night (App Store screenshots).
func sweepNextFridayEvening(from now: Date = Date()) -> Date {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    var c = DateComponents(); c.weekday = 6; c.hour = 19; c.minute = 30
    let start = now.addingTimeInterval(86_400)
    return cal.nextDate(after: start, matching: c, matchingPolicy: .nextTime) ?? start
}

/// The sweep's chip reads. `CasinoService` reads working hands and
/// event transactions straight from Supabase, which returns nothing
/// under `-screenshots-bypass-auth`; a seed that needs a chips night
/// files its rows here and the service answers from them first. Empty
/// in production: nothing outside a sweep seed ever writes to it.
final class SweepChipSeeds: @unchecked Sendable {
    static let shared = SweepChipSeeds()
    private let lock = NSLock()
    private var hands: [UUID: [WorkingHand]] = [:]
    private var transactions: [UUID: [EventTransaction]] = [:]

    func set(eventId: UUID, hands: [WorkingHand], transactions: [EventTransaction]) {
        lock.lock(); defer { lock.unlock() }
        self.hands[eventId] = hands
        self.transactions[eventId] = transactions
    }

    func hands(eventId: UUID) -> [WorkingHand]? {
        lock.lock(); defer { lock.unlock() }
        return hands[eventId]
    }

    func transactions(eventId: UUID) -> [EventTransaction]? {
        lock.lock(); defer { lock.unlock() }
        return transactions[eventId]
    }
}
