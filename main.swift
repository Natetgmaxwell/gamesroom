//
//  tests.swift
//
//  Single-file Foundation test runner for games-room's
//  Foundation-only slice. Compiled and run with:
//
//      swiftc -parse-as-library \
//             -target arm64-apple-macosx14.0 \
//             -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
//             tests.swift GamesRoom/Models/*.swift \
//                      GamesRoom/Packs/*.swift \
//             -o tests && ./tests
//
//  `tests.swift` is intentionally one file (not a Swift package)
//  to side-step a Swift Package Manager limitation in the
//  CommandLineTools 6.2.4 SDK: the toolchain emits
//  swiftmodule files that other toolchain-invocation contexts
//  can't read, so a multi-target SPM build produces "cannot find
//  type X in scope" errors even when the symbols are present.
//  Compiling everything in one invocation avoids the issue.
//
//  Coverage mirrors what an XCTestCase file would look like:
//  PackRegistry lookup, PackScoringResolver for both families,
//  Room / Event / BriefingSummary / RedeemedRoom / ScoreEntry /
//  PackMetaValue / MemberRSVPState JSON round-trips.
//

import Foundation
import CoreGraphics

// MARK: - Test primitives

final class TestRunner {
    var passes = 0
    var failures: [String] = []
    var currentName = "<unknown>"

    func assertEqual<T: Equatable>(_ actual: T, _ expected: T,
                                  file: StaticString = #file,
                                  line: UInt = #line) {
        if actual != expected {
            failures.append("[\(currentName)] \(file):\(line) — expected \(expected), got \(actual)")
        }
    }

    func assertTrue(_ value: Bool, _ message: String = "",
                    file: StaticString = #file,
                    line: UInt = #line) {
        if !value {
            failures.append("[\(currentName)] \(file):\(line) — expected true: \(message)")
        }
    }

    func assertFalse(_ value: Bool, _ message: String = "",
                     file: StaticString = #file,
                     line: UInt = #line) {
        if value {
            failures.append("[\(currentName)] \(file):\(line) — expected false: \(message)")
        }
    }

    func assertNotNil<T>(_ value: T?, _ message: String = "",
                        file: StaticString = #file,
                        line: UInt = #line) {
        if value == nil {
            failures.append("[\(currentName)] \(file):\(line) — expected non-nil: \(message)")
        }
    }

    func assertNil<T>(_ value: T?, _ message: String = "",
                     file: StaticString = #file,
                     line: UInt = #line) {
        if value != nil {
            failures.append("[\(currentName)] \(file):\(line) — expected nil: \(message)")
        }
    }

    func run(_ name: String, _ block: () throws -> Void) {
        currentName = name
        let prior = failures.count
        do {
            try block()
            if failures.count == prior {
                print("ok   \(name)")
                passes += 1
            } else {
                print("FAIL \(name)")
                for f in failures.suffix(failures.count - prior) {
                    print("       \(f)")
                }
            }
        } catch {
            print("FAIL \(name) — threw \(error)")
            failures.append("[\(name)] threw \(error)")
        }
    }
}

let runner = TestRunner()

// MARK: - StorageKeys tests (T1.2)

runner.run("StorageKeys.keepScanPhotos defaults to false") {
    let defaults = UserDefaults(suiteName: "test-keepScanPhotos-default")!
    defaults.removePersistentDomain(forName: "test-keepScanPhotos-default")
    runner.assertFalse(defaults.bool(forKey: StorageKeys.keepScanPhotos))
}

runner.run("StorageKeys.keepScanPhotos round-trips") {
    let defaults = UserDefaults(suiteName: "test-keepScanPhotos-roundtrip")!
    defaults.removePersistentDomain(forName: "test-keepScanPhotos-roundtrip")
    defaults.set(true, forKey: StorageKeys.keepScanPhotos)
    runner.assertTrue(defaults.bool(forKey: StorageKeys.keepScanPhotos))
    defaults.set(false, forKey: StorageKeys.keepScanPhotos)
    runner.assertFalse(defaults.bool(forKey: StorageKeys.keepScanPhotos))
}

runner.run("StorageKeys.calendarEventIdentifier is stable per event") {
    let id = UUID()
    let first = StorageKeys.calendarEventIdentifier(eventId: id)
    let second = StorageKeys.calendarEventIdentifier(eventId: id)
    runner.assertEqual(first, second)
    runner.assertTrue(first.contains(id.uuidString))
}

// MARK: - PackRegistry tests

