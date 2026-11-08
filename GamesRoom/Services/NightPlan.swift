//
//  NightPlan.swift
//  GamesRoom
//
//  S1 lane (night lifecycle) — the one action the night is waiting for.
//
//  Foundation only, no I/O, no clock, no network. The caller resolves
//  every fact (who has arrived, how many rounds are scored, what the
//  viewer has withdrawn) and hands them in as a `NightInput`; the plan
//  turns those facts into ONE primary action plus the grey secondary
//  lines under it.
//
//  Why this file exists (audit 02-workflows #19 and #8): the room page
//  decided the in-night button from `event.packSlug` — the "headline
//  pack", whichever pack the host tapped last. On a Casino + Monopoly
//  Deal night that sent the host's "Score a round" to the chip
//  scanner; on a Monopoly Deal only night it sent every member to a
//  casino withdrawal sheet for a pack that was not being played. The
//  pack list (`event.packSlugs`) is the contract, and the plan reads
//  the list, never the headline.
//
//  The rules, in one place:
//
//    Member, live night:
//      held deposit and not withdrawn -> checkIn
//      else casino in packs            -> withdrawChips
//      else CAH in packs               -> countCAH
//      else                            -> nil
//
//    Host, live night:
//      nobody arrived                  -> waitingForTable
//      arrived, no round scored yet    -> scoreRound (the scorable
//                                         packs) when there are any,
//                                         else settleNight
//      a round is scored               -> settleNight, with
//                                         scoreRound as a secondary
//      the host also gets their member action as a secondary
//
//    Host, night settled inside the recap window -> planNextNight
//
//  `claimSeat` is the RSVP action for a night that has not started. The
//  plan does not emit it: `NightInput` carries no claim state, so it
//  cannot tell "has not claimed" from "already claimed", and the RSVP
//  CTA still belongs to the briefing slot. Offering an action the
//  viewer cannot act on is worse than offering none.
//

import Foundation

/// The one thing the night is waiting for.
enum NightAction: Equatable {
    /// Claim a seat on a night that has not started.
    case claimSeat
    /// "I'm here" — reclaim the deposit the room is holding.
    case checkIn
    /// Withdraw casino chips to play.
    case withdrawChips
    /// Count the Cards Against Humanity cards.
    case countCAH
    /// Nobody has arrived yet. Caption only, no button.
    case waitingForTable(arrived: Int, claimed: Int)
    /// Score a round of one of these packs.
    case scoreRound(packs: [String])
    /// Close the night out.
    case settleNight
    /// Schedule the next night.
    case planNextNight
}

/// Every fact the plan needs, handed in by the caller.
struct NightInput: Equatable {
    /// The viewer hosts the room.
    var isHost: Bool
    /// Every pack the host picked for this night (`event.packSlugs`).
    var packSlugs: [String]
    /// When the night starts.
    var playedAt: Date
    /// When the night was settled, if it has been.
    var settledAt: Date?
    /// The clock, passed in so the plan stays pure.
    var now: Date
    /// Members who have arrived (checked in or played).
    var arrivedCount: Int
    /// Members who claimed a seat.
    var claimedCount: Int
    /// Rounds already scored for this event.
    var roundsScored: Int
    /// The room is still holding a deposit for the viewer.
    var iHaveHeldDeposit: Bool
    /// The viewer has already withdrawn, so the deposit is spent.
    var iHaveWithdrawn: Bool
}

/// The plan for one viewer and one night: one primary action, the
/// grey secondary lines under it.
struct NightPlan: Equatable {
    /// The one thing the viewer does next. `nil` when there is
    /// nothing for them to do.
    var primary: NightAction?
    /// The secondary actions, rendered as grey caption text under the
    /// primary.
    var secondaries: [NightAction]

    /// How long after a night is settled the recap still counts as
    /// the night that just happened (24 hours, the same window the
    /// room page's ceremonial card uses).
    static let recapWindow: TimeInterval = 86_400

    /// The plan for the night as it stands.
    static func plan(for input: NightInput) -> NightPlan {
        if let settledAt = input.settledAt {
            // The night is over. Inside the recap window the host
            // plans the next one; outside it the night is history and
            // the page shows the standings.
            guard settledAt > input.now.addingTimeInterval(-recapWindow) else {
                return NightPlan(primary: nil, secondaries: [])
            }
            return NightPlan(primary: input.isHost ? .planNextNight : nil, secondaries: [])
        }
        guard input.playedAt <= input.now else {
            // The night has not started. The RSVP CTA still belongs to
            // the briefing slot; the plan has no claim state to work
            // from, so it offers nothing.
            return NightPlan(primary: nil, secondaries: [])
        }
        let memberAction = memberAction(for: input)
        guard input.isHost else {
            return NightPlan(primary: memberAction, secondaries: [])
        }
        let scorable = scorablePacks(in: input.packSlugs)
        var secondaries: [NightAction] = []
        let primary: NightAction
        if input.arrivedCount == 0 {
            primary = .waitingForTable(arrived: input.arrivedCount, claimed: input.claimedCount)
        } else if input.roundsScored == 0 {
            primary = scorable.isEmpty ? .settleNight : .scoreRound(packs: scorable)
        } else {
            primary = .settleNight
            if !scorable.isEmpty {
                secondaries.append(.scoreRound(packs: scorable))
            }
        }
        // The host plays too: their own member action rides under the
        // host action, after the night's own progress line.
        if let memberAction {
            secondaries.append(memberAction)
        }
        return NightPlan(primary: primary, secondaries: secondaries)
    }

    /// The member's own action for the night. The held deposit comes
    /// first: getting the deposit back is what they came for, and the
    /// casino withdrawal waits until they have checked in.
    private static func memberAction(for input: NightInput) -> NightAction? {
        if input.iHaveHeldDeposit && !input.iHaveWithdrawn { return .checkIn }
        if input.packSlugs.contains(CasinoPack.slug) { return .withdrawChips }
        if input.packSlugs.contains(CardsAgainstHumanityPack.slug) { return .countCAH }
        return nil
    }

    /// The packs the host can score a round of: the single-winner
    /// packs (Monopoly Deal) and the count packs (Cards Against
    /// Humanity). The casino pack is `withdraw_return` — the host
    /// settles chips, not rounds — so it is never scorable.
    ///
    /// The pack list comes from the registry, the same source the room
    /// page reads for its single-winner gate.
    static func scorablePacks(in packSlugs: [String]) -> [String] {
        var seen: Set<String> = []
        return packSlugs.filter { slug in
            guard let type = PackRegistry.shared.definition(for: slug)?.scoringType else { return false }
            guard type == .singleWinner || type == .countBased else { return false }
            return seen.insert(slug).inserted
        }
    }
}
