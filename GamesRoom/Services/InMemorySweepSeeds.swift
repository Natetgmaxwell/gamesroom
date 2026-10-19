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
            Event(
                id: carwoolaEvent.id,
                roomId: carwoola.id,
                name: name,
                playedAt: Date().addingTimeInterval(-1_500),
                createdAt: carwoolaEvent.createdAt,
                venue: carwoolaEvent.venue,
                hostNote: carwoolaEvent.hostNote,
                maxSeats: carwoolaEvent.maxSeats,
                startedAt: Date().addingTimeInterval(-1_500),
                settledAt: nil,
                sessionId: nil,
                packSlugs: packSlugs,
                packSlug: packSlug,
                hostFinalized: false
            )
        }

        func upcomingEvent() -> Event {
            Event(
                id: carwoolaEvent.id,
                roomId: carwoola.id,
                name: carwoolaEvent.name,
                playedAt: Date().addingTimeInterval(86_400 * 2),
                createdAt: carwoolaEvent.createdAt,
                venue: carwoolaEvent.venue,
                hostNote: carwoolaEvent.hostNote,
                maxSeats: carwoolaEvent.maxSeats,
                startedAt: nil,
                settledAt: nil,
                sessionId: carwoolaEvent.sessionId,
                packSlug: carwoolaEvent.packSlug,
                hostFinalized: false,
                eventCalendarIdentifier: nil,
                hiddenFromUserIds: []
            )
        }

        switch key {
        case "tonight-live":
            events[carwoola.id] = liveEvent(
                name: carwoolaEvent.name,
                packSlug: carwoolaEvent.packSlug
            )
            questionBox.settings[carwoola.id] = questionBoxOff

        case "score-live":
            events[carwoola.id] = liveEvent(
                name: "Monopoly Deal Night",
                packSlug: "monopoly_deal"
            )
            questionBox.settings[carwoola.id] = questionBoxOff

        case "chip-scan":
            events[carwoola.id] = liveEvent(
                name: carwoolaEvent.name,
                packSlug: "casino",
                packSlugs: ["casino", "monopoly_deal"]
            )
            questionBox.settings[carwoola.id] = questionBoxOff

        case "settled-rich":
            let settled = Event(
                id: carwoolaEvent.id,
                roomId: carwoola.id,
                name: carwoolaEvent.name,
                playedAt: Date().addingTimeInterval(-10_800),
                createdAt: carwoolaEvent.createdAt,
                venue: carwoolaEvent.venue,
                hostNote: carwoolaEvent.hostNote,
                maxSeats: carwoolaEvent.maxSeats,
                startedAt: Date().addingTimeInterval(-10_800),
                settledAt: Date().addingTimeInterval(-1_800),
                sessionId: carwoolaEvent.sessionId,
                packSlug: carwoolaEvent.packSlug,
                hostFinalized: false
            )
            events[carwoola.id] = settled
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
                customText: "nOtHiNg AbOuT tHaT wAs LeGaL",
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
            events[carwoola.id] = nil

        case "upcoming-partial":
            let partial = upcomingEvent()
            events[carwoola.id] = partial
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
            events[carwoola.id] = claimable
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

        default:
            break
        }
    }
}