runner.run("PackRegistry default registry holds four V0.8 packs") {
    let slugs = PackRegistry.shared.allPacks.map { $0.slug }
    runner.assertEqual(slugs, ["casino", "cards_against_humanity", "monopoly_deal", "pluto_chess"])
}

runner.run("PackRegistry isRegistered rejects legacy / unknown slugs") {
    runner.assertFalse(PackRegistry.shared.isRegistered(slug: "monopoly-deal"))
    runner.assertFalse(PackRegistry.shared.isRegistered(slug: "blackjack"))
    runner.assertFalse(PackRegistry.shared.isRegistered(slug: ""))
    runner.assertFalse(PackRegistry.shared.isRegistered(slug: "unknown-pack"))
    runner.assertTrue(PackRegistry.shared.isRegistered(slug: "casino"))
    runner.assertTrue(PackRegistry.shared.isRegistered(slug: "pluto_chess"))
}

runner.run("Pack scoring types match migration 034") {
    runner.assertEqual(CasinoPack.scoringType, .withdrawReturn)
    runner.assertEqual(CardsAgainstHumanityPack.scoringType, .singleWinner)
    runner.assertEqual(MonopolyDealPack.scoringType, .singleWinner)
    runner.assertEqual(PlutoChessPack.scoringType, .singleWinner)
}

runner.run("PackRegistry winPoints single-winner packs return 1") {
    runner.assertEqual(PackRegistry.shared.winPoints(for: "cards_against_humanity"), 1)
    runner.assertEqual(PackRegistry.shared.winPoints(for: "monopoly_deal"), 1)
    runner.assertEqual(PackRegistry.shared.winPoints(for: "pluto_chess"), 1)
    runner.assertEqual(PackRegistry.shared.winPoints(for: "casino"), 0)
    runner.assertEqual(PackRegistry.shared.winPoints(for: "unknown"), 1)
}

// MARK: - PackScoringResolver tests

runner.run("PackScoringResolver singleWinner produces one entry for winner") {
    let winnerId = UUID()
    let input = PackScoringInput.singleWinner(
        roundIndex: 3,
        winnerMemberId: winnerId,
        winPoints: 1
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "cards_against_humanity")
    runner.assertEqual(entries.count, 1)
    runner.assertEqual(entries[0].memberId, winnerId)
    runner.assertEqual(entries[0].pointsDelta, 1)
    runner.assertEqual(entries[0].meta["winner"], .bool(true))
}

runner.run("PackScoringResolver multiWinner produces one entry per winner") {
    let alice = UUID()
    let bob = UUID()
    let input = PackScoringInput.multiWinner(
        roundIndex: 4,
        winnerMemberIds: [alice, bob],
        winPoints: 1
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "cards_against_humanity")
    runner.assertEqual(entries.count, 2)
    let aliceRow = entries.first { $0.memberId == alice }
    let bobRow   = entries.first { $0.memberId == bob }
    runner.assertEqual(aliceRow?.pointsDelta, 1)
    runner.assertEqual(bobRow?.pointsDelta, 1)
    runner.assertEqual(aliceRow?.meta["winner"], .bool(true))
    runner.assertEqual(aliceRow?.meta["round_index"], .int(4))
}

runner.run("PackScoringResolver multiWinner empty list produces no entries") {
    let input = PackScoringInput.multiWinner(
        roundIndex: 1,
        winnerMemberIds: [],
        winPoints: 1
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "pluto_chess")
    runner.assertEqual(entries.count, 0)
}

runner.run("PackScoringInput multiWinner packSlug resolves to single_winner family") {
    let input = PackScoringInput.multiWinner(
        roundIndex: 1,
        winnerMemberIds: [UUID()],
        winPoints: 1
    )
    runner.assertEqual(input.packSlug, "single_winner")
}

runner.run("PackScoringResolver withdrawReturn emits one entry per member with net delta") {
    let alice = UUID()
    let bob = UUID()
    let input = PackScoringInput.withdrawReturn(
        roundIndex: 1,
        perMember: [
            MemberNet(memberId: alice, withdrawnPoints: 50, returnedPoints: 70),
            MemberNet(memberId: bob,   withdrawnPoints: 50, returnedPoints: 30)
        ]
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "casino")
    runner.assertEqual(entries.count, 2)
    let aliceRow = entries.first { $0.memberId == alice }
    let bobRow   = entries.first { $0.memberId == bob }
    runner.assertEqual(aliceRow?.pointsDelta, 20)
    runner.assertEqual(bobRow?.pointsDelta, -20)
    runner.assertEqual(aliceRow?.meta["withdrawn"], .int(50))
    runner.assertEqual(aliceRow?.meta["returned"], .int(70))
}

