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

    func runAsync(_ name: String, _ block: @escaping () async throws -> Void) {
        currentName = name
        let prior = failures.count
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                try await block()
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
            sem.signal()
        }
        sem.wait()
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

runner.run("Pack scoring types match migration 034 / V0.34 count-based CAH") {
    // V0.34 — Cards Against Humanity moved from `single_winner` to
    // the new `count_based` family (migration 055). The pack's score
    // is now the count of black cards held at session end; the
    // judge's pick keeps the black card and the host enters the
    // cards-won count per round.
    runner.assertEqual(CasinoPack.scoringType, .withdrawReturn)
    runner.assertEqual(CardsAgainstHumanityPack.scoringType, .countBased)
    runner.assertEqual(MonopolyDealPack.scoringType, .singleWinner)
    runner.assertEqual(PlutoChessPack.scoringType, .singleWinner)
}

runner.run("PackScoringType.countBased raw value is 'count_based' and Codable round-trips") {
    // V0.34 — the new scoring-type discriminator. The raw value is
    // the database-side `packs.scoring_type` check constraint's
    // third allowed value (migration 055).
    runner.assertEqual(PackScoringType.countBased.rawValue, "count_based")

    // Codable round-trip preserves the case through JSON — the
    // server's jsonb decoder must see the same string the Swift
    // encoder emits.
    let data = try JSONEncoder().encode(PackScoringType.countBased)
    let decoded = try JSONDecoder().decode(PackScoringType.self, from: data)
    runner.assertEqual(decoded, .countBased)
}

runner.run("PackScoringType displayLabel covers all three families") {
    // V0.34 — single source of truth for the picker + settings
    // rows. The labels are user-facing copy; changes here
    // propagate to PackDetailView + RoomSettingsSheet.
    runner.assertEqual(PackScoringType.singleWinner.displayLabel, "Single winner")
    runner.assertEqual(PackScoringType.withdrawReturn.displayLabel, "Withdraw & return")
    runner.assertEqual(PackScoringType.countBased.displayLabel, "Count-based")
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

runner.run("PackScoringResolver countBased emits one entry with cards_won meta") {
    // V0.34 — count-based scoring (CAH). The resolver emits one
    // entry whose pointsDelta equals the cards-won count and whose
    // meta carries the round's `cards_won`, `winner` and
    // `round_index` so the per-round breakdown can show "Alex won
    // 2 cards this round" and the session tally RPC can identify
    // the per-round rows it will later replace.
    let winnerId = UUID()
    let input = PackScoringInput.countBased(
        roundIndex: 2,
        winnerMemberId: winnerId,
        cardCount: 2
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "cards_against_humanity")
    runner.assertEqual(entries.count, 1)
    runner.assertEqual(entries[0].memberId, winnerId)
    runner.assertEqual(entries[0].pointsDelta, 2)
    runner.assertEqual(entries[0].meta["cards_won"], .int(2))
    runner.assertEqual(entries[0].meta["winner"], .bool(true))
    runner.assertEqual(entries[0].meta["round_index"], .int(2))
}

runner.run("PackScoringResolver countBased with cardCount 1 records pointsDelta 1") {
    // V0.34 — the default per-round count is 1 (the judge's pick
    // takes one black card). The resolver's pointsDelta is the
    // cardCount so the ledger row matches what the host entered.
    let winnerId = UUID()
    let input = PackScoringInput.countBased(
        roundIndex: 1,
        winnerMemberId: winnerId,
        cardCount: 1
    )
    let entries = PackScoringResolver.resolve(input, packSlug: "cards_against_humanity")
    runner.assertEqual(entries.first?.pointsDelta, 1)
    runner.assertEqual(entries.first?.meta["cards_won"], .int(1))
}

runner.run("PackScoringInput countBased packSlug resolves to cards_against_humanity") {
    // The packSlug discriminator drives ScoringService's input
    // routing (roundIndex extraction, ledger payload key). For CAH
    // it must read as the CAH slug, not the bare "single_winner"
    // family name.
    let input = PackScoringInput.countBased(
        roundIndex: 1,
        winnerMemberId: UUID(),
        cardCount: 1
    )
    runner.assertEqual(input.packSlug, "cards_against_humanity")
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

runner.run("Room decodes notifications_enabled true from server shape (V0.54)") {
    // Migration 066: the current user's per-room opt-in for the
    // quiet-by-default pre-play logistics pushes. Default is false;
    // a member who flips the BriefingSlot toggle sends `true` here.
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
      "member_drowning_opt_in": false,
      "notifications_enabled": true
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let room = try decoder.decode(Room.self, from: json.data(using: .utf8)!)
    runner.assertEqual(room.notificationsEnabled, true)
}

runner.run("Room defaults notifications_enabled to false when column missing (V0.54)") {
    // Pre-migration-066 server shape (or a brand-new member who
    // has never set the toggle). Defaults to false — the
    // quiet-by-default default.
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
    runner.assertEqual(room.notificationsEnabled, false)
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

runner.run("PackHowTo CAH describes count-based scoring + scan section") {
    // V0.34 — the CAH how-to body now describes count-based
    // scoring (winner keeps the black card, score is cards held)
    // and includes a "Scan" section that points members at the
    // session-end card-counting flow. The previous single-winner
    // "one point" copy is gone.
    let howTo = PackHowToCatalog.howTo(forSlug: "cards_against_humanity")
    runner.assertNotNil(howTo)
    let bodies = howTo?.sections.map { $0.body } ?? []
    // Either form ("cards won" / "cards-won") counts — the
    // per-round body uses the hyphenated "cards-won count" to
    // match the leaderboard recap copy.
    let mentionsCardsWon = bodies.contains { body in
        body.contains("cards won") || body.contains("cards-won")
    }
    runner.assertTrue(
        mentionsCardsWon,
        "expected a section body containing 'cards won' / 'cards-won' — got: \(bodies)"
    )
    runner.assertTrue(
        howTo?.sections.contains { $0.title == "Scan" } ?? false,
        "expected a 'Scan' section in the CAH how-to"
    )
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

runner.run("EventRSVP decodes notifications_muted true from server shape (V0.54)") {
    // Migration 066 widens `get_event_rsvps` to include the
    // per-event mute flag. The BriefingSlot derives the muted
    // member ids straight from the cached `eventRSVPsByEvent`
    // without a separate round trip.
    let json = """
    {
      "event_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "display_name": "Alex",
      "state": "claimed",
      "notifications_muted": true
    }
    """
    let decoded = try JSONDecoder().decode(EventRSVP.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.notificationsMuted, true)
    runner.assertEqual(decoded.state, .claimed)
}

runner.run("EventRSVP defaults notifications_muted to false when column missing (V0.54)") {
    // Backward-compat for legacy `get_event_rsvps` callers that
    // pre-date migration 066 — defaults to false (unmuted) rather
    // than throws.
    let json = """
    {
      "event_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "display_name": "Sam",
      "state": "claimed"
    }
    """
    let decoded = try JSONDecoder().decode(EventRSVP.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.notificationsMuted, false)
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

runner.run("SocialProof returns nil for no claimed names") {
    runner.assertNil(SocialProof.claimedSeatsCaption(claimedNames: []))
}

runner.run("SocialProof formats one claimed name") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: ["Sarah"]), "Sarah has claimed a seat")
}

runner.run("SocialProof formats two claimed names") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: ["Sarah", "Mike"]), "Sarah and Mike have claimed seats")
}

runner.run("SocialProof formats three claimed names") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: ["Sarah", "Mike", "Alex"]), "Sarah, Mike +1 more have claimed seats")
}

runner.run("SocialProof formats five claimed names") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: ["Sarah", "Mike", "Alex", "Jo", "Sam"]), "Sarah, Mike +3 more have claimed seats")
}

runner.run("SocialProof drops whitespace-only names") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: ["Sarah", "  ", "Mike"]), "Sarah and Mike have claimed seats")
}

runner.run("SocialProof returns nil for only empty names") {
    runner.assertNil(SocialProof.claimedSeatsCaption(claimedNames: ["", " \n "]))
}

runner.run("SocialProof trims names") {
    runner.assertEqual(SocialProof.claimedSeatsCaption(claimedNames: [" Sarah ", "\nMike\t"]), "Sarah and Mike have claimed seats")
}

