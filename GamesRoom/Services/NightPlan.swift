//
//  NightPlan.swift
//  GamesRoom
//
//  The one action the night is waiting for, per viewer.
//
//  Foundation only, no I/O, no clock, no network. The caller resolves
//  every fact and hands them in as a `NightInput`; the plan turns them
//  into ONE primary action, the quiet lines under it, and a caption.
//
//  Every night is scored in chips (product decision, 2026-11-10):
//  everyone takes chips from the bank, plays anything (winners are paid
//  out in chips), and scans what is in front of them at the end. The
//  scan is the cash-out. There is no other way to score, so the night
//  has one loop and the plan walks each person through it:
//
//    I'm here (held deposit)  ->  Take chips  ->  Cash out  ->  done
//
//  The rules per phase:
//
//    upcoming / none   -> nothing (the RSVP CTA is the briefing slot)
//    past / cancelled  -> nothing (the page shows the standings)
//    recap             -> the host plans the next night
//    stranded          -> the host settles, caption "The night is still
//                         open"; members nothing
//
//    Live, everyone (host included — the host plays too):
//      held deposit, no chips yet -> checkIn
//      no chips yet               -> takeChips
//      chips on the table         -> cashOut, with "Take more chips"
//                                    as the one line under it
//
//    Live, member who has cashed out -> nothing to tap; the caption
//      says the host settles once everyone has cashed out.
//
//    Live, host who has cashed out (or never took chips):
//      someone still playing -> waitingForCashOut(names) as the primary
//                               (a caption, no button), "Settle the night"
//                               as the line under it (the view confirms,
//                               naming who has not cashed out)
//      nobody still playing, someone cashed out -> settleNight
//      nobody has taken chips at all            -> takeChips
//
//  "Settle the night" is never the primary while anyone is still
//  playing: settling early is the one move that can strand someone's
//  chips, so it is the quiet line and it asks first.
//

import Foundation

/// The one thing the night is waiting for.
enum NightAction: Equatable {
    /// Claim a seat on a night that has not started.
    case claimSeat
    /// "I'm here" — reclaim the deposit the room is holding.
    case checkIn
    /// Take chips from the bank. As a secondary line it is the top-up.
    case takeChips
    /// Scan the chips in front of you: the cash-out.
    case cashOut
    /// The host is waiting on these players to cash out. Caption only.
    case waitingForCashOut(names: [String])
    /// Close the night out.
    case settleNight
    /// Schedule the next night.
    case planNextNight
}

/// Where the viewer is in tonight's chip loop.
enum MyChips: Equatable {
    case none
    case playing
    case cashedOut
}

/// Every fact the plan needs, handed in by the caller.
struct NightInput: Equatable {
    /// The viewer hosts the room.
    var isHost: Bool
    /// The night's phase, from `NightPhaseResolver`. The plan reads the
    /// phase, never `playedAt`/`settledAt` comparisons of its own.
    var phase: NightPhase
    /// The room is still holding a deposit for the viewer.
    var iHaveHeldDeposit: Bool = false
    /// The viewer's own chips (`WorkingHand.tookChips` / `.isCashedOut`).
    var myChips: MyChips = .none
    /// Everyone else still playing (took chips, not cashed out), by name.
    var othersPlaying: [String] = []
    /// At least one other player has cashed out tonight.
    var othersCashedOut: Bool = false
}

/// The plan for one viewer and one night.
struct NightPlan: Equatable {
    /// The one thing the viewer does next. `nil` when there is nothing
    /// for them to do.
    var primary: NightAction?
    /// The quiet lines under the primary.
    var secondaries: [NightAction]
    /// A grey line for a state that needs a word of explanation.
    var caption: String? = nil

    /// How long after a night is settled the recap still counts as
    /// the night that just happened.
    static let recapWindow: TimeInterval = NightPhaseResolver.recapWindow

    /// The caption on a night whose auto-close window has gone and
    /// which nobody settled.
    static let strandedCaption = "The night is still open"

    /// The caption for a member who has cashed out.
    static let cashedOutCaption = "You've cashed out. The host settles the night once everyone has."

    /// The plan for the night as it stands.
    static func plan(for input: NightInput) -> NightPlan {
        switch input.phase {
        case .none, .upcoming, .past, .cancelled:
            return NightPlan(primary: nil, secondaries: [])
        case .recap:
            return NightPlan(primary: input.isHost ? .planNextNight : nil, secondaries: [])
        case .stranded:
            guard input.isHost else { return NightPlan(primary: nil, secondaries: []) }
            return NightPlan(primary: .settleNight, secondaries: [], caption: strandedCaption)
        case .live:
            return livePlan(for: input)
        }
    }

    private static func livePlan(for input: NightInput) -> NightPlan {
        switch input.myChips {
        case .none:
            if input.iHaveHeldDeposit {
                return NightPlan(primary: .checkIn, secondaries: [])
            }
            // A host who is only hosting: once the table has played
            // and nobody is left playing, the night is theirs to close.
            if input.isHost, input.othersCashedOut {
                return hostClosing(input)
            }
            return NightPlan(primary: .takeChips, secondaries: [])
        case .playing:
            return NightPlan(primary: .cashOut, secondaries: [.takeChips])
        case .cashedOut:
            guard input.isHost else {
                return NightPlan(primary: nil, secondaries: [], caption: cashedOutCaption)
            }
            return hostClosing(input)
        }
    }

    /// The host's own chips are done: settle, or wait for the table.
    private static func hostClosing(_ input: NightInput) -> NightPlan {
        if input.othersPlaying.isEmpty {
            return NightPlan(primary: .settleNight, secondaries: [])
        }
        return NightPlan(
            primary: .waitingForCashOut(names: input.othersPlaying),
            secondaries: [.settleNight]
        )
    }

    /// "Waiting on Sam and Jo to cash out".
    static func waitingCaption(names: [String]) -> String {
        "Waiting on \(NameList.joined(names)) to cash out"
    }

    /// The confirmation before settling with people still playing.
    static func settleEarlyWarning(names: [String]) -> String {
        let who = NameList.joined(names)
        let verb = names.count == 1 ? "hasn't" : "haven't"
        return "\(who) \(verb) cashed out. Settle the night anyway?"
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