runner.run("PackScoringResolver withdrawReturn zero-returned records zero delta") {
    let member = UUID()
    let input = PackScoringInput.withdrawReturn(
        roundIndex: 2,
        perMember: [MemberNet(memberId: member, withdrawnPoints: 50, returnedPoints: 0)]
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "casino")
    runner.assertEqual(entries.first?.pointsDelta, -50)
}

runner.run("ScoreEntry JSON round-trip preserves the typed meta") {
    let entry = ScoreEntry(
        memberId: UUID(),
        pointsDelta: 5,
        meta: ["winner": .bool(true), "round_index": .int(Int64(7))]
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(entry)
    let decoded = try JSONDecoder().decode(ScoreEntry.self, from: data)
    runner.assertEqual(decoded.memberId, entry.memberId)
    runner.assertEqual(decoded.pointsDelta, 5)
    runner.assertEqual(decoded.meta["winner"], .bool(true))
    runner.assertEqual(decoded.meta["round_index"], .int(7))
}

// MARK: - Room decoding

runner.run("Room decodes full V0.26 + host_journal shape") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Friday Night Hold'em",
      "mascot_name": "Borat",
      "mascot_personality": "snarky",
      "mascot_political_ideology": "anarchist",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-02-01T00:00:00Z",
      "is_live": true,
      "next_event_description": "Tonight 8pm",
      "join_starting_bonus": 250,
      "user_role": "host",
      "briefing_48h_enabled": true,
      "calendar_auto_add_host": false,
      "social_preferences_enabled": true,
      "social_narration_enabled": false,
      "max_seats": 8,
      "member_invite_quota": 4,
      "host_journal": "Bring your own chips."
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.name, "Friday Night Hold'em")
    runner.assertEqual(room.joinStartingBonus, 250)
    runner.assertEqual(room.maxSeats, 8)
    runner.assertEqual(room.memberInviteQuota, 4)
    runner.assertEqual(room.userRole, .host)
    runner.assertTrue(room.briefing48hEnabled)
    runner.assertFalse(room.calendarAutoAddHost)
    runner.assertFalse(room.socialNarrationEnabled)
    runner.assertEqual(room.hostJournal, "Bring your own chips.")
}

runner.run("Room falls back to defaults when V0.26 columns missing") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Old Room",
      "mascot_name": "Felty",
      "mascot_personality": "professional",
      "mascot_political_ideology": "order",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-02T00:00:00Z",
      "is_live": false,
      "join_starting_bonus": 200,
      "user_role": "member"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertTrue(room.briefing48hEnabled)
    runner.assertEqual(room.maxSeats, 6)
    runner.assertEqual(room.memberInviteQuota, 3)
    runner.assertNil(room.hostJournal)
}

// MARK: - RedeemedRoom decoding

runner.run("RedeemedRoom decodes server shape (room_id, room_name)") {
    let json = """
    {
      "room_id": "33333333-3333-3333-3333-333333333333",
      "room_name": "Carwoola Crew"
    }
    """
    let decoded = try JSONDecoder().decode(RedeemedRoom.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.roomId.uuidString, "33333333-3333-3333-3333-333333333333")
    runner.assertEqual(decoded.roomName, "Carwoola Crew")
    runner.assertEqual(decoded.id, decoded.roomId)
}

runner.run("RedeemedRoom falls back to 'Room' when name missing") {
    let json = """
    {
      "room_id": "33333333-3333-3333-3333-333333333333"
    }
    """
    let decoded = try JSONDecoder().decode(RedeemedRoom.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.roomName, "Room")
}

// MARK: - BriefingSummary

runner.run("BriefingSummary seatsLeft = total - claimed - declined") {
    let summary = BriefingSummary(
        eventId: UUID(), roomId: UUID(),
        seatsTotal: 6, seatsClaimed: 2, seatsDeclined: 1, seatsUnclaimed: 3
    )
    runner.assertEqual(summary.seatsLeft, 3)
}

runner.run("BriefingSummary seatsLeft floors at zero") {
    let summary = BriefingSummary(
        eventId: UUID(), roomId: UUID(),
        seatsTotal: 4, seatsClaimed: 3, seatsDeclined: 2, seatsUnclaimed: -1
    )
    runner.assertEqual(summary.seatsLeft, 0)
}

