//
//  DraftSaver.swift
//  GamesRoom
//
//  Task E — the settings write sequencer, moved out of the view.
//
//  V0.81 put the settings autosave in the view's lifecycle:
//
//    • a `.task(id: draft)` on the NavigationStack slept 600 ms and wrote,
//    • `.onDisappear` flushed a pending edit,
//    • a `writeTask` handle refired a write that was still on the wire when
//      the sheet went away.
//
//  Every one of those is a timing decision made by a view, and each one
//  had a failure mode the code had to patch around:
//
//    • the debounce had to live on the stack, because a `.task` attached to
//      the Form was cancelled by a pushed sub-sheet,
//    • the in-flight handle lived in the view, so an edit that landed while
//      a write was running needed a second write to catch up, and
//    • "is there an edit no write captured?" was a Bool the view kept in
//      sync with a counter it also had to keep in sync with a Task.
//
//  `DraftSaver` is that machinery in one actor. The view submits a draft
//  and flushes on the way out; the actor owns the pending draft, the
//  trailing debounce (a `Task.sleep` inside the actor, not a view
//  lifecycle task), and the serialisation.
//
//  The write itself is injected, so the saver knows nothing about rooms,
//  Supabase or SwiftUI — and the tests can drive it with a closure and a
//  ten-millisecond debounce.
//
//  The serialisation rule is not new: `WriteGate`
//  (`Models/WriteState.swift`) already says "one write at a time, exactly
//  one re-write", and it is table-tested. The saver composes that rule
//  rather than writing a second copy of it.
//
//  Foundation only — this file is in the test runner's slice, so it may
//  not import SwiftUI. `Combine` is enough for the one observable the
//  write reports through.
//

import Foundation
import Combine

// MARK: - RoomSettingsDraft

/// One snapshot of the room settings form.
///
/// The settings sheet's fields were a dozen `@State` properties and the
/// write read all of them at the moment it fired. A draft is those values
/// in one value type: the saver can hold the pending draft, keep the last
/// one it wrote, and hand the write closure exactly the values to persist.
///
/// It lives here rather than in `Models/` because the only draft the app
/// has today is the settings one, and the file that owns the write
/// sequencer is the file that owns its payload.
struct RoomSettingsDraft: Equatable, Sendable {
    /// `rooms.name`. Kept apart from the mascot name (V0.45).
    var name: String
    var mascotName: String
    var mascotPersonality: MascotPersonality
    var mascotPoliticalIdeology: MascotPoliticalIdeology
    var maxSeats: Int
    var memberInviteQuota: Int
    var joinStartingBonus: Int
    var socialNarrationEnabled: Bool
    var briefing48hEnabled: Bool
    var socialPreferencesEnabled: Bool
    var autoCloseHours: Int
    var seatDepositAmount: Int
    var seatDepositTrigger: SeatDepositTrigger
    var seatDepositGraceMinutes: Int
    /// V0.107 — the brought-by switch. It rides the settings write even
    /// though `update_room_settings` does not own the column (migration
    /// 103 gave it its own RPC).
    var showBroughtBy: Bool
    /// P1.5 — the host journal. Written after the settings write.
    var hostJournal: String
    /// W2.6 — the season subtitle. Written after the settings write.
    var seasonSubtitle: String
}

// MARK: - DraftWriteStatus

/// The write status of a settings surface, and the main-actor channel a
/// write reports through.
///
/// A class, not a `@State` in the view, for two reasons: the saver's write
/// closure has to hold it (a `@Sendable` closure may only capture
/// `Sendable` values, and a `@MainActor` class is one), and the write
/// closure runs off the main actor — the status must be updated on the
/// main actor, never from the wire.
///
/// The machine itself is `WriteState` (`Models/WriteState.swift`): this
/// type only routes the events to it, so there is still exactly one
/// definition of what "saving" and "saved" mean.
@MainActor
final class DraftWriteStatus: ObservableObject {
    /// idle · saving · saved(at:) · failed(settings, message).
    @Published private(set) var state: WriteState = .idle

    /// The user changed something; a previous outcome no longer describes
    /// the draft on the wire.
    func edited() {
        state = state.reduce(.edited)
    }

    /// A write started.
    func begin() {
        state = state.reduce(.begin(.settings))
    }

    /// A write landed.
    func succeed(at date: Date = Date()) {
        state = state.reduce(.succeed(at: date))
    }

    /// A write failed.
    func fail(_ message: String) {
        state = state.reduce(.fail(.settings, message))
    }
}

// MARK: - DraftSaver

