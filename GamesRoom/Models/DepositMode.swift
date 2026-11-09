//
//  DepositMode.swift
//  GamesRoom
//
//  Lane P (state machines) — does this room hold a seat deposit?
//
//  One question, one answer. The app used to answer it in three places
//  with two different cache-miss defaults (audit 02 D5): `claimSeat`
//  read "no trigger column" as deposits-off and took the plain RSVP
//  path, `releaseSeat` read it as deposits-on and took the escrow path.
//  The server's rule (migration 113) is a third: a deposit is live only
//  when the trigger is `escrow` AND the amount is above zero.
//
//  Every call site already holds a `Room`, so the question is a property
//  of the room, not a lookup with a fallback.
//

import Foundation

/// How a room runs the seat deposit.
enum DepositMode: Equatable {
    /// No deposit: claims are plain RSVP upserts, the arrival card never
    /// renders, and nobody owes anybody a chip for not turning up.
    case off
    /// Every claimed seat holds `amount` points. Mirrors migration 113:
    /// `seat_deposit_trigger = 'escrow'` AND `seat_deposit_amount > 0`.
    case escrow(amount: Int)

    /// The amount in escrow, or `nil` when the room runs deposits off.
    var amount: Int? {
        if case .escrow(let amount) = self { return amount }
        return nil
    }

    var isEscrow: Bool { self != .off }
}

extension Room {
    /// The room's deposit mode. `(escrow, 0)` and `(off, 300)` both mean
    /// off: the amount is what a deposit costs, so zero of it is no
    /// deposit — the same normalisation the server applies before it
    /// decides whether to hold anything.
    var depositMode: DepositMode {
        guard seatDepositTrigger == .escrow, seatDepositAmount > 0 else { return .off }
        return .escrow(amount: seatDepositAmount)
    }
}
