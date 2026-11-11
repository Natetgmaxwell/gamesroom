//
//  GladYouCame.swift
//  GamesRoom
//
//  1.2.5 Task 4 — "Glad you came". After a settled night, anyone who
//  had a seat can tell any number of the people they sat with that
//  they were glad to see them. Each recipient hears it once, the next
//  morning, as one batched line. Nothing else ever sees it.
//
//  Why (Boothby et al. 2018, the liking gap; Kumar & Epley 2018):
//  people leave a night thinking the others liked them less than they
//  did, and they underestimate what a small thanks means. This closes
//  that gap privately, one person at a time.
//
//  Hard rules this file exists to keep in one place:
//   * Never a count, rank, total or tally. There is no function here
//     (or on the server) that answers "how many". The only outputs
//     are a sentence for one recipient and a set for one sender.
//   * Only people who held a seat that night, inside the 24 h recap
//     window (`NightPhase.recap`, from `NightPhaseResolver`), can send.
//   * Nobody sees who did NOT get one. The host has no special view.
//
//  Server twins (migration 119):
//   * `public.glad_you_came` + its RLS (the send gate),
//   * `public.glad_push_deliver_at(settled_at, time_zone)` (the
//     delivery rule, `GladPushTime.deliverAt` here),
//   * `glad-push` edge function `composeGladCopy` (the sentence,
//     `GladYouCame.line` here; both pinned by the same table).
//
//  Foundation only, so the unit runner can test it.
//

import Foundation

/// One "glad you came" row as the client can read it: either one it
/// sent (`fromUser == me`) or one addressed to it (`toUser == me`).
/// RLS returns nothing else.
struct GladNote: Codable, Hashable {
    let eventId: UUID
    let fromUser: UUID
    let toUser: UUID
    let createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case fromUser = "from_user"
        case toUser = "to_user"
        case createdAt = "created_at"
    }

    init(eventId: UUID, fromUser: UUID, toUser: UUID, createdAt: Date? = nil) {
        self.eventId = eventId
        self.fromUser = fromUser
        self.toUser = toUser
        self.createdAt = createdAt
    }
}

enum GladYouCame {

    /// The one secondary caption on the recap.
    static let prompt = "Who were you glad to see?"

    /// Beyond this many senders the line names two and folds the rest.
    static let namedBeforeFolding = 3

    /// The batched sentence, exactly as the push and the recap say it:
    ///
    ///     1  "Connor was glad you came."
    ///     2  "Connor and Sam were glad you came."
    ///     3  "Connor, Sam and Jo were glad you came."
    ///     4+ "Connor, Sam and 2 others were glad you came."
    ///
    /// nil for no senders. Names are used in the order given (the
    /// server's send order), blanks are dropped.
    static func line(senderNames: [String]) -> String? {
        let names = senderNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        switch names.count {
        case 0:
            return nil
        case 1:
            return "\(names[0]) was glad you came."
        case 2...namedBeforeFolding:
            return "\(NameList.joined(names)) were glad you came."
        default:
            let rest = names.count - 2
            return "\(names[0]), \(names[1]) and \(rest) \(rest == 1 ? "other" : "others") were glad you came."
        }
    }

    /// Whether the viewer may send for this night: the night is in its
    /// recap window and the viewer held a seat. The phase is the one
    /// `NightPhaseResolver` computed; never re-derive it here.
    static func canSend(phase: NightPhase, viewerHadSeat: Bool) -> Bool {
        phase == .recap && viewerHadSeat
    }

    /// Whether the viewer held a seat that night.
    static func hadSeat(_ viewerId: UUID?, rsvps: [EventRSVP]) -> Bool {
        guard let viewerId else { return false }
        return rsvps.contains { $0.memberId == viewerId && $0.state == .claimed }
    }

    /// The night's table as the sheet lists it: everyone who held a
    /// seat, never the viewer, in the server's row order.
    static func table(rsvps: [EventRSVP], viewerId: UUID?) -> [EventRSVP] {
        var seen = Set<UUID>()
        return rsvps.filter {
            $0.state == .claimed && $0.memberId != viewerId && seen.insert($0.memberId).inserted
        }
    }

    /// The people the viewer has already told, for this night. Only the
    /// viewer's own rows count; anything else is ignored even if passed.
    static func alreadyTold(notes: [GladNote], eventId: UUID, viewerId: UUID?) -> Set<UUID> {
        guard let viewerId else { return [] }
        return Set(notes.filter { $0.eventId == eventId && $0.fromUser == viewerId }.map(\.toUser))
    }

