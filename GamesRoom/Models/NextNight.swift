//
//  NextNight.swift
//  GamesRoom
//
//  1.2.5 Task 1 — book the next night at settle, and end the recap on
//  a person.
//
//  Two reasons this exists (brain page 2026-11-10 room dynamics):
//   - Friendship takes hours together (Hall 2019), and the hours only
//     add up if the next night exists. The best moment to book it is
//     while everyone is still at the table, so the settled night offers
//     "Same time next Tuesday?" as the host's one primary action.
//   - People remember a night by its best moment and its ending
//     (peak-end rule). The recap now opens on Tonight's Star and closes
//     on the next night, with the chip results between them.
//
//  Three pure pieces, Foundation only, no clock reads:
//
//    NextNightOffer      what "Same time next Tuesday?" would book, or
//                        nil when it must not be offered.
//    NextNightBooking    the optimistic one-tap booking with Undo
//                        (same shape as `SettlePhase`).
//    RecapClosing /      the recap's last line and the order of the
//    RecapLayout         recap's sections.
//
//  Server twin: `add_event` and the one-upcoming-night trigger
//  (`one_upcoming_night`, migration 115). This file never decides
//  whether a night is upcoming on its own: it asks `NightPhaseResolver`.
//

import Foundation

enum NightPackOrder {
    static func casinoFirst(_ packSlugs: [String]) -> [String] {
        [CasinoPack.slug] + packSlugs.filter { $0 != CasinoPack.slug }
    }
}

// MARK: - The offer

/// "Same time next Tuesday?": the settled night's start time plus seven
/// days in the room's time zone, the same packs, the default name.
struct NextNightOffer: Equatable {
    /// When the next night starts.
    let playedAt: Date
    /// The default night name for that time ("tue 17 nov · 7pm session").
    let name: String
    /// The settled night's packs, chips first.
    let packSlugs: [String]
    /// The weekday in the room's time zone ("Tuesday").
    let weekday: String
    /// The room's time zone, kept so every line about this night reads
    /// the same clock.
    let timeZone: TimeZone

    /// The host's one primary action on the settled night.
    var prompt: String { "Same time next \(weekday)?" }

    /// The grey caption under the prompt. Opens `AddEventSheet`.
    static let pickAnotherTime = "Pick another time"

    /// The settled night's start time plus seven days, wall clock kept
    /// in `timeZone`: a 7pm night is still 7pm across a DST change.
    static func sameTimeNextWeek(after playedAt: Date, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 7, to: playedAt)
    }

    /// The offer for a settled night, or nil when it must not show:
    ///
    /// - members never see it (the host books nights);
    /// - a future night is already booked (one upcoming night per room,
    ///   `one_upcoming_night`);
    /// - the settle is still inside its Undo window or in flight (the
    ///   night is not settled yet, and one toast at a time);
    /// - same time next week has already gone (an old night settled
    ///   late): the host plans the next night instead.
    static func offer(
        settled: Event,
        isHost: Bool,
        hasFutureNight: Bool,
        settleInFlight: Bool,
        now: Date,
        timeZone: TimeZone
    ) -> NextNightOffer? {
        guard isHost, !hasFutureNight, !settleInFlight else { return nil }
        guard let next = sameTimeNextWeek(after: settled.playedAt, timeZone: timeZone),
              next > now else { return nil }
        // Only games the catalog still knows: a retired pack on an old
        // night must not make the one-tap booking fail.
        let packs = NightPackOrder.casinoFirst(
            settled.packSlugs.filter { PackRegistry.shared.isRegistered(slug: $0) }
        )
        return NextNightOffer(
            playedAt: next,
            name: EventDefaultName.name(for: next, timeZone: timeZone),
            packSlugs: packs,
            weekday: weekdayName(for: next, timeZone: timeZone),
            timeZone: timeZone
        )
    }

    /// True when the room already has a night ahead of the settled one:
    /// the active night is a different night that is upcoming, live or
    /// stranded. The phase comes from `NightPhaseResolver`.
    static func hasFutureNight(
        active: Event?,
        settledId: UUID,
        now: Date,
        autoCloseHours: Int = NightPhaseResolver.defaultAutoCloseHours
    ) -> Bool {
        guard let active, active.id != settledId else { return false }
        switch NightPhaseResolver.phase(for: active, autoCloseHours: autoCloseHours, now: now) {
        case .upcoming, .live, .stranded: return true
        case .none, .recap, .past, .cancelled: return false
        }
    }

    /// "Tuesday", in the room's time zone, in English whatever the
    /// device language (the rest of the copy is English too).
    static func weekdayName(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    /// "Next: Tue 17 Nov, 7pm" — the recap's closing line.
    static func closingLine(for date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        return "Next: \(formatter.string(from: date)), \(EventDefaultName.clock(for: date, timeZone: timeZone))"
    }
}

