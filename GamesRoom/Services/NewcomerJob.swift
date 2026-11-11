//
//  NewcomerJob.swift
//  GamesRoom
//
//  1.2.5 Task 3 — give the newcomer a job.
//
//  Foundation only, no state. The host's pre-night summary
//  (`BriefingSlot`) names up to two first-night members who have
//  claimed a seat and suggests a small job for each:
//
//    "Sam's first night. Give them a job: the bank, dealing, or the
//     first question."
//
//  Rules (all decided here, nowhere else):
//
//    1. Host only. Any other viewer gets no lines. The line is never
//       a push.
//    2. Before the night only. Any phase other than `.upcoming`
//       (live, stranded, recap, past...) gets no lines, so the line
//       disappears once the night is live. The phase comes from
//       `NightPhaseResolver`, never from a second clock read.
//    3. Only claimed seats. Unclaimed and declined rows never count.
//    4. First night = `BroughtBy.isFirstNight` (no settled night in
//       the room yet). The viewer is never named, even on the room's
//       very first night.
//    5. Earliest claims first, at most `maxLines`. A row with no
//       claim time sorts after every row that has one; ties keep the
//       order the rows came in.
//    6. A blank display name is skipped rather than rendered as
//       "'s first night."
//
//  The app never counts or ranks friendship: this is a prompt for
//  the host, not a tally, and nothing about it is stored.
//

import Foundation

enum NewcomerJob {

    /// At most this many newcomer lines per night.
    static let maxLines = 2

    /// One claimed (or unclaimed / declined) seat, as the summary sees it.
    struct Seat: Equatable {
        let memberId: UUID
        let displayName: String
        let state: MemberRSVPState
        /// When the seat was claimed, if the server said. nil sorts last.
        let claimedAt: Date?

        init(memberId: UUID, displayName: String, state: MemberRSVPState, claimedAt: Date? = nil) {
            self.memberId = memberId
            self.displayName = displayName
            self.state = state
            self.claimedAt = claimedAt
        }
    }

    /// The host's newcomer lines for one night. Empty when there is
    /// nothing to say, so the caller renders nothing at all.
    static func lines(isHost: Bool,
                      viewerId: UUID?,
                      phase: NightPhase,
                      seats: [Seat],
                      isFirstNight: (UUID) -> Bool) -> [String] {
        guard isHost, phase == .upcoming else { return [] }

        let newcomers = seats.enumerated().filter { _, seat in
            seat.state == .claimed
                && seat.memberId != viewerId
                && BroughtBy.nonEmpty(seat.displayName) != nil
                && isFirstNight(seat.memberId)
        }
        let ordered = newcomers.sorted { a, b in
            switch (a.element.claimedAt, b.element.claimedAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }
        return ordered.prefix(maxLines).compactMap { line(name: $0.element.displayName) }
    }

    /// "Sam's first night. Give them a job: the bank, dealing, or the
    /// first question."
    static func line(name: String) -> String? {
        guard let name = BroughtBy.nonEmpty(name) else { return nil }
        return "\(name)'s first night. Give them a job: the bank, dealing, or the first question."
    }
}
