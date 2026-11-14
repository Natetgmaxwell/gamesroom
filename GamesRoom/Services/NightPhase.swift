//
//  NightPhase.swift
//  GamesRoom
//
//  Lane P (state machines) — the night phase, named once.
//
//  Foundation only. No I/O, no clock: the caller hands in every
//  fact the phase depends on and gets one answer back.
//
//  This is the Swift mirror of migration 120's `public.night_phase(
//  p_played_at, p_settled_at, p_auto_close_hours, p_now)`. The SQL is
//  canonical; the two bodies must answer identically for every input,
//  and `TestsP1` pins the table row by row on both sides.
//
//  Two rules that were unknowable before this type existed:
//
//  1. `live` ends at `played_at + auto_close_hours`, settled or not.
//     It is a promise about the app's attention, not about the table.
//     After that window a night nobody settled has ENDED — the night
//     ends itself, so it reads `recap` (or `past`), never `live` and
//     never `stranded`. The old inline `playedAt <= now && settledAt
//     == nil` predicate said "live forever", and the server disagreed.
//
//  1a. The night ends itself because the end is known at booking time:
//      `played_at + auto_close_hours`. So the phase is derived from the
//      EFFECTIVE settle — the host's own stamp when there is one,
//      otherwise the night's true end once the clock has reached it —
//      and no writer has to run for the night to have ended. `stranded`
//      stays in the vocabulary as an unreachable safety fallback, on
//      both sides.
//
//  2. `recap` is a property of the night, not of the room's active
//     slot. It coexists with `upcoming`: a night settled inside the
//     24-hour window renders as its own section above next week's
//     card. Any consumer that returns one night per room is wrong by
//     construction.
//
//  `cancelled` is part of the vocabulary (a cancelled night is a real
//  thing a host can do) but `phase(_:)` never returns it: `cancel_event`
//  deletes the row, so a cancelled night is absent, not a fact to
//  classify. It exists so a server row that carries a cancel marker
//  has somewhere to land, and so no consumer invents its own name.
//

import Foundation

/// Where one night sits in its lifecycle.
enum NightPhase: String, Equatable, Codable, CaseIterable {
    /// No night at all.
    case none
    /// Scheduled, not started.
    case upcoming
    /// Started, inside the auto-close window, not settled.
    case live
    /// Started, the window has gone, nobody settled it. UNREACHABLE
    /// BY DESIGN since migration 120: the night ends itself, so an
    /// expired night reads `recap` (or `past`) without any writer
    /// having run. The case stays in the vocabulary — the SQL keeps it
    /// as its final fallback and old rows can carry it — but the
    /// resolver no longer produces it.
    case stranded
    /// Settled inside the 24-hour recap window.
    case recap
    /// Settled, and the recap window has closed.
    case past
    /// Called off before it started. `phase(_:)` cannot return this
    /// (the row is deleted); it exists for rows that carry the marker.
    case cancelled
}

/// Everything the phase depends on, nothing else.
struct NightFacts: Equatable {
    /// When the night starts. `nil` when there is no night.
    var playedAt: Date?
    /// When the host settled it, if they have.
    var settledAt: Date?
    /// The room's `auto_close_hours` (default 8).
    var autoCloseHours: Int
    /// The clock, passed in so the rule stays pure.
    var now: Date

    init(playedAt: Date?, settledAt: Date? = nil, autoCloseHours: Int = NightPhaseResolver.defaultAutoCloseHours, now: Date) {
        self.playedAt = playedAt
        self.settledAt = settledAt
        self.autoCloseHours = autoCloseHours
        self.now = now
    }
}

/// The one derivation of "what phase is this night in".
enum NightPhaseResolver {
    /// How long a settled night still counts as the night that just
    /// happened. Keep 86_400: do not unify with the 12-hour member-note
    /// window or the 7-day season-awards window — different questions.
    static let recapWindow: TimeInterval = 86_400

    /// `rooms.auto_close_hours` default, the same default migration 081
    /// and 107 use.
    static let defaultAutoCloseHours = 8

    /// Mirrors `public.night_phase(...)` branch for branch:
    ///
    ///     played_at is null                                              -> none
    ///     played_at > now                                               -> upcoming
    ///     no effective settle and now < played_at + auto_close_hours    -> live
    ///     effective settle > now - 24h                                  -> recap
    ///     effective settle is not null                                  -> past
    ///     otherwise                                                      -> stranded
    ///
    /// The EFFECTIVE settle is the host's own stamp when there is one,
    /// and otherwise the night's true end — `played_at +
    /// auto_close_hours` — once the clock has reached it. The end of a
    /// night is known the moment the night is booked, so the night
    /// ends itself: no writer has to stamp the column for the night to
    /// have ended, and a night nobody settled reads `recap` (or
    /// `past`) the moment its window closes.
    ///
    /// `live` additionally requires NO effective settle: a night the
    /// host settled early has ended, so it reads `recap`, never `live`.
    ///
    /// The comparisons are strict, exactly like the SQL: a night
    /// settled exactly 24 hours ago is `past`, a night starting exactly
    /// now is `live`, and a night whose window ends exactly now is
    /// `recap` — its effective settle lands exactly on `now`.
    ///
    /// `stranded` is the last branch and is unreachable: a nil
    /// effective settle means the clock has not reached the window end,
    /// so the `live` branch took the row. It stays in the vocabulary
    /// because the SQL keeps it as its own fallback.
    static func phase(_ facts: NightFacts) -> NightPhase {
        guard let playedAt = facts.playedAt else { return .none }
        if playedAt > facts.now { return .upcoming }
        let windowEnd = playedAt.addingTimeInterval(TimeInterval(facts.autoCloseHours) * 3_600)
        // The effective settle: the host's own stamp when there is
        // one, else the night's true end once `now` has reached it.
        let effectiveSettledAt = facts.settledAt ?? (facts.now >= windowEnd ? windowEnd : nil)
        if let settledAt = effectiveSettledAt {
            return settledAt > facts.now.addingTimeInterval(-recapWindow) ? .recap : .past
        }
        // No effective settle: the clock has not reached the window
        // end, so the night is still live.
        return facts.now < windowEnd ? .live : .stranded
    }

    /// Convenience for the call sites that already hold an event.
    static func phase(
        for event: Event?,
        autoCloseHours: Int = defaultAutoCloseHours,
        now: Date = Date()
    ) -> NightPhase {
        guard let event else { return .none }
        return phase(NightFacts(
            playedAt: event.playedAt,
            settledAt: event.settledAt,
            autoCloseHours: autoCloseHours,
            now: now
        ))
    }
}