// MARK: - The booking (optimistic, with Undo)

/// The one-tap booking. Same shape as `SettlePhase`: nothing is sent for
/// the 5 s Undo window, then the create goes out and the toast stays up
/// until the server answers.
///
///     idle ──begin──▶ undoing(offer) ──commitStarted──▶ committing(offer)
///       ▲                 │                                  │
///       └──────undo───────┘                 succeeded / taken │ failed
///       ▲                                                    ▼
///       └──────────────── idle ◀──────── failed(offer, message)
///
/// Sending nothing during the window also means members get no
/// new-night notice for a night the host takes back.
enum NextNightBooking: Equatable {
    case idle
    /// The 5 s Undo window. The recap already reads "Next: ...".
    case undoing(NextNightOffer)
    /// `add_event` is in flight. Undo is gone.
    case committing(NextNightOffer)
    /// `add_event` failed. The prompt comes back with the reason.
    case failed(NextNightOffer, message: String)

    /// The one line a failed booking shows. The prompt above it is the
    /// retry.
    static let failureMessage = "Couldn't book it. Try again."

    /// The toast's line while the booking is pending.
    static let toastLine = "Next night booked."

    /// The night the recap should already show as booked.
    var pendingOffer: NextNightOffer? {
        switch self {
        case .undoing(let offer), .committing(let offer): return offer
        case .idle, .failed: return nil
        }
    }

    var showsToast: Bool { pendingOffer != nil }

    /// Non-nil only inside the Undo window.
    var undoingOffer: NextNightOffer? {
        if case .undoing(let offer) = self { return offer }
        return nil
    }

    var isCommitting: Bool {
        if case .committing = self { return true }
        return false
    }

    var failedMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    func reduce(_ event: NextNightBookingEvent) -> NextNightBooking {
        switch (self, event) {
        case (_, .begin(let offer)):
            // An in-flight create owns the phase: a second tap here would
            // book the night twice.
            if case .committing = self { return self }
            return .undoing(offer)
        case (.undoing, .undo):
            return .idle
        case (.undoing(let offer), .commitStarted):
            return .committing(offer)
        case (.committing, .commitSucceeded):
            return .idle
        case (.committing, .alreadyBooked):
            // `one_upcoming_night`: a night is on the books after all.
            // The page reloads and shows it; there is nothing to retry.
            return .idle
        case (.committing(let offer), .commitFailed(let message)):
            return .failed(offer, message: message)
        default:
            return self
        }
    }
}

/// Everything that can move `NextNightBooking`.
enum NextNightBookingEvent: Equatable {
    /// The host tapped "Same time next Tuesday?".
    case begin(NextNightOffer)
    /// Undo inside the 5 s window.
    case undo
    /// The window passed and `add_event` was sent.
    case commitStarted
    /// The night is booked.
    case commitSucceeded
    /// The server refused with `one_upcoming_night`.
    case alreadyBooked
    /// Any other failure.
    case commitFailed(String)
}

// MARK: - The recap's closing line

