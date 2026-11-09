//
//  SettlePhase.swift
//  GamesRoom
//
//  P2 (audit 03 C2, closes D5) — "Settle the night" with Undo, named.
//
//  Before this type the view held `pendingSettle: PendingSettle?` and a
//  separate `settleFailed: Bool`. `commitSettle` nilled `pendingSettle`
//  BEFORE the RPC, so the toast vanished while the write was still in
//  flight and a failure landed as a grey caption that needed a re-render
//  to appear.
//
//  The machine:
//
//      idle ──begin──▶ undoing(event) ──commitStarted──▶ committing(id)
//        ▲                 │                                    │
//        └───undo──────────┘                          committed │ failed
//        ▲                                                      ▼
//        └──────────── begin ◀── failed(id, message) ◀───── failed
//
//  Two rules the enum exists to make checkable:
//   1. The toast renders while `.undoing` AND while `.committing` — the
//      line says "Night settled." until the server has answered.
//   2. A failure is `.failed`, never `.idle`. `.idle` would mean "the
//      user has not settled", which is a different fact.
//
//  Undo is only offered while `.undoing`: after `.committing` the RPC is
//  already out and the night cannot be put back locally (audit 03 D6).
//

import Foundation

enum SettlePhase: Equatable {
    /// Nothing pending.
    case idle
    /// The 5 s Undo window. The cached night already reads settled;
    /// nothing has been sent.
    case undoing(event: Event)
    /// The settle RPC is in flight. The toast stays up.
    case committing(eventId: UUID)
    /// The settle RPC failed. The live card offers a retry.
    case failed(eventId: UUID, message: String)

    /// The one line the failure shows. Existing copy — no new string.
    static let failureMessage = "Couldn't settle. Try again."

    /// The toast is up for both pre-send and in-flight.
    var showsToast: Bool {
        switch self {
        case .undoing, .committing: return true
        case .idle, .failed: return false
        }
    }

    /// Non-nil only inside the Undo window.
    var undoingEvent: Event? {
        if case .undoing(let event) = self { return event }
        return nil
    }

    var isCommitting: Bool {
        if case .committing = self { return true }
        return false
    }

    /// The event whose settle failed, so a retry can be scoped to it.
    var failedEventId: UUID? {
        if case .failed(let eventId, _) = self { return eventId }
        return nil
    }

    var failedMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}

/// Everything that can move `SettlePhase`.
enum SettleEvent: Equatable {
    /// The host tapped "Settle the night".
    case begin(Event)
    /// The host tapped Undo inside the 5 s window.
    case undo
    /// The window elapsed and the RPC was started.
    case commitStarted(UUID)
    /// The RPC succeeded.
    case commitSucceeded(UUID)
    /// The RPC failed.
    case commitFailed(UUID, String)
}

extension SettlePhase {
    /// Pure transition table. The view cancels the previous window before
    /// it applies `.begin`, so a second settle replaces the first.
    func reduce(_ event: SettleEvent) -> SettlePhase {
        switch (self, event) {
        case (_, .begin(let newEvent)):
            // An in-flight RPC owns the phase: a second settle here would
            // send the same night twice.
            if case .committing = self { return self }
            return .undoing(event: newEvent)

        case (.undoing, .undo):
            return .idle

        case (.undoing(let current), .commitStarted(let eventId)) where current.id == eventId:
            return .committing(eventId: eventId)

        case (.committing(let current), .commitSucceeded(let eventId)) where current == eventId:
            return .idle

        case (.committing(let current), .commitFailed(let eventId, let message)) where current == eventId:
            return .failed(eventId: eventId, message: message)

        // Anything else is a late message from a window that no longer
        // owns the phase.
        default:
            return self
        }
    }
}