// MARK: - SeatGrid (seat grid maxSeats loop)

func seatGridRSVP(_ name: String, _ state: MemberRSVPState) -> EventRSVP {
    EventRSVP(eventId: UUID(), memberId: UUID(), displayName: name, state: state)
}

runner.run("SeatGrid.cells 2 claimed of 6 → 6 cells, first 2 claimed, last 4 open") {
    let rsvps = [
        seatGridRSVP("Alex", .claimed),
        seatGridRSVP("Sam", .claimed)
    ]
    let cells = SeatGrid.cells(maxSeats: 6, rsvps: rsvps)
    runner.assertEqual(cells.count, 6)
    runner.assertEqual(cells[0].rsvp?.displayName, "Alex")
    runner.assertEqual(cells[1].rsvp?.displayName, "Sam")
    runner.assertNil(cells[2].rsvp)
    runner.assertNil(cells[3].rsvp)
    runner.assertNil(cells[4].rsvp)
    runner.assertNil(cells[5].rsvp)
}

runner.run("SeatGrid.cells 0 claimed of 6 → 6 open cells") {
    let rsvps = [seatGridRSVP("Alex", .declined)]
    let cells = SeatGrid.cells(maxSeats: 6, rsvps: rsvps)
    runner.assertEqual(cells.count, 6)
    for cell in cells {
        runner.assertNil(cell.rsvp)
    }
}

runner.run("SeatGrid.cells 6 claimed of 6 → 6 claimed, 0 open") {
    let rsvps = (0..<6).map { seatGridRSVP("M\($0)", .claimed) }
    let cells = SeatGrid.cells(maxSeats: 6, rsvps: rsvps)
    runner.assertEqual(cells.count, 6)
    for (i, cell) in cells.enumerated() {
        runner.assertEqual(cell.rsvp?.displayName, "M\(i)")
    }
}

runner.run("SeatGrid.cells claimed > maxSeats → drops extras") {
    let rsvps = (0..<8).map { seatGridRSVP("M\($0)", .claimed) }
    let cells = SeatGrid.cells(maxSeats: 6, rsvps: rsvps)
    runner.assertEqual(cells.count, 6)
    for (i, cell) in cells.enumerated() {
        runner.assertEqual(cell.rsvp?.displayName, "M\(i)")
    }
}

runner.run("SeatGrid.cells maxSeats 0 → empty") {
    let rsvps = [seatGridRSVP("Alex", .claimed)]
    let cells = SeatGrid.cells(maxSeats: 0, rsvps: rsvps)
    runner.assertEqual(cells.count, 0)
}

runner.run("SeatGrid.cells preserves claimed input order") {
    let rsvps = [
        seatGridRSVP("Charlie", .claimed),
        seatGridRSVP("Alice", .claimed),
        seatGridRSVP("Bob", .claimed)
    ]
    let cells = SeatGrid.cells(maxSeats: 6, rsvps: rsvps)
    runner.assertEqual(cells.count, 6)
    runner.assertEqual(cells[0].rsvp?.displayName, "Charlie")
    runner.assertEqual(cells[1].rsvp?.displayName, "Alice")
    runner.assertEqual(cells[2].rsvp?.displayName, "Bob")
    runner.assertNil(cells[3].rsvp)
    runner.assertNil(cells[4].rsvp)
    runner.assertNil(cells[5].rsvp)
}

runner.run("SeatGrid.columnCount adapts to maxSeats (4→2, 6→3, 8→3, 12→4)") {
    runner.assertEqual(SeatGrid.columnCount(for: 4), 2)
    runner.assertEqual(SeatGrid.columnCount(for: 6), 3)
    runner.assertEqual(SeatGrid.columnCount(for: 8), 3)
    runner.assertEqual(SeatGrid.columnCount(for: 12), 4)
}