/// How the recap ends.
enum RecapClosing: Equatable {
    /// "Next: Tue 17 Nov, 7pm". `claim` adds "Claim your seat" (a member
    /// who has not answered yet).
    case nextNight(line: String, claim: Bool)
    /// The host's "Same time next Tuesday?" with "Pick another time"
    /// under it.
    case bookSameTime(NextNightOffer)
    /// The host's "Plan the next night" (no quick booking to offer).
    case planNextNight
    /// Members with nothing booked: the recap simply ends.
    case none

    /// The member's quiet line under the next night.
    static let claimYourSeat = "Claim your seat"

    /// The host's existing action when nothing is booked.
    static let planNextNightTitle = "Plan the next night"

    /// - Parameters:
    ///   - isHost: the viewer hosts the room.
    ///   - nextNightAt: the booked next night's start, or the pending
    ///     booking's (optimistic). nil when nothing is booked.
    ///   - nextNightIsReal: the next night exists on the server (so a
    ///     seat can be claimed on it), not just a pending booking.
    ///   - myRSVPOnNext: the viewer's answer on that night.
    ///   - offer: "Same time next ..." (`NextNightOffer.offer`).
    ///   - canPlan: the night plan's primary is `.planNextNight`.
    static func resolve(
        isHost: Bool,
        nextNightAt: Date?,
        nextNightIsReal: Bool,
        myRSVPOnNext: MemberRSVPState?,
        offer: NextNightOffer?,
        canPlan: Bool,
        timeZone: TimeZone
    ) -> RecapClosing {
        if let nextNightAt {
            let claim = !isHost && nextNightIsReal && myRSVPOnNext == .unclaimed
            return .nextNight(
                line: NextNightOffer.closingLine(for: nextNightAt, timeZone: timeZone),
                claim: claim
            )
        }
        guard isHost else { return .none }
        if let offer { return .bookSameTime(offer) }
        return canPlan ? .planNextNight : .none
    }
}

// MARK: - The recap's order

/// One block of the recap card, below its header.
enum RecapSection: Equatable {
    /// Tonight's Star (host pick, or the chip-swing fallback).
    case star
    /// The host's "Make a call", when there is no star yet.
    case makeACall
    /// How the night went: the cash-out results.
    case results
    /// The member's one-line drop (next-morning window).
    case memberNote
    /// The recap's last line: `RecapClosing`.
    case closing
    /// "Glad you came": `RecapLayout.placingGlad(in:)` puts it in.
    case glad
}

/// Where Tonight's Star comes from.
enum RecapStar: Equatable {
    case none
    /// The host picked tonight's star.
    case hostPick
    /// 067's fallback: the biggest chip swing. It is a result, so it sits
    /// with the results rather than leading the recap.
    case chipSwing
}

enum RecapLayout {
    /// The recap's order (peak-end): the host's star first, the chip
    /// results as they are, and the next night last.
    static func sections(
        star: RecapStar,
        canMakeACall: Bool,
        hasResults: Bool,
        showsMemberNote: Bool,
        closing: RecapClosing
    ) -> [RecapSection] {
        var sections: [RecapSection] = []
        switch star {
        case .hostPick: sections.append(.star)
        case .none: if canMakeACall { sections.append(.makeACall) }
        case .chipSwing: break
        }
        if hasResults { sections.append(.results) }
        if star == .chipSwing { sections.append(.star) }
        if showsMemberNote { sections.append(.memberNote) }
        if closing != .none { sections.append(.closing) }
        return sections
    }

    /// 1.2.5 Task 4: "Glad you came" goes directly under Tonight's Star.
    /// With no star it takes the star's place (under "Make a call" when
    /// the host has one), so it always comes before the closing line.
    static func placingGlad(in sections: [RecapSection]) -> [RecapSection] {
        var placed = sections
        let anchor = placed.firstIndex(of: .star) ?? placed.firstIndex(of: .makeACall)
        placed.insert(.glad, at: anchor.map { $0 + 1 } ?? 0)
        return placed
    }

    /// The star's source as the recap reads it.
    static func star(for card: TonightStarCard?) -> RecapStar {
        guard let card else { return .none }
        return card.source == "host_pick" ? .hostPick : .chipSwing
    }
}
