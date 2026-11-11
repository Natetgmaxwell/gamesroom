//
//  TestsNewcomerJob.swift
//  games-room
//
//  1.2.5 Task 3 — give the newcomer a job. The host's pre-night
//  summary names up to two first-night members who claimed a seat.
//  Registered from main.swift through `runNewcomerJobTests(runner)`.
//  Foundation only: runs in the macOS test binary with no simulator.

import Foundation

func runNewcomerJobTests(_ runner: TestRunner) {
    let host = UUID()
    let alex = UUID()   // a regular: 12 nights
    let sam = UUID()    // newcomer
    let jo = UUID()     // newcomer
    let kit = UUID()    // newcomer
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func entry(_ id: UUID, _ name: String, sessions: Int64) -> LeaderboardEntry {
        LeaderboardEntry(userId: id, displayName: name, role: id == host ? "host" : "member",
                         pointsBalance: 0, seasonScore: 0, sessionsPlayed: sessions,
                         lastSessionAt: nil, lastSessionDelta: 0, trajectory: [])
    }
    let board = [
        entry(host, "Host", sessions: 9),
        entry(alex, "Alex", sessions: 12),
        entry(sam, "Sam", sessions: 0),
        entry(jo, "Jo", sessions: 0),
        entry(kit, "Kit", sessions: 0)
    ]
    let firstNight: (UUID) -> Bool = { BroughtBy.isFirstNight($0, board: board) }

    func seat(_ id: UUID, _ name: String, _ state: MemberRSVPState = .claimed,
              at offset: TimeInterval? = nil) -> NewcomerJob.Seat {
        NewcomerJob.Seat(memberId: id, displayName: name, state: state,
                         claimedAt: offset.map { t0.addingTimeInterval($0) })
    }
    func line(_ name: String) -> String {
        "\(name)'s first night. Give them a job: the bank, dealing, or the first question."
    }

    struct Case {
        let name: String
        let isHost: Bool
        let phase: NightPhase
        let seats: [NewcomerJob.Seat]
        let expected: [String]
    }

    let cases: [Case] = [
        Case(name: "zero newcomers: no line",
             isHost: true, phase: .upcoming,
             seats: [seat(host, "Host"), seat(alex, "Alex")],
             expected: []),
        Case(name: "one newcomer: one line",
             isHost: true, phase: .upcoming,
             seats: [seat(host, "Host"), seat(alex, "Alex"), seat(sam, "Sam")],
             expected: [line("Sam")]),
        Case(name: "two newcomers: earliest claim first",
             isHost: true, phase: .upcoming,
             seats: [seat(sam, "Sam", at: 300), seat(jo, "Jo", at: 100)],
             expected: [line("Jo"), line("Sam")]),
        Case(name: "three newcomers: capped at the two earliest claims",
             isHost: true, phase: .upcoming,
             seats: [seat(kit, "Kit", at: 50), seat(sam, "Sam", at: 300), seat(jo, "Jo", at: 100)],
             expected: [line("Kit"), line("Jo")]),
        Case(name: "three newcomers without claim times: server order, capped at 2",
             isHost: true, phase: .upcoming,
             seats: [seat(sam, "Sam"), seat(jo, "Jo"), seat(kit, "Kit")],
             expected: [line("Sam"), line("Jo")]),
        Case(name: "a claim time sorts before no claim time",
             isHost: true, phase: .upcoming,
             seats: [seat(sam, "Sam"), seat(jo, "Jo"), seat(kit, "Kit", at: 0)],
             expected: [line("Kit"), line("Sam")]),
        Case(name: "non-host viewer: no line",
             isHost: false, phase: .upcoming,
             seats: [seat(sam, "Sam"), seat(jo, "Jo")],
             expected: []),
        Case(name: "unclaimed and declined newcomers: no line",
             isHost: true, phase: .upcoming,
             seats: [seat(sam, "Sam", .unclaimed), seat(jo, "Jo", .declined)],
             expected: []),
        Case(name: "member missing from the board is not a newcomer",
             isHost: true, phase: .upcoming,
             seats: [seat(UUID(), "Stranger")],
             expected: []),
        Case(name: "blank display name is skipped, not rendered",
             isHost: true, phase: .upcoming,
             seats: [seat(sam, "  "), seat(jo, "Jo")],
             expected: [line("Jo")])
    ]

    for c in cases {
        runner.run("NewcomerJob: \(c.name)") {
            runner.assertEqual(
                NewcomerJob.lines(isHost: c.isHost, viewerId: host, phase: c.phase,
                                  seats: c.seats, isFirstNight: firstNight),
                c.expected
            )
        }
    }

    runner.run("NewcomerJob: the line is gone in every phase but upcoming") {
        for phase in NightPhase.allCases {
            let lines = NewcomerJob.lines(isHost: true, viewerId: host, phase: phase,
                                          seats: [seat(sam, "Sam")], isFirstNight: firstNight)
            runner.assertTrue(lines.isEmpty == (phase != .upcoming), "phase \(phase)")
        }
    }

    runner.run("NewcomerJob: the host is never named, even on the room's first night") {
        let freshBoard = [entry(host, "Host", sessions: 0), entry(sam, "Sam", sessions: 0)]
        runner.assertEqual(
            NewcomerJob.lines(isHost: true, viewerId: host, phase: .upcoming,
                              seats: [seat(host, "Host", at: 0), seat(sam, "Sam", at: 10)],
                              isFirstNight: { BroughtBy.isFirstNight($0, board: freshBoard) }),
            [line("Sam")]
        )
    }

    runner.run("NewcomerJob: copy is AU casual, no em dash, at most two lines") {
        let text = line("Sam")
        runner.assertFalse(text.contains("—"))
        runner.assertFalse(text.contains("–"))
        runner.assertEqual(NewcomerJob.maxLines, 2)
        runner.assertEqual(NewcomerJob.line(name: " Sam "), text)
    }

    runner.run("BroughtBy.isFirstNight: zero sessions is new, absent is not") {
        runner.assertTrue(BroughtBy.isFirstNight(sam, board: board))
        runner.assertFalse(BroughtBy.isFirstNight(alex, board: board))
        runner.assertFalse(BroughtBy.isFirstNight(UUID(), board: board))
        runner.assertFalse(BroughtBy.isFirstNight(sam, board: []))
    }

    runner.run("EventRSVP: claimedAt decodes from responded_at and tolerates its absence") {
        let ev = UUID(), m = UUID()
        let without = #"{"event_id":"\#(ev)","member_id":"\#(m)","display_name":"Sam","state":"claimed"}"#
        let decoded = try JSONDecoder().decode(EventRSVP.self, from: Data(without.utf8))
        runner.assertNil(decoded.claimedAt)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let with = #"{"event_id":"\#(ev)","member_id":"\#(m)","display_name":"Sam","state":"claimed","responded_at":"2026-11-10T08:00:00Z"}"#
        runner.assertNotNil(try dec.decode(EventRSVP.self, from: Data(with.utf8)).claimedAt)
    }
}
