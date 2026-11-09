//
//  SeatPhase.swift
//  GamesRoom
//
//  Lane P (state machines) — what is happening with this member's chair.
//
//  The chair card used to read RSVP state and deposit status inline, and
//  the two answers could disagree: "claimed" with no deposit row rendered
//  as if the room ran deposits off, which is exactly how a missing
//  deposit became invisible (audit 02 C2). Naming `.missingDeposit` is
//  the point of this file — a claimed seat in an escrow room with no
//  deposit behind it is an impossible state, and it should say so rather
//  than look like "deposits are off".
//

import Foundation

/// One member's chair for one night.
enum SeatPhase: Equatable {
    /// No answer, or the seat was given back.
    case open
    /// "Can't make it."
    case declined
    /// Claimed, and the room runs no deposit, so there is nothing to
    /// hold and nothing to reclaim.
    case claimedNoDeposit
    /// Claimed with the deposit still in escrow: "I'm here" is offered.
    case held(deposit: SeatDeposit)
    /// Claimed and arrived — the deposit came back.
    case arrived(deposit: SeatDeposit)
    /// Claimed, the host kept the deposit. Terminal for the member.
    case noShow(deposit: SeatDeposit)
    /// Claimed in an escrow room with no deposit row. Impossible from
    /// the server's own writers; rendered so it cannot hide.
    case missingDeposit

    /// The phase for one member, from the three facts the server keeps.
    static func phase(
        rsvp: MemberRSVPState,
        deposit: SeatDeposit?,
        mode: DepositMode
    ) -> SeatPhase {
        switch rsvp {
        case .unclaimed:
            return .open
        case .declined:
            return .declined
        case .claimed:
            guard let deposit else {
                return mode.isEscrow ? .missingDeposit : .claimedNoDeposit
            }
            switch deposit.status {
            case .held:      return .held(deposit: deposit)
            case .returned:  return .arrived(deposit: deposit)
            case .forfeited: return .noShow(deposit: deposit)
            case .waived:    return .noShow(deposit: deposit)
            }
        }
    }

    /// The deposit behind this chair, if any.
    var deposit: SeatDeposit? {
        switch self {
        case .held(let deposit), .arrived(let deposit), .noShow(let deposit):
            return deposit
        case .open, .declined, .claimedNoDeposit, .missingDeposit:
            return nil
        }
    }
}