    /// What a Send actually writes: the picked people, minus anyone
    /// already told and minus the viewer. Sending twice to the same
    /// person does nothing, so the second pick never leaves the phone.
    /// Ordered by the table so the write is deterministic.
    static func toSend(picked: Set<UUID>, alreadyTold: Set<UUID>, table: [EventRSVP], viewerId: UUID?) -> [UUID] {
        table.map(\.memberId).filter {
            picked.contains($0) && !alreadyTold.contains($0) && $0 != viewerId
        }
    }

    /// The recipient's line on the recap: the notes addressed to the
    /// viewer for this night, earliest first, named from the roster.
    /// A sender the roster cannot name is skipped, never "Someone".
    static func receivedLine(notes: [GladNote], eventId: UUID, viewerId: UUID?, names: [UUID: String]) -> String? {
        guard let viewerId else { return nil }
        let mine = notes
            .filter { $0.eventId == eventId && $0.toUser == viewerId && $0.fromUser != viewerId }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        var seen = Set<UUID>()
        let senders = mine.compactMap { note -> String? in
            guard seen.insert(note.fromUser).inserted else { return nil }
            return names[note.fromUser]
        }
        return line(senderNames: senders)
    }

    /// The sender's own grey confirmation: "Sent to Connor and Sam."
    static func sentLine(names: [String]) -> String? {
        let names = names.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return "Sent to \(NameList.joined(names))."
    }
}

// MARK: - Delivery time (server twin: public.glad_push_deliver_at)

/// When the batched push reaches a recipient, in the room's own zone:
///
///   * settled before 09:00            -> 09:00 that morning
///   * settled 09:00 to before 22:00   -> the next whole hour, unless
///                                        that is 22:00 or later
///   * otherwise (22:00 onwards)       -> 09:00 the next morning
///
/// So it is never sent 22:00 to 08:00. Settle at 13:00 -> 14:00,
/// 21:30 -> 09:00 next day, 23:30 -> 09:00 next day.
enum GladPushTime {
    static let morningHour = 9
    static let quietFromHour = 22

    static func deliverAt(settledAt: Date, timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let startOfDay = cal.startOfDay(for: settledAt)
        func at(_ hour: Int, daysAfter: Int) -> Date {
            let day = cal.date(byAdding: .day, value: daysAfter, to: startOfDay) ?? startOfDay
            return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        let morning = at(morningHour, daysAfter: 0)
        if settledAt < morning { return morning }
        let hour = cal.component(.hour, from: settledAt)
        let nextHour = hour + 1
        if nextHour < quietFromHour {
            return at(nextHour, daysAfter: 0)
        }
        return at(morningHour, daysAfter: 1)
    }

    /// True inside 22:00 to 08:00 local, the hours no push may land in.
    static func isQuiet(_ date: Date, timeZone: TimeZone) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: date)
        return hour >= quietFromHour || hour < 8
    }
}

// MARK: - Send with Undo

/// The sheet's Send, optimistic with Undo (no confirmation alert):
///
///     idle ──send──▶ undoing(ids) ──commitStarted──▶ committing(ids)
///       ▲               │                                  │
///       └────undo───────┘                  succeeded/failed ▼
///       ▲                                         sent(ids) / failed(ids)
///
/// Nothing leaves the phone while `.undoing`. The recap reads as sent
/// from the first tap; Undo is offered only until the write goes out.
enum GladSendPhase: Equatable {
    case idle
    case undoing([UUID])
    case committing([UUID])
    case sent([UUID])
    case failed([UUID])

    enum Event: Equatable {
        case send([UUID])
        case undo
        case commitStarted
        case succeeded
        case failed
    }

    /// The undo window, the same 5 s the settle uses.
    static let undoWindow: TimeInterval = 5

    func reduce(_ event: Event) -> GladSendPhase {
        switch (self, event) {
        case (.committing, .send):
            return self
        case (_, .send(let ids)):
            return ids.isEmpty ? self : .undoing(ids)
        case (.undoing, .undo):
            return .idle
        case (.undoing(let ids), .commitStarted):
            return .committing(ids)
        case (.committing(let ids), .succeeded):
            return .sent(ids)
        case (.committing(let ids), .failed):
            return .failed(ids)
        default:
            return self
        }
    }

    /// The ids the recap should already read as told (optimistic).
    var pendingOrSent: [UUID] {
        switch self {
        case .undoing(let ids), .committing(let ids), .sent(let ids): return ids
        case .idle, .failed: return []
        }
    }

    var canUndo: Bool {
        if case .undoing = self { return true }
        return false
    }
}