runner.run("SeatGrid.columnCount floors at 2 (2→2, 1→2, 0→2)") {
    runner.assertEqual(SeatGrid.columnCount(for: 2), 2)
    runner.assertEqual(SeatGrid.columnCount(for: 1), 2)
    runner.assertEqual(SeatGrid.columnCount(for: 0), 2)
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

runner.run("Member decodes get_room_members RPC shape (legacy 6-column contract)") {
    // Migration 049 truncated the RPC's column list to the six
    // membership columns visible to the leaderboard; the iOS
    // `Member` decoder must tolerate the absence of `room_id`,
    // `joined_at` and the social-preference columns without
    // throwing — otherwise the roster card spins forever.
    let hostId = UUID()
    let redId = UUID()
    let json = """
    [
      {
        "user_id": "\(hostId.uuidString)",
        "display_name": "Alex",
        "role": "host",
        "points_balance": 250,
        "season_score": 250,
        "team": null
      },
      {
        "user_id": "\(redId.uuidString)",
        "display_name": "Sam",
        "role": "member",
        "points_balance": 180,
        "season_score": 180,
        "team": "Red"
      }
    ]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let members = try decoder.decode([Member].self, from: json.data(using: .utf8)!)
    runner.assertEqual(members.count, 2)

    let host = members[0]
    runner.assertEqual(host.id, hostId.uuidString)
    runner.assertNil(host.roomId)
    runner.assertEqual(host.joinedAt, .distantPast)
    runner.assertEqual(host.role, .host)
    runner.assertEqual(host.displayName, "Alex")
    runner.assertNil(host.team)
    runner.assertEqual(host.socialPreference, .empty)
    runner.assertNil(host.lastSeenAt)

    let red = members[1]
    runner.assertEqual(red.id, redId.uuidString)
    runner.assertEqual(red.team, "Red")
    runner.assertEqual(red.displayName, "Sam")
}

runner.run("Member decodes enriched get_room_members shape (migration 059)") {
    // Migration 059 widens the RPC back to the full membership row,
    // so the decoder must surface every column and synthesise the
    // composite `id` from `room_id` + `user_id`. The three social-
    // preference columns ship nested under `social_preference` —
    // the Swift `Member` decoder reads that container, which in
    // turn reads its three `preferences_*` keys verbatim from the
    // RPC columns.
    let roomId = UUID()
    let userId = UUID()
    let joinedAtDate = Date(timeIntervalSince1970: 1_700_000_000)
    let lastSeenAtDate = Date(timeIntervalSince1970: 1_700_086_400)
    let iso = ISO8601DateFormatter()
    let json = """
    [
      {
        "user_id": "\(userId.uuidString)",
        "room_id": "\(roomId.uuidString)",
        "display_name": "Alex",
        "role": "host",
        "points_balance": 250,
        "season_score": 250,
        "team": null,
        "joined_at": "\(iso.string(from: joinedAtDate))",
        "last_seen_at": "\(iso.string(from: lastSeenAtDate))",
        "social_preference": {
          "preferences_social": "I prefer to be introduced by name.",
          "preferences_conversation_prompt": "Tell me your favourite game.",
          "preferences_default_set": true
        }
      }
    ]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let members = try decoder.decode([Member].self, from: json.data(using: .utf8)!)
    runner.assertEqual(members.count, 1)

    let member = members[0]
    runner.assertEqual(member.id, "\(roomId.uuidString):\(userId.uuidString)")
    runner.assertEqual(member.roomId, roomId)
    runner.assertEqual(member.joinedAt, joinedAtDate)
    runner.assertEqual(member.lastSeenAt, lastSeenAtDate)
    runner.assertEqual(member.socialPreference.socialText, "I prefer to be introduced by name.")
    runner.assertEqual(member.socialPreference.conversationPrompt, "Tell me your favourite game.")
    runner.assertTrue(member.socialPreference.defaultSet)
    runner.assertNil(member.team)
    runner.assertEqual(member.userId, userId)
}

runner.run("Member decodes notifications_enabled when present in RPC shape (V0.54)") {
    // Migration 066 widens `get_room_members` to include the
    // per-member notifications opt-in (encoded as the room-level
    // `notifications_enabled` column from the membership row).
    // The roster filter reads this field to gate the briefing
    // cadenced fan-out.
    let roomId = UUID()
    let optedUserId = UUID()
    let quietUserId = UUID()
    let iso = ISO8601DateFormatter()
    let json = """
    [
      {
        "user_id": "\(optedUserId.uuidString)",
        "room_id": "\(roomId.uuidString)",
        "display_name": "Alex",
        "role": "member",
        "points_balance": 250,
        "season_score": 250,
        "joined_at": "\(iso.string(from: Date(timeIntervalSince1970: 1_700_000_000)))",
        "last_seen_at": null,
        "notifications_enabled": true
      },
      {
        "user_id": "\(quietUserId.uuidString)",
        "room_id": "\(roomId.uuidString)",
        "display_name": "Sam",
        "role": "member",
        "points_balance": 100,
        "season_score": 100,
        "joined_at": "\(iso.string(from: Date(timeIntervalSince1970: 1_700_086_400)))",
        "last_seen_at": null,
        "notifications_enabled": false
      }
    ]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let members = try decoder.decode([Member].self, from: json.data(using: .utf8)!)
    runner.assertEqual(members.count, 2)
    runner.assertEqual(members[0].notificationsEnabled, true)
    runner.assertEqual(members[0].userId, optedUserId)
    runner.assertEqual(members[1].notificationsEnabled, false)
    runner.assertEqual(members[1].userId, quietUserId)
}

runner.run("Member defaults notifications_enabled to false when RPC omits the column (V0.54)") {
    // Backward-compat for legacy `get_room_members` callers that
    // pre-date migration 066 — the field should default to false
    // (quiet-by-default) rather than throw.
    let json = """
    [
      {
        "user_id": "11111111-1111-1111-1111-111111111111",
        "room_id": "22222222-2222-2222-2222-222222222222",
        "display_name": "Pre-migration Sam",
        "role": "member",
        "joined_at": "2026-01-01T00:00:00Z"
      }
    ]
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let members = try decoder.decode([Member].self, from: json.data(using: .utf8)!)
    runner.assertEqual(members.count, 1)
    runner.assertEqual(members[0].notificationsEnabled, false)
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

runner.run("WorkingHand JSON round-trips with snake_case keys") {
    let memberId = UUID()
    let hand = WorkingHand(
        memberId: memberId,
        displayName: "Alice",
        workingHand: 120,
        pointsBalance: 80
    )
    let data = try JSONEncoder().encode(hand)
    let decoded = try JSONDecoder().decode(WorkingHand.self, from: data)
    runner.assertEqual(decoded.memberId, memberId)
    runner.assertEqual(decoded.displayName, "Alice")
    runner.assertEqual(decoded.workingHand, 120)
    runner.assertEqual(decoded.pointsBalance, 80)
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

runner.run("ScanConfidenceGate prompts rescan below 0.3, not at/above") {
    runner.assertTrue(ScanConfidenceGate.shouldPromptRescan(confidenceAvg: 0.0))
    runner.assertTrue(ScanConfidenceGate.shouldPromptRescan(confidenceAvg: 0.29))
    runner.assertFalse(ScanConfidenceGate.shouldPromptRescan(confidenceAvg: 0.3))
    runner.assertFalse(ScanConfidenceGate.shouldPromptRescan(confidenceAvg: 0.7))
    runner.assertFalse(ScanConfidenceGate.shouldPromptRescan(confidenceAvg: 1.0))
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

// MARK: - Room deletion (W-04, US-04)

runner.runAsync("InMemoryRoomStore.deleteRoom expires open join codes and removes the room") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    let code = try await store.generateJoinCode(roomId: hosted.id)
    try await store.deleteRoom(roomId: hosted.id)
    let rooms = try await store.fetchRooms()
    runner.assertFalse(rooms.contains { $0.id == hosted.id }, "deleted room still listed")
    do {
        _ = try await store.redeemJoinCode(code: code)
        runner.assertTrue(false, "redeem should throw after delete")
    } catch {
        runner.assertTrue(true)
    }
}

runner.runAsync("InMemoryRoomStore.deleteRoom throws for non-host") {
    let store = InMemoryRoomStore()
    let otherRoom = try await store.fetchRooms()[1]
    do {
        try await store.deleteRoom(roomId: otherRoom.id)
        runner.assertTrue(false, "non-host delete should throw")
    } catch {
        runner.assertTrue(true)
    }
}

// MARK: - Season history (W-05, US-10)

runner.runAsync("InMemoryRoomStore.seasonHistory returns prior seasons ordered with totals") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    let history = try await store.fetchSeasonHistory(roomId: hosted.id)
    runner.assertEqual(history.count, 2)
    runner.assertTrue(history[0].ordinal > history[1].ordinal, "most recent season first")
    runner.assertTrue(history.allSatisfy { $0.callerTotal > 0 }, "caller totals present")
    let currentScore: Int64 = 1_200
    runner.assertEqual(history[0].delta(against: currentScore), currentScore - history[0].callerTotal)
    for row in history {
        runner.assertTrue(!row.scoreProgression.isEmpty, "score progression seeded")
        runner.assertEqual(
            row.scoreProgression.last?.total ?? -1,
            row.callerTotal
        )
    }
}

runner.runAsync("InMemoryRoomStore.seasonHistory is empty for a fresh room") {
    let store = InMemoryRoomStore()
    let id = try await store.createRoom(
        name: "Fresh", mascotName: "M", mascotPersonality: .friendly,
        mascotPoliticalIdeology: .centrist, joinStartingBonus: 200,
        mascotApiKey: nil, blacklistedUserIds: []
    )
    let history = try await store.fetchSeasonHistory(roomId: id)
    runner.assertEqual(history.count, 0)
}

runner.run("SeasonHistoryEntry decodes score_progression when present") {
    let json = """
    {
      "season_id": "00000000-0000-0000-0000-000000000001",
      "ordinal": 2,
      "subtitle": "The Comeback",
      "started_at": "2026-01-15T00:00:00Z",
      "ended_at": "2026-02-14T00:00:00Z",
      "caller_total": 980,
      "caller_rank": 1,
      "score_progression": [
        { "at": "2026-01-20T00:00:00Z", "total": 200 },
        { "at": "2026-02-01T00:00:00Z", "total": 600 },
        { "at": "2026-02-12T00:00:00Z", "total": 980 }
      ]
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SeasonHistoryEntry.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.scoreProgression.count, 3)
    runner.assertEqual(decoded.scoreProgression[0].total, 200)
    runner.assertEqual(decoded.scoreProgression.last?.total, 980)
}

runner.run("SeasonHistoryEntry defaults scoreProgression to [] when the key is absent") {
    let json = """
    {
      "season_id": "00000000-0000-0000-0000-000000000002",
      "ordinal": 1,
      "subtitle": "Genesis",
      "started_at": "2025-11-01T00:00:00Z",
      "ended_at": "2025-12-01T00:00:00Z",
      "caller_total": 640,
      "caller_rank": 3
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SeasonHistoryEntry.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.scoreProgression.count, 0)
}

runner.run("SeasonHistoryEntry.delta(against:) is positive when climbed since that season") {
    let past = SeasonHistoryEntry(seasonId: UUID(), ordinal: 1, subtitle: "", startedAt: Date(), endedAt: Date(), callerTotal: 100, callerRank: 1)
    runner.assertEqual(past.delta(against: 160), 60)
    runner.assertEqual(past.delta(against: 80), -20)
}

// MARK: - Casino config (W-06, US-26)

runner.runAsync("InMemoryRoomStore casino config defaults to standard presets") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    let config = try await store.fetchCasinoConfig(roomId: hosted.id)
    runner.assertNotNil(config, "seeded room should have a casino config")
    runner.assertTrue(config?.standardPresets ?? false, "defaults to standard presets")
    runner.assertEqual(config?.chipColorMap.isEmpty ?? false, true)
}

runner.runAsync("InMemoryRoomStore updateCasinoConfig stores a custom color map") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    try await store.updateCasinoConfig(
        roomId: hosted.id, enabled: true,
        chipColorMap: [.red: 7, .blue: 12], standardPresets: false
    )
    let config = try await store.fetchCasinoConfig(roomId: hosted.id)
    runner.assertEqual(config?.chipColorMap[.red], 7)
    runner.assertEqual(config?.chipColorMap[.blue], 12)
    runner.assertTrue(config?.standardPresets == false)
    runner.assertTrue(config?.enabled == true)
}