/// Owns the sequencing of a draft the user is editing.
///
/// The contract:
///
///    • `submit(_:)` — the newest draft. Any pending debounce is cancelled
///      and one is scheduled for `debounce` from now, so N edits in a row
///      are one write.
///    • `flush()` — write the pending draft now, without the debounce,
///      after the write already on the wire has landed. Safe to call
///      repeatedly; a call with nothing pending does nothing.
///
/// The serial semantics are the ones the view used to own: at most one
/// write on the wire, and an edit that lands during a write queues
/// exactly one re-write (`WriteGate`).
actor DraftSaver<Payload: Sendable> {

    /// The write the saver performs. Throwing marks a failed write.
    typealias Write = @Sendable (Payload) async throws -> Void

    /// How long the saver waits after the last edit before it writes.
    /// 600 ms is the product decision V0.81 made ("an edit lands within
    /// about six hundred milliseconds"); it lives here now because the
    /// model owns the timing, not the view's lifecycle.
    static var defaultDebounce: Duration { .milliseconds(600) }

    private let debounce: Duration
    private let write: Write

    /// The newest draft no write has captured yet.
    private var pending: Payload?

    /// The draft the last write captured. `nil` until the first write
    /// lands.
    private var lastWritten: Payload?

    /// The draft whose write was refused. It is not pending — a write that
    /// failed did capture its draft — but it is worth one more attempt
    /// when the surface flushes.
    private var failedDraft: Payload?

    /// The scheduled trailing write. Cancelled and replaced by every
    /// submit.
    private var debounceTask: Task<Void, Never>?

    /// The write on the wire right now, if any.
    private var writeTask: Task<Void, Never>?

    /// One write at a time; exactly one re-write queued.
    private var gate = WriteGate()

    init(debounce: Duration = DraftSaver.defaultDebounce, write: @escaping Write) {
        self.debounce = debounce
        self.write = write
    }

    /// Hand the saver the newest draft.
    ///
    /// Coalescing: the pending debounce is cancelled and a fresh one is
    /// scheduled, so a burst of edits is one write. The draft itself is
    /// kept until a write captures it.
    func submit(_ draft: Payload) {
        pending = draft
        debounceTask?.cancel()
        let delay = debounce
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancelled: a newer submit took over the debounce.
                return
            }
            guard !Task.isCancelled else { return }
            await self?.fire()
        }
    }

    /// Write the pending draft now.
    ///
    /// Waits for the write already on the wire — an edit that landed
    /// during it is written by that write's own re-write — and then writes
    /// whatever is pending without the debounce. An edit that lands while
    /// the flush writes is written too: the loop keeps going until nothing
    /// is pending.
    ///
    /// A write that was refused is tried once more (the old dismiss-time
    /// retry). That retry is deliberately not looped: a server that keeps
    /// refusing must not turn a dismiss into a retry storm.
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        while true {
            await drain()
            guard pending != nil else { break }
            fire()
        }
        if failedDraft != nil {
            pending = failedDraft
            failedDraft = nil
            fire()
            await drain()
        }
    }

    /// The draft the last write captured, if a write has landed.
    func lastWrittenDraft() -> Payload? {
        lastWritten
    }

    // MARK: - Internals

    /// Start a write, if the gate allows one.
    ///
    /// The gate queues the re-write when a write is already on the wire,
    /// so the pending draft is left where it is and the running write
    /// picks it up when it finishes.
    private func fire() {
        guard let draft = pending else { return }
        guard gate.begin() else { return }
        pending = nil
        startWrite(draft)
    }

    /// Put the draft on the wire.
    ///
    /// The task owns the write and the report of its outcome: by the time
    /// `task.value` returns, the write has finished AND the saver has
    /// already re-armed itself. That is what lets `flush()` await the
    /// write and then trust that nothing is left in flight.
    private func startWrite(_ draft: Payload) {
        let task = Task { [weak self, write] in
            var failed = false
            do {
                try await write(draft)
            } catch {
                failed = true
            }
            await self?.writeFinished(draft: draft, failed: failed)
        }
        writeTask = task
    }

    /// The write on the wire finished.
    ///
    /// A refused write keeps its draft in `failedDraft`: the next flush
    /// tries it once more, which is what the dismiss-time retry used to
    /// do. It is not put back in `pending` — nothing retries it on its
    /// own, and a refused write must not turn a dismiss into a retry
    /// storm.
    ///
    /// A landed write records the draft and hands over the one re-write an
    /// edit during the write is owed. That re-write carries the newer
    /// draft, so it also retires the refused one.
    private func writeFinished(draft: Payload, failed: Bool) {
        writeTask = nil
        if failed {
            failedDraft = draft
        } else {
            lastWritten = draft
            failedDraft = nil
        }
        guard gate.end() else { return }
        guard let next = pending else { return }
        pending = nil
        failedDraft = nil
        guard gate.begin() else { return }
        startWrite(next)
    }

    /// Wait for the write on the wire (and any re-write it queued) to
    /// settle.
    private func drain() async {
        while let task = writeTask {
            await task.value
        }
    }
}
