//
//  V0State.swift
//  GamesRoom
//
//  Lane P (state machines) — which slot the room page shows.
//
//  This used to be a `private var state` on RoomDetailView that
//  re-derived "is the night live", "is it settled" and "was it
//  settled inside 24 hours" from the event row. Every one of those
//  questions now has one answer, `NightPhase`, and this file turns
//  that answer into the slot. Nothing here reads a clock: the caller
//  resolves the phase and hands it in.
//
//  Three bugs this closes (audit 03 D2, D3, D4):
//
//   - a night settled more than 24 hours ago used to fall through to
//     the live card, so a finished night rendered as "The night has
//     started" with Withdraw and Score buttons. `.past` is now
//     `.readStandings`.
//   - "has played" had three definitions. `hasWithdrawn` is the one
//     `NightInput` already used (working hand, casino withdrawal or a
//     scan), so the card and the plan cannot disagree on the same
//     frame.
//   - a stranded night (started, window gone, never settled) used to
//     be unrepresentable; it is now `.inPlay`, the same card a live
//     night gets, and its settle action comes from `NightPlan`.
//

import Foundation

/// The slot the room page renders for the room's active night.
enum V0State: Equatable {
    /// Nothing loaded yet.
    case loading
    /// The night just settled: the ceremonial card.
    case justSettled(Event)
    /// Live, and the viewer has not played yet — the play-just-started
    /// moment. Distinct from `.inPlay` so the witness hero can carry
    /// the started-time caption on its own.
    case tonightEvent(Event)
    /// Live and the viewer has played, or the night is stranded and
    /// waiting on the host to settle it.
    case inPlay(Event)
    /// Scheduled, viewer has not answered.
    case upcoming(Event)
    /// Scheduled, viewer claimed a seat.
    case claimed(Event)
    /// Scheduled, viewer declined.
    case declined(Event)
    /// No night to show: the standings slot.
    case readStandings

    /// The slot for one viewer. Pure: every input is a fact the caller
    /// already holds.
    ///
    /// - Parameters:
    ///   - hasLoaded: the first refresh has resolved. Before that the
    ///     page shows `.loading`, because "no data yet" and "no night"
    ///     render differently.
    ///   - phase: the night's phase, from `NightPhaseResolver`.
    ///   - activeEvent: the room's active night, if any.
    ///   - myRSVP: the viewer's RSVP for that night.
    ///   - hasWithdrawn: the viewer has played — working hand, casino
    ///     withdrawal or a scan. The same definition `NightInput` uses.
    static func resolve(
        hasLoaded: Bool,
        phase: NightPhase,
        activeEvent: Event?,
        myRSVP: MemberRSVPState,
        hasWithdrawn: Bool
    ) -> V0State {
        guard hasLoaded else { return .loading }
        guard let event = activeEvent, phase != .none else { return .readStandings }
        switch phase {
        case .recap:
            return .justSettled(event)
        case .past, .cancelled:
            // A finished night keeps its standings, never its buttons.
            return .readStandings
        case .live:
            return hasWithdrawn ? .inPlay(event) : .tonightEvent(event)
        case .stranded:
            // The night ran past its auto-close window unresolved. It
            // is still the page's subject — the host has to settle it —
            // so it takes the in-play card rather than vanishing.
            return .inPlay(event)
        case .upcoming:
            switch myRSVP {
            case .unclaimed: return .upcoming(event)
            case .claimed:   return .claimed(event)
            case .declined:  return .declined(event)
            }
        case .none:
            return .readStandings
        }
    }
}
