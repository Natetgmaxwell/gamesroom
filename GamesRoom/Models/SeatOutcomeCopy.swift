//
//  SeatOutcomeCopy.swift
//  GamesRoom
//
//  Lane P (state machines) — what a seat action actually did.
//
//  checkInSeat, forfeitSeatDeposit and waiveSeatDeposit all return
//  `true` from the server for a no-op (audit 02 D3): the RPCs cannot tell
//  "applied" from "already mine" from "somebody else resolved it". The
//  client used to read `true` as success and fire a success haptic while
//  the member's deposit was already gone.
//
//  The service now force-reloads the deposit and returns it; this file
//  turns "before" and "after" into the one line the member reads. Pure,
//  so the copy is pinned by a table test rather than by a screenshot.
//

import Foundation

/// The line under a seat action, from the deposit before and after.
enum SeatOutcomeCopy {
    /// The tap returned the deposit.
    static let returned = "Your deposit is back."
    /// The deposit was already resolved when the tap landed.
    static let alreadyResolved = "That deposit was already resolved."
    /// There was no deposit to return.
    static let nothingHeld = "Nothing was held for this night."

    /// The member's "I'm here" outcome.
    ///
    /// - `nil` when the tap left a held deposit held — the button stays,
    ///   so there is nothing to say.
    static func checkIn(before: SeatDeposit?, after: SeatDeposit?) -> String? {
        guard let after else { return nothingHeld }
        switch after.status {
        case .returned:
            // A held deposit before the tap means this tap is what gave it
            // back; anything else was already done.
            return before?.status == .held ? returned : alreadyResolved
        case .forfeited, .waived:
            return alreadyResolved
        case .held:
            return nil
        }
    }

    /// The host's Keep / Give it back outcome. `after` is the deposit the
    /// service reloaded: still `.held` means the row the host was looking
    /// at had already been resolved by someone else (or by the member),
    /// so the tap changed nothing.
    static func hostResolved(_ after: SeatDeposit?) -> String? {
        guard let after else { return nothingHeld }
        return after.status == .held ? alreadyResolved : nil
    }
}