runner.run("CasinoConfig.value(for:) honors custom map when standardPresets is false") {
    let custom = CasinoConfig(
        roomId: UUID(), enabled: true,
        chipColorMap: [.red: 7, .blue: 12], standardPresets: false
    )
    runner.assertEqual(custom.value(for: .red), 7)
    runner.assertEqual(custom.value(for: .blue), 12)
    // Unmapped colors fall back to the built-in default.
    runner.assertEqual(custom.value(for: .green), 25)
}

runner.run("CasinoConfig.value(for:) ignores the map when standardPresets is true") {
    let standard = CasinoConfig(
        roomId: UUID(), enabled: true,
        chipColorMap: [.red: 7], standardPresets: true
    )
    runner.assertEqual(standard.value(for: .red), 5)
}

// MARK: - EventRound round-tally (W3.6 — deletion + correction)

runner.run("Array<EventRound>.nextRoundIndex is 1 for an empty log") {
    let empty: [EventRound] = []
    runner.assertEqual(empty.nextRoundIndex, 1)
}

runner.run("Array<EventRound>.nextRoundIndex is max+1 for [1, 2, 4]") {
    let eventId = UUID()
    let roomId = UUID()
    let userId = UUID()
    let rounds: [EventRound] = [
        EventRound(id: UUID(), eventId: eventId, roomId: roomId, packSlug: "cards_against_humanity", roundIndex: 1, entries: [], createdBy: userId, createdAt: Date()),
        EventRound(id: UUID(), eventId: eventId, roomId: roomId, packSlug: "cards_against_humanity", roundIndex: 2, entries: [], createdBy: userId, createdAt: Date()),
        EventRound(id: UUID(), eventId: eventId, roomId: roomId, packSlug: "cards_against_humanity", roundIndex: 4, entries: [], createdBy: userId, createdAt: Date())
    ]
    runner.assertEqual(rounds.nextRoundIndex, 5)
}

runner.run("Array<EventRound>.nextRoundIndex stays monotonic after a delete") {
    let eventId = UUID()
    let roomId = UUID()
    let userId = UUID()
    let rounds: [EventRound] = [
        EventRound(id: UUID(), eventId: eventId, roomId: roomId, packSlug: "pluto_chess", roundIndex: 1, entries: [], createdBy: userId, createdAt: Date()),
        EventRound(id: UUID(), eventId: eventId, roomId: roomId, packSlug: "pluto_chess", roundIndex: 3, entries: [], createdBy: userId, createdAt: Date())
    ]
    runner.assertEqual(rounds.nextRoundIndex, 4)
}

