//
//  SeatAvailability.swift
//  GamesRoom
//
//  Lane P (state machines) — can this member take a chair?
//
//  The room page used to remember a refusal in `nightFullEventIds`: the
//  server said `night_full` once, and the claim button stayed hidden
//  until the same member successfully claimed (audit 03 D1). If somebody
//  else then released a seat, the page kept saying "All 6 seats are
//  taken." until it was recreated. The latch is gone; this is derived
//  from the counts the briefing already refreshes.
//

import Foundation

/// Whether the viewer can take a chair on this night.
enum SeatAvailability: Equatable {
    /// A chair is free (or the viewer already holds one).
    case open
    /// Every chair is taken and the viewer does not hold one.
    case full
    /// The viewer already holds a chair — the counts do not matter.
    case youHoldOne

    /// The availability for one viewer.
    ///
    /// - Parameters:
    ///   - rsvp: the viewer's RSVP for the night.
    ///   - seatsClaimed: chairs claimed by active members, from the
    ///     briefing summary (or the seat grid while it loads).
    ///   - maxSeats: chairs at the table.
    static func compute(
        rsvp: MemberRSVPState,
        seatsClaimed: Int,
        maxSeats: Int
    ) -> SeatAvailability {
        if rsvp == .claimed { return .youHoldOne }
        guard maxSeats > 0 else { return .open }
        return seatsClaimed >= maxSeats ? .full : .open
    }
}
