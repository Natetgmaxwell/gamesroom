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
//  The plan reads `NightPhase`, never a pair of date comparisons: the
//  phase is the one answer to "where is this night", and every screen
//  that used to derive it separately now asks the same question. The
//  rules per phase:
//
//    recap                -> the host plans the next night
//    past / cancelled     -> nothing (the page shows the standings)
//    upcoming / none      -> nothing (the RSVP CTA is the briefing slot)
//    stranded             -> the host settles it, with the caption
//                            "The night is still open"; members nothing
//
//    Member, live night:
//      held deposit and not withdrawn -> checkIn
//      else casino in packs            -> withdrawChips
//      else CAH in packs               -> countCAH
//      else                            -> nil
//
//    Host, live night (fx30 — ONE primary, at most ONE line under it):
//      nobody arrived, seats claimed   -> waitingForTable as the caption,
//                                         with scoreRound as the one line
//                                         under it (a host can always
//                                         record a round)
//      nothing scored tonight          -> scoreRound, nothing under it
//      something scored tonight        -> settleNight, with scoreRound
//                                         as the one line under it
//
//      "Scored" is a non-correction round OR a casino settlement (a
//      scan) for this event. The host's own player actions (withdraw,
//      settle chips, withdraw more, count CAH) are NOT lines under the
//      primary: they live in the "Score a round" picker, which lists
//      every pack on the night with Casino chips first.
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
    /// Open the score picker: one entry per pack on the night, casino
    /// chips first. One pack routes straight into it.
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
    /// The night's phase, from `NightPhaseResolver`. The plan reads the
    /// phase, never `playedAt`/`settledAt` comparisons of its own: one
    /// rule, one place (audit 01 §3.1).
    var phase: NightPhase
    /// Members who have arrived (checked in or played).
    var arrivedCount: Int
    /// Members who claimed a seat.
    var claimedCount: Int
    /// Rounds already scored for this event.
    var roundsScored: Int
    /// fx30 — casino settlements (scans) already recorded for this
    /// event. A settled hand is "something scored tonight" for the
    /// host's card: the casino pack is played by settling chips, not
    /// by scoring rounds, so rounds alone would leave a casino-only
    /// night looking untouched.
    var casinoSettlements: Int = 0
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
    /// A grey line under the primary, for a state that needs a word of
    /// explanation. `nil` for every state that speaks for itself.
    var caption: String? = nil

    /// How long after a night is settled the recap still counts as
    /// the night that just happened (24 hours, the same window the
    /// room page's ceremonial card uses).
    static let recapWindow: TimeInterval = NightPhaseResolver.recapWindow

    /// The caption on a night whose auto-close window has gone and
    /// which nobody settled. New copy for a state that did not exist
    /// until the phase did.
    static let strandedCaption = "The night is still open"

    /// The plan for the night as it stands.
    static func plan(for input: NightInput) -> NightPlan {
        switch input.phase {
        case .none, .upcoming:
            // No night, or one that has not started. The RSVP CTA still
            // belongs to the briefing slot; the plan has no claim state
            // to work from, so it offers nothing.
            return NightPlan(primary: nil, secondaries: [])
        case .recap:
            // Inside the recap window the host plans the next one.
            return NightPlan(primary: input.isHost ? .planNextNight : nil, secondaries: [])
        case .past, .cancelled:
            // History. The page shows the standings.
            return NightPlan(primary: nil, secondaries: [])
        case .stranded:
            // The window has gone and nobody settled. The night is still
            // the host's to close; there is nothing for a member to do.
            guard input.isHost else { return NightPlan(primary: nil, secondaries: []) }
            return NightPlan(primary: .settleNight, secondaries: [], caption: strandedCaption)
        case .live:
            return livePlan(for: input)
        }
    }

    /// The plan for a night that is live right now.
    ///
    /// fx30 — the host gets ONE primary and at most ONE grey line under
    /// it. The host's own player actions are not lines any more; they
    /// live in the "Score a round" picker, so nothing under the primary
    /// competes with the night's own progress.
    private static func livePlan(for input: NightInput) -> NightPlan {
        let memberAction = memberAction(for: input)
        guard input.isHost else {
            return NightPlan(primary: memberAction, secondaries: [])
        }
        let scorable = scorablePacks(in: input.packSlugs)
        let scoreLine = scorable.isEmpty ? nil : NightAction.scoreRound(packs: scorable)
        // "Scored" means a non-correction round OR a casino settlement:
        // the casino pack is played by settling a hand, not by scoring
        // a round, and a night where the chips are settled is under way.
        let hasScored = input.roundsScored > 0 || input.casinoSettlements > 0

        if !hasScored, input.arrivedCount == 0, input.claimedCount > 0 {
            // A room with claimed seats and nobody at the table yet.
            // The caption is the primary slot (no button); the host can
            // still record a round, so that is the one line under it.
            // claimed == 0 never reaches here: "0 of 0 here" was noise.
            return NightPlan(
                primary: .waitingForTable(arrived: input.arrivedCount, claimed: input.claimedCount),
                secondaries: scoreLine.map { [$0] } ?? []
            )
        }
        if hasScored {
            return NightPlan(primary: .settleNight, secondaries: scoreLine.map { [$0] } ?? [])
        }
        return NightPlan(primary: scoreLine ?? .settleNight, secondaries: [])
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

    /// The packs the host can score tonight, in picker order: the
    /// casino pack first (it is played by settling chips, so its label
    /// is "Casino chips"), then the rest in the night's own pack order.
    ///
    /// fx30 — the casino pack used to be excluded here because it is
    /// `withdrawReturn` and the host "settles chips, not rounds". That
    /// left the score picker offering only the side packs on a casino
    /// night and put the host's chip actions in grey lines under the
    /// primary. The picker is now the one place the host picks a pack.
    ///
    /// The pack list comes from the registry, the same source the room
    /// page reads for its single-winner gate.
    static func scorablePacks(in packSlugs: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered = packSlugs.filter { slug in
            guard let type = PackRegistry.shared.definition(for: slug)?.scoringType else { return false }
            guard type == .singleWinner || type == .countBased || type == .withdrawReturn else { return false }
            return seen.insert(slug).inserted
        }
        // Casino chips come first whenever the night has the pack.
        if let index = ordered.firstIndex(of: CasinoPack.slug) {
            ordered.remove(at: index)
            ordered.insert(CasinoPack.slug, at: 0)
        }
        return ordered
    }

    /// The label for one pack in the "Score which game?" picker. The
    /// casino option is the host's chip actions in one place, so it
    /// says "Casino chips"; every other pack keeps its display name.
    static func pickerTitle(for slug: String) -> String {
        if slug == CasinoPack.slug { return "Casino chips" }
        return PackRegistry.shared.definition(for: slug)?.displayName ?? slug
    }
}

