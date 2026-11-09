//
//  WriteState.swift
//  GamesRoom
//
//  One write machine, shared by every surface that saves on the user's
//  behalf. Promoted from `RoomSettingsSheet.SaveState` (V0.81), which was
//  already the right shape — it only lacked a name for *what* failed, so
//  a share-code error landed in the settings status row, a section away
//  from the button that caused it.
//
//  Three pieces, all Foundation-only so the harness can table-test them:
//
//    • `Operation`  — which write this is. The tag that lets a surface put
//      a failure next to its own control instead of in a shared row.
//    • `WriteState` — idle · saving · saved(at:) · failed(Operation, String).
//      `reduce(_:)` is the transition table; it is the only way the cases
//      change inside a view.
//    • `WriteGate`  — the `isWriting` / `refireAfterWrite` serializer from
//      RoomSettingsSheet, wrapped as a value type so the same behaviour is
//      testable and both sheets can use it.
//
//  Deliberately not a generic `LoadingState<T>`: every call site needs a
//  different failure surface (alert, footer, grey caption, toast), and one
//  shared `WriteState` with an `Operation` tag is the most abstraction this
//  app tolerates.
//

import Foundation

// MARK: - Operation

/// Which write a `WriteState` belongs to. One case per owner that can fail
/// on its own; the tag is what routes the failure to the right control.
enum Operation: String, CaseIterable, Equatable {
    case settings
    case displayName
    case shareCode
    case declareSeason
    case deleteRoom

    var id: String { rawValue }
}

// MARK: - WriteState

/// The write machine for one surface: nothing in flight, a write in flight,
/// the write that last landed, or the write that last failed.
enum WriteState: Equatable {
    case idle
    case saving
    case saved(at: Date)
    case failed(Operation, String)

    /// A write is in flight. Drives spinners and disables the control.
    var isBusy: Bool {
        if case .saving = self { return true }
        return false
    }

    /// The operation the last failure belonged to, if the last outcome was
    /// a failure. `nil` for every other state — `saved` carries no tag
    /// because a surface only ever reports a save it owns.
    var failedOperation: Operation? {
        if case .failed(let operation, _) = self { return operation }
        return nil
    }

    /// The message for the last failure, or nil.
    var failureMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }

    /// The message for the last failure *of this operation*, or nil. A
    /// surface that shares one `WriteState` across several controls uses
    /// this to render only its own failure.
    func failure(for operation: Operation) -> String? {
        if case .failed(let owner, let message) = self, owner == operation {
            return message
        }
        return nil
    }
}

// MARK: - Transitions

/// The events that move a `WriteState`. Kept as its own type so the table
/// test can enumerate the rows.
enum WriteEvent: Equatable {
    /// The user changed something that will be written later. Clears a
    /// "Saved" or a failure; leaves an in-flight write alone.
    case edited
    /// The write started.
    case begin(Operation)
    /// The write landed.
    case succeed(at: Date)
    /// The write failed.
    case fail(Operation, String)
}

extension WriteState {
    /// The whole machine. Every state change in a consuming view goes
    /// through this so the table test pins the behaviour, not the views.
    func reduce(_ event: WriteEvent) -> WriteState {
        switch (self, event) {
        case (_, .begin):
            return .saving
        case (_, .succeed(let at)):
            return .saved(at: at)
        case (_, .fail(let operation, let message)):
            return .failed(operation, message)
        case (.saving, .edited):
            // An edit during an in-flight write must not hide the spinner;
            // the gate queues a refire and the write stays the current one.
            return .saving
        case (_, .edited):
            // D8 — "Saved" and a stale failure both clear the moment the
            // next edit lands, so a footer can never keep saying "Saved"
            // after a later failed write.
            return .idle
        }
    }
}

// MARK: - WriteGate

/// The `isWriting` / `refireAfterWrite` serializer, as a value type.
///
/// One write at a time; an edit that lands while a write is in flight
/// queues exactly one refire instead of running concurrently. Wrapped, not
/// redesigned: the call sites keep their shape —
///
///     guard gate.begin() else { return }
///     defer { if gate.end() { Task { await write() } } }
struct WriteGate: Equatable {
    private(set) var isWriting = false
    private(set) var refire = false

    /// True when the caller may run the write now. False when one is
    /// already in flight — the caller has queued a single refire and must
    /// not start a second write.
    mutating func begin() -> Bool {
        guard !isWriting else {
            refire = true
            return false
        }
        isWriting = true
        return true
    }

    /// Call when the write finishes. True means an edit landed while it was
    /// in flight: the caller must run the write again with the newest
    /// values.
    mutating func end() -> Bool {
        isWriting = false
        guard refire else { return false }
        refire = false
        return true
    }
}

// MARK: - SubmitOnce

/// The claimed-card field writes on Return *and* on focus loss, so one
/// Return could persist the same value twice. This is the guard: the first
/// claim of a value inside the window wins, the echo loses.
struct SubmitOnce: Equatable {
    /// A second submit of the same value inside this window is an echo of
    /// the same gesture (Return resigns focus, focus loss submits again).
    static let echoWindow: TimeInterval = 1.5

    private(set) var lastValue: String?
    private(set) var lastAt: Date?
    var window: TimeInterval = SubmitOnce.echoWindow

    /// True when this value should be sent. False when it is the echo of
    /// the value the same gesture already sent.
    mutating func claim(_ value: String, now: Date) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lastValue, let lastAt,
           lastValue == trimmed,
           now.timeIntervalSince(lastAt) < window {
            return false
        }
        lastValue = trimmed
        lastAt = now
        return true
    }
}