// MARK: - Event round-trip

runner.run("Event JSON round-trip preserves venue + hostNote") {
    let event = Event(
        id: UUID(), roomId: UUID(),
        name: "Friday Night Hold'em",
        playedAt: Date(timeIntervalSince1970: 1_700_000_000),
        createdAt: Date(timeIntervalSince1970: 1_699_900_000),
        venue: "The dining room",
        hostNote: "Bring snacks.",
        maxSeats: 6,
        startedAt: nil, settledAt: nil, sessionId: nil, hostFinalized: false
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(event)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Event.self, from: data)
    runner.assertEqual(decoded.id, event.id)
    runner.assertEqual(decoded.name, event.name)
    runner.assertEqual(decoded.venue, event.venue)
    runner.assertEqual(decoded.hostNote, event.hostNote)
}

// MARK: - RSVP

runner.run("MemberRSVPState hasResponded logic") {
    runner.assertFalse(MemberRSVPState.unclaimed.hasResponded)
    runner.assertTrue(MemberRSVPState.claimed.hasResponded)
    runner.assertTrue(MemberRSVPState.declined.hasResponded)
}

runner.run("MemberRSVPState round-trips through rawValue") {
    for state in MemberRSVPState.allCases {
        let decoded = MemberRSVPState(rawValue: state.rawValue)
        runner.assertEqual(decoded, state)
    }
}

runner.run("MemberRSVP decodes server shape with responded_at") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "event_id": "22222222-2222-2222-2222-222222222222",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "state": "claimed",
      "responded_at": "2026-02-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(MemberRSVP.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.state, .claimed)
    runner.assertNotNil(decoded.respondedAt)
}

// MARK: - PackMetaValue encoding round-trip

runner.run("PackMetaValue bool and int round-trip") {
    let meta: [String: PackMetaValue] = [
        "flag": .bool(true),
        "count": .int(Int64(42))
    ]
    let data = try JSONEncoder().encode(meta)
    let decoded = try JSONDecoder().decode([String: PackMetaValue].self, from: data)
    runner.assertEqual(decoded["flag"], .bool(true))
    runner.assertEqual(decoded["count"], .int(42))
}

runner.run("PackMetaValue string round-trip") {
    let meta: [String: PackMetaValue] = ["reason": .string("host override")]
    let data = try JSONEncoder().encode(meta)
    let decoded = try JSONDecoder().decode([String: PackMetaValue].self, from: data)
    runner.assertEqual(decoded["reason"], .string("host override"))
}

// MARK: - LeaderboardEntry trajectory

runner.run("LeaderboardEntry round-trip preserves trajectory") {
    let entry = LeaderboardEntry(
        userId: UUID(),
        displayName: "Alex",
        role: "member",
        pointsBalance: 980,
        seasonScore: 980,
        sessionsPlayed: 12,
        lastSessionAt: Date(timeIntervalSince1970: 1_699_000_000),
        lastSessionDelta: 180,
        trajectory: [
            SessionDelta(sessionId: UUID(), delta: 60),
            SessionDelta(sessionId: UUID(), delta: 180)
        ]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(LeaderboardEntry.self, from: data)
    runner.assertEqual(decoded.userId, entry.userId)
    runner.assertEqual(decoded.trajectory.count, 2)
    runner.assertEqual(decoded.trajectory[1].delta, 180)
}

runner.run("LeaderboardEntry scoreCorrectedAt decodes and isRecentlyCorrected fires within 60s") {
    let recentCorrection = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-10))
    let json = """
    {
      "user_id": "55555555-5555-5555-5555-555555555555",
      "display_name": "Thea",
      "role": "member",
      "points_balance": 1240,
      "season_score": 1240,
      "sessions_played": 6,
      "last_session_at": "2026-08-01T00:00:00Z",
      "last_session_delta": 80,
      "trajectory": [],
      "score_corrected_at": "\(recentCorrection)"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entry = try decoder.decode(LeaderboardEntry.self, from: json.data(using: .utf8)!)
    runner.assertNotNil(entry.scoreCorrectedAt)
    runner.assertTrue(entry.isRecentlyCorrected)
}

runner.run("LeaderboardEntry without score_corrected_at decodes nil and isRecentlyCorrected is false") {
    let json = """
    {
      "user_id": "66666666-6666-6666-6666-666666666666",
      "display_name": "Marco",
      "role": "member",
      "points_balance": 720,
      "season_score": 720,
      "sessions_played": 4,
      "trajectory": []
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let entry = try decoder.decode(LeaderboardEntry.self, from: json.data(using: .utf8)!)
    runner.assertNil(entry.scoreCorrectedAt)
    runner.assertFalse(entry.isRecentlyCorrected)
}