// MARK: - Next round (S1.6)

/// Where the host's score sheet starts: the round after the highest
/// round already scored for the night, across every pack, so a save
/// never lands on a round that already has a result.
struct NextRound: Equatable {
    /// The round the sheet scores. 1 when nothing is scored yet.
    let index: Int
    /// Who won the round before it (positive points), in the order
    /// they were entered. Empty for round 1 or a round with no
    /// winner recorded.
    let lastWinnerIds: [UUID]

    /// The next round for a night, from the night's scored rounds
    /// (every pack). A corrected round counts once: its latest row
    /// names the winners.
    static func after(_ rounds: [EventRound]) -> NextRound {
        guard let last = rounds.map(\.roundIndex).max() else {
            return NextRound(index: 1, lastWinnerIds: [])
        }
        let latest = rounds
            .filter { $0.roundIndex == last }
            .max { $0.createdAt < $1.createdAt }
        var seen: Set<UUID> = []
        let winners = (latest?.entries ?? [])
            .filter { $0.pointsDelta > 0 }
            .map(\.memberId)
            .filter { seen.insert($0).inserted }
        return NextRound(index: last + 1, lastWinnerIds: winners)
    }

    /// The caption under "Round {n}": "Last: Sam won round 2".
    /// nil for round 1, or when the last round has no named winner.
    static func lastLine(winnerNames: [String], round: Int) -> String? {
        guard round > 1, !winnerNames.isEmpty else { return nil }
        let names: String
        if winnerNames.count == 1 {
            names = winnerNames[0]
        } else {
            names = winnerNames.dropLast().joined(separator: ", ") + " and " + winnerNames[winnerNames.count - 1]
        }
        return "Last: \(names) won round \(round - 1)"
    }
}

// MARK: - Recap above the next night (S1.7)

extension NightPlan {
    /// The settled night that renders as its own section above the
    /// next night's card: settled inside the recap window, and the
    /// active event is a different night that has not been settled
    /// (the next one is on the books, or under way). When the active
    /// event IS the settled night, the recap is the page's slot and
    /// this returns nil.
    static func recapAboveNextNight(
        recent: Event?,
        active: Event?,
        now: Date,
        autoCloseHours: Int = NightPhaseResolver.defaultAutoCloseHours
    ) -> Event? {
        guard let recent,
              NightPhaseResolver.phase(
                for: recent, autoCloseHours: autoCloseHours, now: now
              ) == .recap else { return nil }
        guard let active, active.id != recent.id else { return nil }
        // The recap sits above a night that is still ahead of it: the
        // next one on the books, or one under way (including a night
        // whose window has run out - it still owns the slot).
        switch NightPhaseResolver.phase(for: active, autoCloseHours: autoCloseHours, now: now) {
        case .upcoming, .live, .stranded: return recent
        case .none, .recap, .past, .cancelled: return nil
        }
    }
}

// MARK: - Season awards window (S1.7)

/// Which closed season's awards every member sees: the most recently
/// ended season, for 7 days after it ended, until the member taps
/// Done.
enum SeasonAwardsWindow {
    /// 7 days.
    static let window: TimeInterval = 7 * 86_400

    /// UserDefaults key for "this member dismissed these awards".
    static func dismissedKey(seasonId: UUID) -> String {
        "seasonAwardsDismissed-\(seasonId.uuidString)"
    }

    /// The most recently ended season, if it ended inside the window
    /// and has not been dismissed. Only the latest season counts: an
    /// older season never comes back when the latest is dismissed.
    static func seasonToShow(_ seasons: [Season], now: Date, isDismissed: (UUID) -> Bool) -> Season? {
        let ended = seasons.compactMap { season -> (Season, Date)? in
            guard let endedAt = season.endedAt else { return nil }
            return (season, endedAt)
        }
        guard let latest = ended.max(by: { $0.1 < $1.1 }) else { return nil }
        guard latest.1 > now.addingTimeInterval(-window) else { return nil }
        guard !isDismissed(latest.0.id) else { return nil }
        return latest.0
    }
}
