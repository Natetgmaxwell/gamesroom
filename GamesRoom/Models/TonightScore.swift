//
//  TonightScore.swift
//  GamesRoom
//
//  The night's own scoreboard, in chips.
//
//  Every night is scored the same way: everyone takes chips from the
//  bank, plays anything (winners are paid out in chips), and at the end
//  scans what is in front of them. A scan is the cash-out. This file
//  answers, for one night: who has chips, who is still playing, who has
//  cashed out, and how far up or down each of them finished.
//
//  Pure derivation of two reads the page already makes:
//    * `get_event_working_hands` — per member: chips on the table,
//      whether they have scanned, their latest scan.
//    * `get_event_transactions` — every `casino_settlement` row; the
//      sum per member is their net for the night. It is the same row
//      the season leaderboard sums, so tonight's number and the
//      standings can never disagree.
//
//  One rule, one place: "cashed out" is `WorkingHand.isCashedOut`
//  (scanned, and no chips taken since the scan). The night plan, the
//  live card and this board all read it.
//

import Foundation

extension WorkingHand {
    /// This member took chips tonight (they are in the game).
    var tookChips: Bool { workingHand > 0 || hasScanned }

    /// This member has scanned their chips back in and has taken none
    /// since. `workingHand` is the latest scan plus every withdrawal
    /// after it (migration 074), so a fresh top-up after a scan makes
    /// the two differ and the member is playing again.
    var isCashedOut: Bool {
        guard hasScanned, let scannedValue else { return false }
        return scannedValue == workingHand
    }
}

/// Where one player is in tonight's chip loop.
enum ChipStatus: Equatable {
    /// Has not taken chips yet.
    case noChips
    /// Has chips on the table and has not cashed out.
    case playing
    /// Scanned back in. `net` is what they finished up (or down).
    case cashedOut(net: Int64)
}

/// Joins names the way people say them: "Sam", "Sam and Jo",
/// "Sam, Jo and Alex".
enum NameList {
    static func joined(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }
}

/// Tonight's tally for one event.
struct TonightScore: Equatable {
    struct Row: Equatable, Identifiable {
        let memberId: UUID
        let name: String
        let status: ChipStatus
        var id: UUID { memberId }

        var net: Int64? {
            if case .cashedOut(let net) = status { return net }
            return nil
        }
    }

    /// Cashed-out players first (highest net first), then everyone
    /// still playing, then anyone without chips. Ties break on name so
    /// the order never shuffles between renders.
    let rows: [Row]

    var playing: [Row] { rows.filter { $0.status == .playing } }
    var cashedOut: [Row] { rows.filter { $0.net != nil } }
    /// Players who have taken chips tonight (playing or cashed out).
    var inTheGame: [Row] { rows.filter { $0.status != .noChips } }

    /// The players on the top net, when the top net is above zero.
    var leaders: [Row] {
        guard let top = cashedOut.first?.net, top > 0 else { return [] }
        return cashedOut.filter { $0.net == top }
    }

    /// The one sentence at the top of the board.
    var headline: String {
        let leaders = leaders
        if let net = leaders.first?.net {
            let names = NameList.joined(leaders.map(\.name))
            return leaders.count == 1 ? "\(names) is up \(net)" : "\(names) are up \(net)"
        }
        if !cashedOut.isEmpty { return "Nobody has finished up yet" }
        if !playing.isEmpty { return "Game on. Scores land as people cash out." }
        return "Everyone takes chips to start"
    }

    /// "2 of 5 cashed out", nil before anyone has taken chips.
    var progressCaption: String? {
        let total = inTheGame.count
        guard total > 0 else { return nil }
        return "\(cashedOut.count) of \(total) cashed out"
    }

    /// The tally from the night's reads.
    ///
    /// - Parameters:
    ///   - hands: `get_event_working_hands` rows.
    ///   - transactions: `get_event_transactions` rows (any kinds).
    ///   - players: members who should show even before they take chips
    ///     (claimed seats). Anyone who took chips always shows.
    ///   - names: display names by member id (falls back to the hand's).
    static func tally(
        hands: [WorkingHand],
        transactions: [EventTransaction],
        players: [UUID] = [],
        names: [UUID: String] = [:]
    ) -> TonightScore {
        var net: [UUID: Int64] = [:]
        for tx in transactions where tx.kind == "casino_settlement" {
            net[tx.memberId, default: 0] += tx.amountPoints
        }
        var statuses: [UUID: ChipStatus] = [:]
        var handNames: [UUID: String] = [:]
        for id in players { statuses[id] = .noChips }
        for hand in hands {
            handNames[hand.memberId] = hand.displayName
            if hand.isCashedOut {
                statuses[hand.memberId] = .cashedOut(net: net[hand.memberId] ?? 0)
            } else if hand.tookChips {
                statuses[hand.memberId] = .playing
            }
        }
        func order(_ status: ChipStatus) -> Int {
            switch status {
            case .cashedOut: return 0
            case .playing: return 1
            case .noChips: return 2
            }
        }
        let rows = statuses.map { id, status in
            Row(memberId: id, name: names[id] ?? handNames[id] ?? "Someone", status: status)
        }
        .sorted { lhs, rhs in
            if order(lhs.status) != order(rhs.status) { return order(lhs.status) < order(rhs.status) }
            if let l = lhs.net, let r = rhs.net, l != r { return l > r }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return TonightScore(rows: rows)
    }
}

/// The plain-words "when" in front of a night's date: "Tonight",
/// "Tomorrow", "In 3 days". nil when the night is under way, already
/// past, or more than a week out (the date alone says it then).
enum NightWhen {
    static func label(playedAt: Date, now: Date, calendar: Calendar = .current) -> String? {
        guard playedAt > now else { return nil }
        let start = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: playedAt)
        guard let days = calendar.dateComponents([.day], from: start, to: day).day else { return nil }
        switch days {
        case 0:
            return calendar.component(.hour, from: playedAt) >= 17 ? "Tonight" : "Today"
        case 1:
            return "Tomorrow"
        case 2...6:
            return "In \(days) days"
        default:
            return nil
        }
    }
}
