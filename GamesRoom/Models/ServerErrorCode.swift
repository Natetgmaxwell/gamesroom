//
//  ServerErrorCode.swift
//  GamesRoom
//
//  Lane P (state machines) — the server's refusal tokens, named once.
//
//  Migration 113 and 114 raise `P0001` with a bare token in the message
//  (`night_full`, `night_started`). The app matched one of them by
//  string-searching the localized description in RoomService and let the
//  rest fall through as raw Postgres text. One enum, one matcher, one
//  line of copy each.
//
//  The match stays a substring search on purpose: PostgREST wraps the
//  message, so the token arrives inside a longer string. Matching is
//  case-insensitive for the same reason.
//

import Foundation

/// A refusal the app knows how to explain.
enum ServerErrorCode: String, CaseIterable {
    /// Every chair is taken (migration 113).
    case nightFull = "night_full"
    /// The night has started, so the seat can no longer be released
    /// (migration 114's precedent, applied to the seat flows).
    case nightStarted = "night_started"
    /// The host kept this member's deposit; the member cannot re-claim
    /// the seat.
    case forfeitedSeat = "forfeited_seat"
    /// Arrivals are not open yet.
    case tooEarly = "too_early"
    /// The night was called off.
    case cancelled = "cancelled"

    /// The code behind an error, or `nil` when the server said something
    /// the app has no copy for.
    static func code(in error: Error) -> ServerErrorCode? {
        let nsError = error as NSError
        let text = "\(nsError.localizedDescription) \(String(describing: error))".lowercased()
        return allCases.first { text.contains($0.rawValue) }
    }

    /// The one line the room page shows. Plain, no jargon, no blame.
    var message: String {
        switch self {
        case .nightFull:
            return "All the seats are taken."
        case .nightStarted:
            return "The night has started, so your seat stays."
        case .forfeitedSeat:
            return "Your deposit was kept for this night."
        case .tooEarly:
            return "Arrivals aren't open yet."
        case .cancelled:
            return "This night was called off."
        }
    }
}