// MARK: - SeatDeposit + Room seat_deposit_amount

runner.run("SeatDeposit decodes held status from server shape") {
    let json = """
    {
      "id": "77777777-7777-7777-7777-777777777777",
      "amount": 50,
      "status": "held",
      "held_at": "2026-08-05T12:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let deposit = try decoder.decode(SeatDeposit.self, from: json.data(using: .utf8)!)
    runner.assertEqual(deposit.amount, 50)
    runner.assertEqual(deposit.status, .held)
    runner.assertFalse(deposit.isResolved)
}

runner.run("SeatDeposit forfeited status is resolved") {
    let json = """
    {
      "id": "88888888-8888-8888-8888-888888888888",
      "amount": 30,
      "status": "forfeited",
      "held_at": "2026-08-01T00:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let deposit = try decoder.decode(SeatDeposit.self, from: json.data(using: .utf8)!)
    runner.assertEqual(deposit.status, .forfeited)
    runner.assertTrue(deposit.isResolved)
}

runner.run("Room decodes seat_deposit_amount from server shape") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Deposit Room",
      "mascot_name": "Borat",
      "mascot_personality": "snarky",
      "mascot_political_ideology": "centrist",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-02-01T00:00:00Z",
      "is_live": true,
      "join_starting_bonus": 200,
      "user_role": "member",
      "seat_deposit_amount": 50
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.seatDepositAmount, 50)
}

runner.run("Room defaults seat_deposit_amount to 0 when column missing") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Legacy Room",
      "mascot_name": "Felty",
      "mascot_personality": "professional",
      "mascot_political_ideology": "order",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-01-02T00:00:00Z",
      "is_live": false,
      "join_starting_bonus": 200,
      "user_role": "member"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.seatDepositAmount, 0)
}

runner.run("Room decodes member_drowning_opt_in true from server shape") {
    // Migration 044+045: the current user's per-room opt-in for the
    // Drowning row share. The default is false (privacy-respecting).
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Opted-in Room",
      "mascot_name": "Felty",
      "mascot_personality": "professional",
      "mascot_political_ideology": "order",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-02-01T00:00:00Z",
      "is_live": true,
      "join_starting_bonus": 200,
      "user_role": "member",
      "member_drowning_opt_in": true
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.memberDrowningOptIn, true)
}

runner.run("Room defaults member_drowning_opt_in to false when column missing") {
    // Pre-migration-045 server shape (or member who has never set the
    // flag). Defaults to false — the privacy-respecting default.
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "name": "Pre-migration Room",
      "mascot_name": "Borat",
      "mascot_personality": "snarky",
      "mascot_political_ideology": "centrist",
      "created_by": "22222222-2222-2222-2222-222222222222",
      "created_at": "2026-01-01T00:00:00Z",
      "updated_at": "2026-02-01T00:00:00Z",
      "is_live": true,
      "join_starting_bonus": 200,
      "user_role": "member"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.memberDrowningOptIn, false)
}

runner.run("PackHowToCatalog returns bundled content for casino") {
    let howTo = PackHowToCatalog.howTo(forSlug: "casino")
    runner.assertNotNil(howTo)
    runner.assertEqual(howTo?.headline, "How to play Casino")
    runner.assertTrue(howTo?.sections.count ?? 0 >= 3)
}

runner.run("PackHowToCatalog returns bundled content for all four V0.8 packs") {
    let slugs = ["casino", "cards_against_humanity", "monopoly_deal", "pluto_chess"]
    for slug in slugs {
        runner.assertNotNil(
            PackHowToCatalog.howTo(forSlug: slug),
            "Missing how-to for \(slug)"
        )
    }
}

runner.run("PackHowToCatalog returns nil for unknown slugs") {
    runner.assertNil(PackHowToCatalog.howTo(forSlug: "no_such_pack"))
    runner.assertNil(PackHowToCatalog.howTo(forSlug: ""))
}

runner.run("PackDefinition default howToSlug falls back to slug") {
    runner.assertEqual(CasinoPack.howToSlug, "casino")
    runner.assertEqual(CardsAgainstHumanityPack.howToSlug, "cards_against_humanity")
    runner.assertEqual(MonopolyDealPack.howToSlug, "monopoly_deal")
    runner.assertEqual(PlutoChessPack.howToSlug, "pluto_chess")
}