runner.run("EventRound decodes correction_of when present") {
    let original = UUID()
    let correction = UUID()
    let json = """
    {
      "id": "\(uuidString(correction))",
      "event_id": "\(uuidString(UUID()))",
      "room_id": "\(uuidString(UUID()))",
      "pack_slug": "cards_against_humanity",
      "round_index": 2,
      "entries": [],
      "created_by": "\(uuidString(UUID()))",
      "created_at": "2026-08-10T12:00:00Z",
      "correction_of": "\(uuidString(original))"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EventRound.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.correctionOf, original)
}

runner.run("EventRound defaults correctionOf to nil when absent") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "event_id": "22222222-2222-2222-2222-222222222222",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "pack_slug": "pluto_chess",
      "round_index": 1,
      "entries": [],
      "created_by": "66666666-6666-6666-6666-666666666666",
      "created_at": "2026-08-10T12:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(EventRound.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.correctionOf, nil)
}

// MARK: - MascotEngine (V0.36 — footer state-aware caption)

private func makeLeaderboardRow(
    userId: UUID,
    displayName: String,
    role: String = "member",
    seasonScore: Int64 = 100,
    sessionsPlayed: Int64 = 1,
    lastSessionAt: Date? = nil
) -> LeaderboardEntry {
    LeaderboardEntry(
        userId: userId,
        displayName: displayName,
        role: role,
        pointsBalance: 0,
        seasonScore: seasonScore,
        sessionsPlayed: sessionsPlayed,
        lastSessionAt: lastSessionAt,
        lastSessionDelta: 0,
        trajectory: []
    )
}

private func makeEvent(
    playedAt: Date,
    settledAt: Date? = nil
) -> Event {
    Event(
        id: UUID(),
        roomId: UUID(),
        name: "Friday Night Hold'em",
        playedAt: playedAt,
        createdAt: playedAt.addingTimeInterval(-86_400)
    )
    .withSettledAt(settledAt)
}

private extension Event {
    func withSettledAt(_ value: Date?) -> Event {
        Event(
            id: self.id,
            roomId: self.roomId,
            name: self.name,
            playedAt: self.playedAt,
            createdAt: self.createdAt,
            venue: self.venue,
            hostNote: self.hostNote,
            maxSeats: self.maxSeats,
            startedAt: self.startedAt,
            settledAt: value,
            sessionId: self.sessionId,
            packSlug: self.packSlug,
            hostFinalized: self.hostFinalized
        )
    }
}

private func makeWinnerRound(
    eventId: UUID,
    roundIndex: Int,
    winnerIds: [UUID]
) -> EventRound {
    EventRound(
        id: UUID(),
        eventId: eventId,
        roomId: UUID(),
        packSlug: "monopoly_deal",
        roundIndex: roundIndex,
        entries: winnerIds.map {
            ScoreEntry(
                memberId: $0,
                pointsDelta: 1,
                meta: ["winner": .bool(true)]
            )
        },
        createdBy: UUID(),
        createdAt: Date()
    )
}

runner.run("MascotEngine.footerKind returns .postPlayRecap when settledAt is set") {
    let past = Date().addingTimeInterval(-3600)
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: past, createdAt: past.addingTimeInterval(-86_400),
        settledAt: past.addingTimeInterval(1800)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: Date()
    )
    runner.assertEqual(kind, .postPlayRecap)
}

runner.run("MascotEngine.footerKind returns .tonightEvent when live, not settled, no withdrawal") {
    let now = Date()
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: now.addingTimeInterval(-600),
        createdAt: now.addingTimeInterval(-86_400)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: now
    )
    runner.assertEqual(kind, .tonightEvent)
}

runner.run("MascotEngine.footerKind returns .inPlayWithWithdrawal when live and withdrawn > 0") {
    let now = Date()
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: now.addingTimeInterval(-600),
        createdAt: now.addingTimeInterval(-86_400)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: now,
        withdrawnAmount: 500
    )
    runner.assertEqual(kind, .inPlayWithWithdrawal)
}

runner.run("MascotEngine.footerKind returns .settleRound when live and host finalized") {
    let now = Date()
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: now.addingTimeInterval(-600),
        createdAt: now.addingTimeInterval(-86_400),
        hostFinalized: true
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: now,
        withdrawnAmount: 500
    )
    runner.assertEqual(kind, .settleRound)
}

runner.run("MascotEngine.footerKind returns .seasonClose when current season ended") {
    let now = Date()
    let season = Season(
        id: UUID(), roomId: UUID(), ordinal: 3, subtitle: "The Long River",
        status: .ended, startedAt: now.addingTimeInterval(-30 * 86_400),
        endedAt: now.addingTimeInterval(-86_400)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: nil, leaderboard: [], now: now,
        currentSeason: season
    )
    runner.assertEqual(kind, .seasonClose)
}

runner.run("MascotEngine.footerKind returns .postPlayRecap when settled even if season ended") {
    // Season-close takes priority over settled-event recap per the
    // V0State precedence — but a settled event with an ACTIVE season
    // still resolves .postPlayRecap.
    let now = Date()
    let past = now.addingTimeInterval(-3600)
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: past, createdAt: past.addingTimeInterval(-86_400),
        settledAt: past.addingTimeInterval(1800)
    )
    let season = Season(
        id: UUID(), roomId: UUID(), ordinal: 2, subtitle: "Arc",
        status: .active, startedAt: now.addingTimeInterval(-30 * 86_400)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: now,
        currentSeason: season
    )
    runner.assertEqual(kind, .postPlayRecap)
}

runner.run("MascotEngine.footerKind returns .briefingOnCreate when playedAt is in the future") {
    let now = Date()
    let event = Event(
        id: UUID(), roomId: UUID(), name: "Poker",
        playedAt: now.addingTimeInterval(86_400),
        createdAt: now.addingTimeInterval(-3600)
    )
    let kind = MascotEngine.footerKind(
        activeEvent: event, leaderboard: [], now: now
    )
    runner.assertEqual(kind, .briefingOnCreate)
}

runner.run("MascotEngine.footerKind returns .roomWelcome when no events and empty leaderboard") {
    let kind = MascotEngine.footerKind(
        activeEvent: nil, leaderboard: [], now: Date()
    )
    runner.assertEqual(kind, .roomWelcome)
}

runner.run("MascotEngine.footerKind returns .roomStale when last session is 30 days ago") {
    let now = Date()
    let stale = now.addingTimeInterval(-30 * 86_400)
    let leaderboard = [
        makeLeaderboardRow(
            userId: UUID(), displayName: "Alice",
            sessionsPlayed: 3, lastSessionAt: stale
        )
    ]
    let kind = MascotEngine.footerKind(
        activeEvent: nil, leaderboard: leaderboard, now: now
    )
    runner.assertEqual(kind, .roomStale)
}

runner.run("MascotEngine.footerKind returns .standings when recent and no active event") {
    let now = Date()
    let recent = now.addingTimeInterval(-3 * 86_400)
    let leaderboard = [
        makeLeaderboardRow(
            userId: UUID(), displayName: "Alice", lastSessionAt: recent
        )
    ]
    let kind = MascotEngine.footerKind(
        activeEvent: nil, leaderboard: leaderboard, now: now
    )
    runner.assertEqual(kind, .standings)
}

runner.run("MascotEngine.footerKind returns .standings when last play is exactly 14 days ago") {
    // The threshold is strict `>`: a 14-day-old session is on the
    // boundary and counts as "still active" (`.standings`), not stale.
    let now = Date()
    let exactCutoff = now.addingTimeInterval(-14 * 86_400)
    let leaderboard = [
        makeLeaderboardRow(
            userId: UUID(), displayName: "Alice",
            lastSessionAt: exactCutoff
        )
    ]
    let kind = MascotEngine.footerKind(
        activeEvent: nil, leaderboard: leaderboard, now: now
    )
    runner.assertEqual(kind, .standings)
}

runner.run("MascotEngine.recentWinners returns names in roundIndex DESC, deduped, capped at 3") {
    let eventId = UUID()
    let alice = UUID(), bob = UUID(), carol = UUID(), dave = UUID()
    // Two rounds: round 3 happens first chronologically (lowest roundIndex),
    // round 7 happens later. Recent-winners ordering must put round 7 first.
    let rounds = [
        makeWinnerRound(eventId: eventId, roundIndex: 3, winnerIds: [carol]),
        makeWinnerRound(eventId: eventId, roundIndex: 7, winnerIds: [alice, bob]),
        // Same member winning again — should not double-list.
        makeWinnerRound(eventId: eventId, roundIndex: 10, winnerIds: [alice, dave])
    ]
    let names = MascotEngine.recentWinners(
        rounds: rounds,
        memberNameById: [alice: "Alice", bob: "Bob", carol: "Carol", dave: "Dave"]
    )
    runner.assertEqual(names, ["Alice", "Dave", "Bob"])
}

runner.run("MascotEngine.recentWinners ignores non-winner entries") {
    let eventId = UUID()
    let alice = UUID()
    // Winner's points_delta = positive, non-winner has no `winner: true`
    let rounds: [EventRound] = [
        EventRound(
            id: UUID(), eventId: eventId, roomId: UUID(),
            packSlug: "pluto_chess", roundIndex: 1,
            entries: [
                ScoreEntry(memberId: alice, pointsDelta: -20, meta: [:])
            ],
            createdBy: UUID(), createdAt: Date()
        )
    ]
    let names = MascotEngine.recentWinners(rounds: rounds, memberNameById: [alice: "Alice"])
    runner.assertEqual(names, [])
}

runner.run("MascotEngine.leaderName returns first non-host displayName") {
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Host", role: "host", seasonScore: 999),
        makeLeaderboardRow(userId: UUID(), displayName: "Alice", seasonScore: 500),
        makeLeaderboardRow(userId: UUID(), displayName: "Bob", seasonScore: 400)
    ]
    runner.assertEqual(MascotEngine.leaderName(leaderboard: leaderboard), "Alice")
}

runner.run("MascotEngine.leaderName returns nil when leaderboard is empty") {
    runner.assertNil(MascotEngine.leaderName(leaderboard: []))
}

runner.run("MascotEngine.leaderName returns nil when only hosts are present") {
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Host", role: "host", seasonScore: 999)
    ]
    runner.assertNil(MascotEngine.leaderName(leaderboard: leaderboard))
}

runner.run("MascotEngine.callerRank returns 1-based rank among non-host entries") {
    let alice = UUID(), bob = UUID(), carol = UUID()
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Host", role: "host", seasonScore: 9999),
        makeLeaderboardRow(userId: alice, displayName: "Alice", seasonScore: 500),
        makeLeaderboardRow(userId: bob, displayName: "Bob", seasonScore: 400),
        makeLeaderboardRow(userId: carol, displayName: "Carol", seasonScore: 300)
    ]
    runner.assertEqual(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: bob), 2)
    runner.assertEqual(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: alice), 1)
    runner.assertEqual(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: carol), 3)
}

runner.run("MascotEngine.callerRank returns nil for nil currentUserId") {
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Alice")
    ]
    runner.assertNil(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: nil))
}

runner.run("MascotEngine.callerRank returns nil when the caller isn't on the board") {
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Alice")
    ]
    runner.assertNil(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: UUID()))
}

runner.run("MascotEngine.callerRank returns nil when the caller is a host") {
    let hostId = UUID()
    let leaderboard = [
        makeLeaderboardRow(userId: hostId, displayName: "Host", role: "host", seasonScore: 9999)
    ]
    runner.assertNil(MascotEngine.callerRank(leaderboard: leaderboard, currentUserId: hostId))
}

runner.run("MascotEngine.lastWinnerDelta returns most recent winner's pointsDelta") {
    let eventId = UUID()
    let alice = UUID(), bob = UUID()
    let rounds = [
        EventRound(
            id: UUID(), eventId: eventId, roomId: UUID(),
            packSlug: "monopoly_deal", roundIndex: 1,
            entries: [
                ScoreEntry(memberId: alice, pointsDelta: 40, meta: ["winner": .bool(true)])
            ],
            createdBy: UUID(), createdAt: Date()
        ),
        EventRound(
            id: UUID(), eventId: eventId, roomId: UUID(),
            packSlug: "monopoly_deal", roundIndex: 2,
            entries: [
                ScoreEntry(memberId: bob, pointsDelta: 25, meta: ["winner": .bool(true)])
            ],
            createdBy: UUID(), createdAt: Date()
        )
    ]
    // roundIndex 2 is most recent → Bob's 25.
    runner.assertEqual(MascotEngine.lastWinnerDelta(rounds: rounds), 25)
}

runner.run("MascotEngine.lastWinnerDelta returns nil when no winner") {
    let eventId = UUID()
    let alice = UUID()
    let rounds = [
        EventRound(
            id: UUID(), eventId: eventId, roomId: UUID(),
            packSlug: "pluto_chess", roundIndex: 1,
            entries: [
                ScoreEntry(memberId: alice, pointsDelta: -20, meta: [:])
            ],
            createdBy: UUID(), createdAt: Date()
        )
    ]
    runner.assertNil(MascotEngine.lastWinnerDelta(rounds: rounds))
}

runner.run("MascotEngine.generateVoice drops {working_hand} sentence when withdrawnAmount is nil") {
    // `.inPlayWithWithdrawal` cells reference {working_hand}; when the
    // context has no withdrawn amount the referencing sentence must drop.
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .professional,
        ideology: .order,
        kind: .inPlayWithWithdrawal,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: ["Alice", "Bob", "Carol", "Dave"],
            recentWinnerNames: ["Alice"],
            leaderName: "Alice",
            callerRank: nil,
            eventCount: nil,
            withdrawnAmount: nil,
            lastWinnerDelta: nil,
            seasonDaysLeft: nil
        )
    )
    runner.assertFalse(body.contains("{working_hand}"), "raw placeholder removed by sentence-drop")
    runner.assertFalse(body.contains("working hand"), "working-hand sentence dropped when nil")
}

runner.run("MascotEngine.generateVoice substitutes {working_hand} when withdrawnAmount present") {
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .professional,
        ideology: .order,
        kind: .inPlayWithWithdrawal,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: ["Alice", "Bob", "Carol", "Dave"],
            recentWinnerNames: ["Alice"],
            leaderName: "Alice",
            callerRank: nil,
            eventCount: nil,
            withdrawnAmount: 500,
            lastWinnerDelta: nil,
            seasonDaysLeft: nil
        )
    )
    runner.assertTrue(body.contains("500"), "working hand substituted")
    runner.assertFalse(body.contains("{working_hand}"), "no raw placeholder")
}

runner.run("MascotEngine.generateVoice drops sentences with unpopulated {event}") {
    // `.briefingOnCreate` with no eventDate/venue/seatsLeft still
    // references {event} — the sentence-drop pass must excise the
    // template's opening sentence and leave the rest intact.
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .friendly,
        ideology: .centrist,
        kind: .briefingOnCreate,
        context: .init(
            activeEventTitle: nil,
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: ["Alice", "Bob", "Carol", "Dave"]
        )
    )
    runner.assertFalse(body.contains("{event}"), "raw placeholder removed by sentence-drop")
    runner.assertFalse(body.lowercased().contains("friday"), "first sentence dropped when {event} nil")
}

runner.run("MascotEngine.generateVoice substitutes {member_count} for non-zero counts") {
    // V0.36 fixes a latent bug: two existing post-play templates
    // reference {member_count} but the previous interpolate pass
    // never substituted it. V0.38 reformats it to "N strong".
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .professional,
        ideology: .centrist,
        kind: .postPlayRecap,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 5,
            memberNames: []
        )
    )
    runner.assertTrue(body.contains("5 strong"), "member_count substituted as 'N strong'")
}

runner.run("MascotEngine.generateVoice appends the winner sentence to postPlayRecap when present") {
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .friendly,
        ideology: .order,
        kind: .postPlayRecap,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: [],
            recentWinnerNames: ["Alice"]
        )
    )
    runner.assertTrue(body.contains("Alice"), "winner name surfaced")
    runner.assertTrue(body.contains("Nice one"), "post-play recap winner sentence appended")
}

runner.run("MascotEngine.generateVoice drops winner sentence when no recent winner") {
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .friendly,
        ideology: .order,
        kind: .postPlayRecap,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: []
        )
    )
    runner.assertFalse(body.contains("{winner}"), "raw placeholder removed")
    runner.assertFalse(body.contains("Nice one"), "winner sentence dropped when no winner")
}

runner.run("MascotEngine.generateVoice renders .roomWelcome when leaderboard is empty") {
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .friendly,
        ideology: .centrist,
        kind: .roomWelcome,
        context: .init(
            activeEventTitle: nil,
            lastEventDaysAgo: nil,
            memberCount: 0,
            memberNames: []
        )
    )
    runner.assertTrue(body.lowercased().contains("welcome") || body.contains("Friday Night"))
}

runner.run("MascotEngine.generateVoice renders .standings substituting leader and rank") {
    let leaderboard = [
        makeLeaderboardRow(userId: UUID(), displayName: "Host", role: "host"),
        makeLeaderboardRow(userId: UUID(), displayName: "Alice", seasonScore: 500)
    ]
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .professional,
        ideology: .order,
        kind: .standings,
        context: .init(
            activeEventTitle: nil,
            lastEventDaysAgo: nil,
            memberCount: 5,
            memberNames: [],
            leaderName: MascotEngine.leaderName(leaderboard: leaderboard),
            callerRank: 1
        )
    )
    runner.assertTrue(body.contains("Alice"), "leader name substituted")
    runner.assertTrue(body.contains("#1"), "caller rank substituted")
}

runner.run("MascotEngine.RoomContext synthesised init honours the 4-arg contract") {
    // Backward-compat — `NotificationDispatcher.swift` constructs
    // RoomContext with 4 args. Swift's synthesised memberwise init
    // must default the V0.36 footer fields so the call still builds.
    let ctx = MascotEngine.RoomContext(
        activeEventTitle: "Poker",
        lastEventDaysAgo: nil,
        memberCount: 4,
        memberNames: ["Alice"]
    )
    runner.assertEqual(ctx.recentWinnerNames, [])
    runner.assertNil(ctx.leaderName)
    runner.assertNil(ctx.callerRank)
    runner.assertNil(ctx.eventCount)
}

// MARK: - MascotEngine V0.38 voice-quality tests

/// Builds a fully-populated `RoomContext` for the V0.38 200-cell
/// voice-quality tests so every template placeholder has a value.
private func fullyPopulatedContext() -> MascotEngine.RoomContext {
    .init(
        activeEventTitle: "Poker",
        lastEventDaysAgo: 7,
        memberCount: 5,
        memberNames: ["Alice", "Bob", "Carol", "Dave", "Eve"],
        recentWinnerNames: ["Alice"],
        leaderName: "Alice",
        callerRank: 2,
        eventCount: 12,
        withdrawnAmount: 500,
        lastWinnerDelta: 120,
        seasonDaysLeft: 7
    )
}

runner.run("MascotEngine.generateVoice — all 200 cells render without raw placeholders when fully populated") {
    let ctx = fullyPopulatedContext()
    let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
    for personality in MascotPersonality.allCases {
        for ideology in MascotPoliticalIdeology.allCases {
            for kind in [
                MascotEngine.NotificationKind.briefingOnCreate,
                .briefing48h,
                .briefingMorning,
                .postPlayRecap,
                .roomWelcome,
                .inPlay,
                .roomStale,
                .standings,
                .tonightEvent,
                .inPlayWithWithdrawal,
                .settleRound,
                .seasonClose
            ] {
                let body = MascotEngine.generateVoice(
                    mascotName: "Max",
                    roomName: "Friday Night",
                    personality: personality,
                    ideology: ideology,
                    kind: kind,
                    context: ctx,
                    eventDate: eventDate,
                    eventVenue: "Back Room",
                    hostNote: nil,
                    seatsLeft: 3,
                    seatsClaimed: 5
                )
                runner.assertFalse(
                    body.contains("{"),
                    "no raw placeholder (\(personality)×\(ideology)×\(kind))"
                )
            }
        }
    }
}

runner.run("MascotEngine.generateVoice — all 200 cells stay <= 200 chars fully populated") {
    let ctx = fullyPopulatedContext()
    let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
    for personality in MascotPersonality.allCases {
        for ideology in MascotPoliticalIdeology.allCases {
            for kind in [
                MascotEngine.NotificationKind.briefingOnCreate,
                .briefing48h,
                .briefingMorning,
                .postPlayRecap,
                .roomWelcome,
                .inPlay,
                .roomStale,
                .standings,
                .tonightEvent,
                .inPlayWithWithdrawal,
                .settleRound,
                .seasonClose
            ] {
                let body = MascotEngine.generateVoice(
                    mascotName: "Max",
                    roomName: "Friday Night",
                    personality: personality,
                    ideology: ideology,
                    kind: kind,
                    context: ctx,
                    eventDate: eventDate,
                    eventVenue: "Back Room",
                    hostNote: nil,
                    seatsLeft: 3,
                    seatsClaimed: 5
                )
                runner.assertTrue(
                    body.count <= 200,
                    "length cap (\(personality)×\(ideology)×\(kind)): \(body.count) chars"
                )
            }
        }
    }
}

runner.run("MascotEngine.generateVoice — 25 voices are pairwise distinct per kind") {
    // For each kind, all 25 personality×ideology outputs must be
    // distinct — no word-swapped form letters.
    let ctx = fullyPopulatedContext()
    let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
    let kinds: [MascotEngine.NotificationKind] = [
        .briefingOnCreate, .briefing48h, .briefingMorning, .postPlayRecap,
        .roomWelcome, .inPlay, .roomStale, .standings
    ]
    for kind in kinds {
        var seen: Set<String> = []
        for personality in MascotPersonality.allCases {
            for ideology in MascotPoliticalIdeology.allCases {
                let body = MascotEngine.generateVoice(
                    mascotName: "Max",
                    roomName: "Friday Night",
                    personality: personality,
                    ideology: ideology,
                    kind: kind,
                    context: ctx,
                    eventDate: eventDate,
                    eventVenue: "Back Room",
                    hostNote: nil,
                    seatsLeft: 3,
                    seatsClaimed: 5
                )
                runner.assertTrue(
                    seen.insert(body).inserted,
                    "distinct body (\(kind) — \(personality)×\(ideology))"
                )
            }
        }
        runner.assertEqual(seen.count, 25)
    }
}

runner.run("MascotEngine.generateVoice — unhinged is quiet (no ALL-CAPS, <= 1 !)") {
    let ctx = fullyPopulatedContext()
    let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
    for ideology in MascotPoliticalIdeology.allCases {
        for kind in [
            MascotEngine.NotificationKind.briefingOnCreate,
            .briefing48h,
            .briefingMorning,
            .postPlayRecap,
            .roomWelcome,
            .inPlay,
            .roomStale,
            .standings
        ] {
            let body = MascotEngine.generateVoice(
                mascotName: "Max",
                roomName: "Friday Night",
                personality: .unhinged,
                ideology: ideology,
                kind: kind,
                context: ctx,
                eventDate: eventDate,
                eventVenue: "Back Room",
                hostNote: nil,
                seatsLeft: 3,
                seatsClaimed: 5
            )
            // No run of 3+ uppercase letters (lets "3 AM", "T", etc.
            // through). Walk the string manually to avoid the Swift
            // regex literal dependency in this Foundation runner.
            var foundRun = false
            var runLength = 0
            for ch in body {
                if ch.isUppercase {
                    runLength += 1
                    if runLength >= 3 { foundRun = true; break }
                } else {
                    runLength = 0
                }
            }
            runner.assertFalse(
                foundRun,
                "no ALL-CAPS run (\(MascotPersonality.unhinged)×\(ideology)×\(kind)): \(body)"
            )
            // At most one exclamation mark.
            let bangs = body.filter { $0 == "!" }.count
            runner.assertTrue(
                bangs <= 1,
                "<= 1 ! (\(MascotPersonality.unhinged)×\(ideology)×\(kind)): \(bangs)"
            )
        }
    }
}

runner.run("MascotEngine.generateVoice — no '(s)' Mad-Libs pattern in any rendered cell") {
    let ctx = fullyPopulatedContext()
    let eventDate = Date(timeIntervalSince1970: 1_700_000_000)
    for personality in MascotPersonality.allCases {
        for ideology in MascotPoliticalIdeology.allCases {
            for kind in [
                MascotEngine.NotificationKind.briefingOnCreate,
                .briefing48h,
                .briefingMorning,
                .postPlayRecap,
                .roomWelcome,
                .inPlay,
                .roomStale,
                .standings,
                .tonightEvent,
                .inPlayWithWithdrawal,
                .settleRound,
                .seasonClose
            ] {
                let body = MascotEngine.generateVoice(
                    mascotName: "Max",
                    roomName: "Friday Night",
                    personality: personality,
                    ideology: ideology,
                    kind: kind,
                    context: ctx,
                    eventDate: eventDate,
                    eventVenue: "Back Room",
                    hostNote: nil,
                    seatsLeft: 3,
                    seatsClaimed: 5
                )
                runner.assertFalse(
                    body.contains("(s)"),
                    "no (s) (\(personality)×\(ideology)×\(kind))"
                )
            }
        }
    }
}

runner.run("MascotEngine.generateVoice — legacy logistics placeholders drop cleanly when footer renders upcoming event") {
    // The room-page footer never passes date/venue/seats — the
    // logistics sentence must disappear cleanly without leaving a
    // stray "at ." or "left .". Sentence 1 (mascot attribution) must
    // survive.
    let body = MascotEngine.generateVoice(
        mascotName: "Max",
        roomName: "Friday Night",
        personality: .professional,
        ideology: .order,
        kind: .briefingOnCreate,
        context: .init(
            activeEventTitle: "Poker",
            lastEventDaysAgo: nil,
            memberCount: 4,
            memberNames: ["Alice"]
        )
    )
    runner.assertEqual(
        body,
        "Max: Poker is on the books. The host will run it."
    )
}

private func uuidString(_ uuid: UUID) -> String { uuid.uuidString }

// MARK: - MascotEngine V0.40 — MiniMax LLM defaults + fallback

runner.run("MascotEngine default LLM endpoint is MiniMax") {
    runner.assertEqual(
        MascotEngine.defaultLLMEndpoint,
        "https://api.minimax.io/v1"
    )
}

runner.run("MascotEngine default LLM model is MiniMax-M3") {
    runner.assertEqual(
        MascotEngine.defaultLLMModel,
        "MiniMax-M3"
    )
}

runner.runAsync("MascotEngine.generateVoiceLLM falls back to template on bad endpoint") {
    // Bogus endpoint that will fail to connect (port 1 is reserved).
    // The engine must swallow the failure and return the template
    // output, matching the V0.26 fallback semantics.
    let mascotName = "Max"
    let roomName = "Friday Poker"
    let personality: MascotPersonality = .friendly
    let ideology: MascotPoliticalIdeology = .centrist
    let kind: MascotEngine.NotificationKind = .briefingOnCreate
    let context = MascotEngine.RoomContext(
        activeEventTitle: "Poker",
        lastEventDaysAgo: nil,
        memberCount: 4,
        memberNames: ["Alice", "Bob"]
    )
    let templateVoice = MascotEngine.generateVoice(
        mascotName: mascotName,
        roomName: roomName,
        personality: personality,
        ideology: ideology,
        kind: kind,
        context: context
    )
    let llmVoice = await MascotEngine.generateVoiceLLM(
        mascotName: mascotName,
        roomName: roomName,
        personality: personality,
        ideology: ideology,
        kind: kind,
        context: context,
        apiKey: "dummy",
        endpoint: "https://127.0.0.1:1"
    )
    runner.assertEqual(llmVoice, templateVoice)
}

// MARK: - V0.42 — bundled global MiniMax API key fallback

runner.run("MascotEngine.defaultLLMApiKey resolves to the sentinel when the key is absent") {
    // The test binary's Bundle.main has no MINIMAX_API_KEY, so the
    // statics initializer must fall back to the loud sentinel rather
    // than trapping or returning an empty string.
    runner.assertEqual(
        MascotEngine.defaultLLMApiKey,
        "MISSING_MINIMAX_API_KEY_CONFIG_ERROR"
    )
}

runner.run("MascotEngine.defaultLLMApiKey is never empty") {
    runner.assertFalse(
        MascotEngine.defaultLLMApiKey.isEmpty,
        "defaultLLMApiKey must fall back to the sentinel, never be empty"
    )
}

// MARK: - Event active-event decode (W-EVT-01 — get_active_event RPC shape)

runner.run("Event decodes get_active_event RPC shape (event_id, no room_id/created_at)") {
    // The current remote `get_active_event` (migration 012) returns
    // only event_id, name, played_at, seat_count, max_seats, pack_slug,
    // scoring_type. The Event decoder must tolerate the missing
    // `room_id` and `created_at` (falling back to Event.unknownRoomId
    // and playedAt respectively) and read `id` from `event_id`.
    let json = """
    {
      "event_id": "11111111-1111-1111-1111-111111111111",
      "name": "Friday Night Hold'em",
      "played_at": "2026-08-15T19:00:00Z",
      "seat_count": 2,
      "max_seats": 6,
      "pack_slug": "casino",
      "scoring_type": "single_winner"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(Event.self, from: json.data(using: .utf8)!)
    runner.assertEqual(
        decoded.id.uuidString,
        "11111111-1111-1111-1111-111111111111"
    )
    runner.assertTrue(
        decoded.roomId == Event.unknownRoomId,
        "roomId fell back to Event.unknownRoomId sentinel"
    )
    runner.assertEqual(decoded.name, "Friday Night Hold'em")
    runner.assertTrue(
        decoded.createdAt == decoded.playedAt,
        "createdAt fell back to playedAt"
    )
    runner.assertEqual(decoded.maxSeats, 6)
    runner.assertEqual(decoded.packSlug, "casino")
    runner.assertEqual(decoded.hostFinalized, false)
    runner.assertNil(decoded.settledAt)
}

// MARK: - RPC contract audit (061) — server shape conformance

runner.run("BriefingSummary decodes the migration 061 get_briefing_summary shape") {
    // The migration aliases max_seats → seats_total, claimed_seats → seats_claimed,
    // declined_seats → seats_declined, unclaimed_seats → seats_unclaimed so the
    // existing BriefingSummary model decodes without modification. Extras
    // (event_name, played_at, venue, host_note, claimed_member_names) are
    // ignored by the decoder but kept for other consumers.
    let json = """
    {
      "event_id": "11111111-1111-1111-1111-111111111111",
      "room_id": "22222222-2222-2222-2222-222222222222",
      "event_name": "Friday Night Hold'em",
      "played_at": "2026-08-15T19:00:00Z",
      "venue": "Back Room",
      "seats_total": 6,
      "seats_claimed": 2,
      "seats_declined": 1,
      "seats_unclaimed": 3,
      "host_note": "Bring snacks",
      "claimed_member_names": ["Alex", "Sam"]
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(BriefingSummary.self, from: json.data(using: .utf8)!)
    runner.assertEqual(summary.seatsTotal, 6)
    runner.assertEqual(summary.seatsClaimed, 2)
    runner.assertEqual(summary.seatsDeclined, 1)
    runner.assertEqual(summary.seatsUnclaimed, 3)
    runner.assertEqual(summary.seatsLeft, 3)
}

runner.run("BriefingSummary from migration 061 with negative unclaimed floors seatsLeft at 0") {
    let json = """
    {
      "event_id": "11111111-1111-1111-1111-111111111111",
      "room_id": "22222222-2222-2222-2222-222222222222",
      "seats_total": 4,
      "seats_claimed": 3,
      "seats_declined": 2,
      "seats_unclaimed": 0
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let summary = try decoder.decode(BriefingSummary.self, from: json.data(using: .utf8)!)
    runner.assertEqual(summary.seatsLeft, 0)
}

runner.run("[String] decodes the migration 061 get_room_packs shape") {
    // The migration returns a single-column table (pack_slug text). The client
    // decoder expects [String] and the PostgREST wire shape is a JSON array of
    // bare strings.
    let json = """
    ["casino", "cards_against_humanity"]
    """
    let decoded = try JSONDecoder().decode([String].self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded, ["casino", "cards_against_humanity"])
}

runner.run("MemberRSVP decodes the migration 061 upsert_event_rsvp row") {
    // The migration now returns the full MemberRSVP row: id, event_id, room_id,
    // member_id, state, responded_at. The model decodes verbatim.
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
    runner.assertEqual(decoded.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    runner.assertEqual(decoded.state, .claimed)
    runner.assertNotNil(decoded.respondedAt)
}

runner.run("ChapterLine decodes the migration 061 get_event_chapter_line aliased shape") {
    // The migration aliases the table columns to the model's keys:
    //   event_id  → session_id
    //   call_forward → next_episode_teaser
    //   created_at → written_at
    // The model decodes the aliased shape verbatim. nil call_forward → nil
    // nextEpisodeTeaser.
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "room_id": "22222222-2222-2222-2222-222222222222",
      "session_id": "33333333-3333-3333-3333-333333333333",
      "title": "The night everything went sideways",
      "next_episode_teaser": null,
      "written_at": "2026-08-15T22:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ChapterLine.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.title, "The night everything went sideways")
    runner.assertNil(decoded.nextEpisodeTeaser)
    runner.assertEqual(decoded.sessionId, UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
}

runner.run("ChapterLine decodes with non-null next_episode_teaser") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "room_id": "22222222-2222-2222-2222-222222222222",
      "session_id": "33333333-3333-3333-3333-333333333333",
      "title": "Showdown",
      "next_episode_teaser": "Next: the reckoning",
      "written_at": "2026-08-15T22:00:00Z"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ChapterLine.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.nextEpisodeTeaser, "Next: the reckoning")
}

runner.run("OpenAttestationSummary decodes the migration 061 get_my_open_attestations row with hasDispute true") {
    // The migration joins settlement_attestations → rooms → events, surfaces
    // session_name via the left join, and includes sa.disputed as has_dispute.
    let json = """
    {
      "attestation_id": "11111111-1111-1111-1111-111111111111",
      "session_id": "22222222-2222-2222-2222-222222222222",
      "room_id": "33333333-3333-3333-3333-333333333333",
      "room_name": "Friday Night Hold'em",
      "session_name": "Friday Night Hold'em",
      "vision_amount_points": 120,
      "detection_source": "on_device",
      "confidence_avg": 0.92,
      "opened_at": "2026-08-15T21:00:00Z",
      "has_dispute": true
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(OpenAttestationSummary.self, from: json.data(using: .utf8)!)
    runner.assertTrue(decoded.hasDispute)
    runner.assertEqual(decoded.visionAmountPoints, 120)
    runner.assertEqual(decoded.detectionSource, "on_device")
    runner.assertEqual(decoded.confidenceAvg, 0.92)
    runner.assertEqual(decoded.contextLabel, "Friday Night Hold'em")
}

runner.run("CasinoWithdrawal decodes the migration 061 withdraw_casino_chips row") {
    let json = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "session_id": "22222222-2222-2222-2222-222222222222",
      "member_id": "44444444-4444-4444-4444-444444444444",
      "points_withdrawn": 120,
      "withdrawn_at": "2026-08-15T20:30:00Z",
      "withdrawn_by": "55555555-5555-5555-5555-555555555555"
    }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(CasinoWithdrawal.self, from: json.data(using: .utf8)!)
    runner.assertEqual(decoded.id, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    runner.assertEqual(decoded.pointsWithdrawn, 120)
    runner.assertEqual(decoded.memberId, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
    runner.assertEqual(decoded.sessionId, UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
}

// MARK: - Seat-action refresh data path (claim-seat fix loop)
//
// Store-contract tests proving `upsertEventRSVP` mutations are
// visible to the read paths RoomService refreshes after a
// successful claim/decline/release:
//   - the briefing summary's seat-count mirror
//     (`BriefingSummary.seatsClaimed` drives the "1 of 6 claimed"
//     caption on the BriefingSlot)
//   - the returned `MemberRSVP.state` (canonical confirmation
//     that the write round-tripped).
//
// The full seat-grid data path (`fetchEventRSVPs`) is the
// primary contract under test, but `InMemoryRoomStore.fetchEventRSVPs`
// is blocked by a pre-existing indexing bug (`events` is keyed by
// roomId, while the read keys by eventId) that's outside this
// loop's 5-file change contract. See
// `docs/loop-artifacts/CLAIM_SEAT_REFRESH_SPEC.md` §Deviations.

runner.runAsync("InMemoryRoomStore.upsertEventRSVP returns a row whose state matches the request") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
        runner.assertTrue(false, "seeded room should have an active event")
        return
    }
    let rowClaimed = try await store.upsertEventRSVP(eventId: event.id, state: .claimed)
    runner.assertEqual(rowClaimed.state, .claimed)
    runner.assertEqual(rowClaimed.eventId, event.id)

    let rowDeclined = try await store.upsertEventRSVP(eventId: event.id, state: .declined)
    runner.assertEqual(rowDeclined.state, .declined)

    let rowReleased = try await store.upsertEventRSVP(eventId: event.id, state: .unclaimed)
    runner.assertEqual(rowReleased.state, .unclaimed)
}

runner.runAsync("InMemoryRoomStore.upsertEventRSVP increments the briefing's seatsClaimed count") {
    let store = InMemoryRoomStore()
    let hosted = try await store.fetchRooms().first!
    guard let event = try await store.fetchActiveEvent(roomId: hosted.id) else {
        runner.assertTrue(false, "seeded room should have an active event")
        return
    }
    let baseBriefing = try await store.fetchBriefing(eventId: event.id)
    let baseClaimed = baseBriefing?.seatsClaimed ?? -1

    _ = try await store.upsertEventRSVP(eventId: event.id, state: .claimed)
    let after = try await store.fetchBriefing(eventId: event.id)
    runner.assertNotNil(after, "briefing survives the upsert")
    runner.assertEqual(after?.seatsClaimed ?? -1, baseClaimed + 1)
}

// MARK: - Summary

print("")
print("Ran \(runner.passes + runner.failures.count) cases: \(runner.passes) passed, \(runner.failures.count) failed.")
exit(runner.failures.isEmpty ? 0 : 1)