// MARK: - EventRSVP (2026-08-10 feedback round)

runner.run("EventRSVP decodes server shape with display_name") {
    let json = """
    {
      "event_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "display_name": "Alex",
      "state": "claimed"
    }
    """
    let decoded = try JSONDecoder().decode(EventRSVP.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.eventId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    runner.assertEqual(decoded.memberId, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
    runner.assertEqual(decoded.displayName, "Alex")
    runner.assertEqual(decoded.state, .claimed)
}

runner.run("EventRSVP defaults missing state to unclaimed") {
    let json = """
    {
      "event_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "display_name": "Sam"
    }
    """
    let decoded = try JSONDecoder().decode(EventRSVP.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.state, .unclaimed)
    runner.assertEqual(decoded.displayName, "Sam")
}

runner.run("EventRSVP id is stable composite of event + member") {
    let eventId = UUID()
    let memberId = UUID()
    let rsvp = EventRSVP(eventId: eventId, memberId: memberId, displayName: "Alex", state: .claimed)
    runner.assertEqual(rsvp.id, "\(eventId.uuidString):\(memberId.uuidString)")
}

// MARK: - RoomPackConfig (2026-08-10 feedback round)

runner.run("RoomPackConfig decodes server shape with win_points") {
    let json = """
    {
      "room_id": "33333333-3333-3333-3333-333333333333",
      "pack_slug": "monopoly_deal",
      "win_points": 25
    }
    """
    let decoded = try JSONDecoder().decode(RoomPackConfig.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.roomId, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    runner.assertEqual(decoded.packSlug, "monopoly_deal")
    runner.assertEqual(decoded.winPoints, 25)
}

runner.run("RoomPackConfig defaults missing win_points to 1") {
    let json = """
    {
      "room_id": "33333333-3333-3333-3333-333333333333",
      "pack_slug": "pluto_chess"
    }
    """
    let decoded = try JSONDecoder().decode(RoomPackConfig.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.winPoints, 1)
}

runner.run("RoomPackConfig id is stable composite of room + pack") {
    let roomId = UUID()
    let config = RoomPackConfig(roomId: roomId, packSlug: "casino", winPoints: 0)
    runner.assertEqual(config.id, "\(roomId.uuidString):casino")
}

// MARK: - EventRound + Member.team (W1.6 — team mode + per-round breakdown)

runner.run("EventRound decodes server shape with entries array") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "event_id": "22222222-2222-2222-2222-222222222222",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "pack_slug": "cards_against_humanity",
      "round_index": 2,
      "entries": [
        {"member_id": "44444444-4444-4444-4444-444444444444", "points_delta": 1, "meta": {"winner": true, "round_index": 2}},
        {"member_id": "55555555-5555-5555-5555-555555555555", "points_delta": 1, "meta": {"winner": true, "round_index": 2}}
      ],
      "created_by": "66666666-6666-6666-6666-666666666666",
      "created_at": "2026-08-10T12:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EventRound.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.roundIndex, 2)
    runner.assertEqual(decoded.packSlug, "cards_against_humanity")
    runner.assertEqual(decoded.entries.count, 2)
    runner.assertEqual(decoded.entries.first?.pointsDelta, 1)
    runner.assertEqual(decoded.entries.first?.memberId, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
}

runner.run("EventRound defaults missing entries to empty") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "event_id": "22222222-2222-2222-2222-222222222222",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "pack_slug": "pluto_chess",
      "round_index": 1,
      "created_by": "66666666-6666-6666-6666-666666666666",
      "created_at": "2026-08-10T12:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EventRound.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.entries.count, 0)
    runner.assertEqual(decoded.roundIndex, 1)
}

runner.run("Member decodes team column and defaults to nil") {
    let json = """
    {
      "id": "33333333-3333-3333-3333-333333333333:44444444-4444-4444-4444-444444444444",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "user_id": "44444444-4444-4444-4444-444444444444",
      "role": "member",
      "joined_at": "2026-08-01T12:00:00Z",
      "display_name": "Alex",
      "team": "Red"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Member.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.team, "Red")

    let noTeam = """
    {
      "id": "33333333-3333-3333-3333-333333333333:44444444-4444-4444-4444-444444444444",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "user_id": "44444444-4444-4444-4444-444444444444",
      "role": "member",
      "joined_at": "2026-08-01T12:00:00Z",
      "display_name": "Alex"
    }
    """
    let decodedNoTeam = try decoder.decode(Member.self, from: noTeam.data(using: .utf8)!)
    runner.assertEqual(decodedNoTeam.team, nil)
}

// MARK: - CatchUpMessage (W2.7 — joined-late catch-up)

runner.run("CatchUpMessage upcoming event names date and claims seat") {
    let body = CatchUpMessage.body(
        eventName: "Friday Night Hold'em",
        playedAt: Date().addingTimeInterval(86_400),
        mascotName: "Felty",
        leaderboardSummary: "Alex 120 · Sam 80",
        rsvpState: .unclaimed
    )
    runner.assertTrue(body.contains("Friday Night Hold'em"), "event name missing")
    runner.assertTrue(body.contains("Felty"), "mascot name missing")
    runner.assertTrue(body.contains("Alex 120"), "standings missing")
    runner.assertTrue(body.contains("Claim your seat"), "unclaimed nudge missing")
}

runner.run("CatchUpMessage claimed state says you're in") {
    let body = CatchUpMessage.body(
        eventName: "Pluto Chess Sunday",
        playedAt: Date().addingTimeInterval(86_400),
        mascotName: "Felty",
        leaderboardSummary: "",
        rsvpState: .claimed
    )
    runner.assertTrue(body.contains("You're in"), "claimed confirmation missing")
    runner.assertFalse(body.contains("Claim your seat"), "claimed state should not nudge")
}

runner.run("CatchUpMessage live event names state of play") {
    let body = CatchUpMessage.body(
        eventName: "Casino Night",
        playedAt: Date().addingTimeInterval(-3600),
        mascotName: "Felty",
        leaderboardSummary: "Alex 120 · Sam 80",
        rsvpState: .unclaimed
    )
    runner.assertTrue(body.contains("is live"), "live marker missing")
    runner.assertTrue(body.contains("Alex 120"), "standings missing")
}

// MARK: - CasinoWithdrawal (W1.4 — settle-sheet withdrawal wiring)

runner.run("CasinoWithdrawal decodes server shape with points_withdrawn") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "session_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "points_withdrawn": 120,
      "withdrawn_at": "2026-08-10T12:00:00Z",
      "withdrawn_by": "55555555-5555-5555-5555-555555555555"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CasinoWithdrawal.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    runner.assertEqual(decoded.pointsWithdrawn, 120)
    runner.assertEqual(decoded.memberId, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
}

runner.run("CasinoWithdrawal round-trips through JSON encoder") {
    let withdrawal = CasinoWithdrawal(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        sessionId: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        memberId: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        pointsWithdrawn: 80,
        withdrawnAt: Date(timeIntervalSince1970: 1_752_000_000),
        withdrawnBy: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    )
    let data = try JSONEncoder().encode(withdrawal)
    let decoded = try JSONDecoder().decode(CasinoWithdrawal.self, from: data)
    runner.assertEqual(decoded.pointsWithdrawn, 80)
    runner.assertEqual(decoded.withdrawnAt, withdrawal.withdrawnAt)
}

// MARK: - ChipSegmentationDetector + PhotoHash (F-CAS-02 / F-CAS-03)

/// Draws a synthetic chip-stack test image: a felt-colored canvas
/// with one or more solid-color discs (chip stacks). Mirrors the
/// probe's SyntheticCorpusGenerator drawing approach so the app
/// detector is exercised on the same visual class it was locked on.
func makeTestImage(
    width: Int,
    height: Int,
    felt: (r: Double, g: Double, b: Double),
    stacks: [(x: Int, y: Int, radius: Int, color: (r: Double, g: Double, b: Double))]
) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(red: felt.r, green: felt.g, blue: felt.b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    for stack in stacks {
        ctx.setFillColor(CGColor(red: stack.color.r, green: stack.color.g, blue: stack.color.b, alpha: 1))
        ctx.fillEllipse(in: CGRect(
            x: stack.x - stack.radius,
            y: stack.y - stack.radius,
            width: stack.radius * 2,
            height: stack.radius * 2
        ))
    }
    return ctx.makeImage()!
}

runner.run("ChipSegmentationDetector finds a red stack on green felt") {
    let image = makeTestImage(width: 400, height: 400, felt: (0.10, 0.42, 0.18), stacks: [
        (x: 200, y: 200, radius: 40, color: (0.85, 0.10, 0.10))
    ])
    let stacks = ChipSegmentationDetector().detect(cg: image)
    runner.assertEqual(stacks.count, 1)
    runner.assertEqual(stacks.first?.chipColor, .red)
    runner.assertTrue((stacks.first?.count ?? 0) >= 1)
}

runner.run("ChipSegmentationDetector finds nothing on pure felt") {
    let image = makeTestImage(width: 400, height: 400, felt: (0.10, 0.42, 0.18), stacks: [])
    let stacks = ChipSegmentationDetector().detect(cg: image)
    runner.assertEqual(stacks.count, 0)
}

runner.run("ChipSegmentationDetector separates two stacks of different colors") {
    let image = makeTestImage(width: 400, height: 400, felt: (0.10, 0.42, 0.18), stacks: [
        (x: 120, y: 200, radius: 40, color: (0.85, 0.10, 0.10)),
        (x: 280, y: 200, radius: 40, color: (0.10, 0.10, 0.85))
    ])
    let stacks = ChipSegmentationDetector().detect(cg: image)
    runner.assertEqual(stacks.count, 2)
    let colors = Set(stacks.map(\.chipColor))
    runner.assertTrue(colors.contains(.red) && colors.contains(.blue), "expected red + blue, got \(colors)")
}

runner.run("PhotoHash sha256 is deterministic and 64 hex chars") {
    let data = Data("hello".utf8)
    let h1 = PhotoHash.sha256(data)
    let h2 = PhotoHash.sha256(data)
    runner.assertEqual(h1, h2)
    runner.assertEqual(h1.count, 64)
    runner.assertTrue(h1 != PhotoHash.sha256(Data("world".utf8)))
}

// MARK: - Score snapshot + Live Activity rules (W2.3)

runner.run("ScoreSnapshot.shouldPersist accepts first write") {
    let snapshot = ScoreSnapshot(
        roomName: "R", leaderboardLine: "A 10 · B 5", isLive: false, updatedAt: Date()
    )
    runner.assertTrue(ScoreSnapshot.shouldPersist(snapshot, existing: nil))
}

runner.run("ScoreSnapshot.shouldPersist rejects stale empty over real line") {
    let existing = ScoreSnapshot(
        roomName: "R", leaderboardLine: "A 10 · B 5", isLive: false, updatedAt: Date()
    )
    let incoming = ScoreSnapshot(
        roomName: "R", leaderboardLine: "", isLive: false, updatedAt: Date().addingTimeInterval(60)
    )
    runner.assertFalse(ScoreSnapshot.shouldPersist(incoming, existing: existing))
}

runner.run("ScoreSnapshot.shouldPersist accepts newer non-empty write") {
    let existing = ScoreSnapshot(
        roomName: "R", leaderboardLine: "A 10", isLive: false, updatedAt: Date()
    )
    let incoming = ScoreSnapshot(
        roomName: "R", leaderboardLine: "A 12 · B 6", isLive: false,
        updatedAt: Date().addingTimeInterval(60)
    )
    runner.assertTrue(ScoreSnapshot.shouldPersist(incoming, existing: existing))
}

runner.run("ScoreSnapshot.shouldPersist accepts empty when nothing yet") {
    let incoming = ScoreSnapshot(
        roomName: "R", leaderboardLine: "", isLive: false, updatedAt: Date()
    )
    runner.assertTrue(ScoreSnapshot.shouldPersist(incoming, existing: nil))
}

runner.run("LiveActivityRule ends during play when running") {
    let action = LiveActivityRule.action(isLive: true, hasLine: true, isRunning: true)
    runner.assertEqual(action, .end)
}

runner.run("LiveActivityRule stays quiet during play when not running") {
    let action = LiveActivityRule.action(isLive: true, hasLine: true, isRunning: false)
    runner.assertEqual(action, .none)
}

runner.run("LiveActivityRule surfaces outside play with a line") {
    let action = LiveActivityRule.action(isLive: false, hasLine: true, isRunning: false)
    runner.assertEqual(action, .startOrUpdate)
}

runner.run("LiveActivityRule no-ops outside play without a line") {
    let action = LiveActivityRule.action(isLive: false, hasLine: false, isRunning: false)
    runner.assertEqual(action, .none)
}

// MARK: - Summary

print("")
print("Ran \(runner.passes + runner.failures.count) cases: \(runner.passes) passed, \(runner.failures.count) failed.")
exit(runner.failures.isEmpty ? 0 : 1)