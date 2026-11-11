# STATE cc-cc-cde
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/client-local-state  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/client-local-state
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: E2
- [x] C1 LoadPhase enum + RoomService phase tracking
- [x] C2 RoomDetailView reads phase; delete hasLoadedInitialData
- [x] C3 phase table tests
- [x] D1 claim emphasis derived from rsvps data (no stored bool/timer)
- [x] D2 declarative stagger (delete appearedIndices + staggerAppear)
- [x] E1 DraftSaver actor
- [ ] E2 RoomSettingsSheet hands off to saver
- [ ] E3 DraftSaver tests
- [ ] E4 REPORT-task-CDE.md

## Notes for later steps
- D1 kept the confetti celebration but re-sourced its trigger. The old code
  needed a stored flag because it had to *time* the burst (500 ms window);
  the burst component itself still owns its one-shot timing via its own
  `burst` state + `onAppear`. The grid now asks the roster ("is my seat
  claimed?") and the cell shows the burst when that answer flips to true.
  NOTE FOR E4: the burst now shows for as long as the seat is claimed, not
  for 500 ms — the component's internal fade-out covers the celebration.
  Report this as the one behaviour difference.
- D1 removed the `.onChange(of: rsvps)` block in `SeatGridRow` entirely and
  replaced the inline `.spring(...)` with `Theme.Motion.popIn` (the grid
  already had `reduceMotion` gating).
- D2 deleted the `appearedIndices: Set<Int>` @State and `staggerAppear(idx:)`
  (the `Task.sleep(idx * 50ms)` per row). Two anchors, both gone:
  `grep -n "appearedIndices\|staggerAppear" GamesRoom/Views/RoomDetailView.swift`
  → no hits.
- D2 replacement: the awards list container is now ALWAYS rendered (the
  empty-state Text moved inside it), so it is already in the hierarchy
  when the async awards land; it owns
  `.animation(reduceMotion ? nil : Theme.Motion.fade, value: sortedAwards)`
  (group fade on insertion). Each row is wrapped in the new private
  `StaggeredAwardRow`, which puts the per-row delay in the row's
  *transaction* (`Theme.Motion.fade.delay(Double(index) * 0.05)`) and the
  row's content owns `.transition(.opacity.combined(with: .offset(y: 6)))`
  — same 6pt distance the old stagger used, no scale, no spring.
- D2 NOTES FOR E4 (behaviour differences, all deliberate):
  1. The entrance now fires when the award list CHANGES (the awards land
     from the async load), not on the card's first paint. With a warm cache
     — awards already in memory when the card first appears — the rows are
     simply present. A mount-time entrance cannot be expressed without
     stored appearance state, which is what D2 removes.
  2. The row's transaction also governs the drowning badge's "you've opted
     in" footnote, which now fades with that row's delay instead of
     appearing instantly. (DrowningBadge.swift is outside the allowed file
     list, so the footnote could not be opted out of the row's scope.)
  3. The dividers between rows still appear instantly (no transition) —
     unchanged from the old behaviour.

## E1 — what landed (read this before E2)

**New file** `GamesRoom/Services/DraftSaver.swift` (added to the SRC list in
`build-and-run-tests.sh` so the Foundation runner type-checks it).

**`RoomSettingsDraft` did not exist.** The brief assumed it; the repo had
no such type (the settings form was a dozen `@State` properties). It is
defined in `DraftSaver.swift` (a new Models file is outside the allowed
file list) with exactly the values `writeAll()` persisted: name, mascot
name/personality/ideology, maxSeats, memberInviteQuota,
joinStartingBonus, socialNarrationEnabled, briefing48hEnabled,
socialPreferencesEnabled, autoCloseHours, seatDepositAmount,
seatDepositTrigger, seatDepositGraceMinutes, showBroughtBy, hostJournal,
seasonSubtitle. `room.id` is NOT part of it (it identifies the write, not
the form).

**The actor is generic**: `actor DraftSaver<Payload: Sendable>`.
- `submit(_ draft:)` — coalesces; cancels the pending debounce and
  schedules one `Task.sleep` inside the actor. N edits → 1 write, with the
  newest draft.
- `flush() async` — drains the write on the wire, writes the pending draft
  with no debounce, and tries a refused draft once.
- `init(debounce:write:)` — both injected, so E3's tests run in
  milliseconds and need no network.
- The write closure is `@Sendable (Payload) async throws -> Void`.
- Serialisation reuses `WriteGate` (`Models/WriteState.swift`) — the rule
  has one owner; the saver does not write a second copy.

**`DraftWriteStatus`** (same file) — a `@MainActor` `ObservableObject` that
holds the `WriteState` and routes the events to it
(`edited/begin/succeed/fail`). It exists because the write closure runs
off the main actor and cannot touch the view's `@State`, and because a
`@Sendable` closure may not capture the View struct (not `Sendable`). The
view should hold it as `@StateObject private var writeStatus =
DraftWriteStatus()` (the same pattern `ChipScanSheet` uses for
`ScanSettleService`) and read `writeStatus.state` in the status section.
The write closure reports: `begin()` → the write → `succeed()` or
`fail(message)` **and rethrows** (the rethrow is how the saver learns the
write failed).

### The saver's semantics (verified with a scratch harness outside the repo)
1. N rapid submits → exactly 1 write, carrying the newest draft.
2. `flush()` right after a submit → the write lands with that draft, and
   `flush()` returns only after it landed.
3. An edit during an in-flight write → exactly ONE more write, with the
   newer draft (several edits → still one re-write).
4. A refused write is NOT retried on its own — no retry storm. `flush()`
   tries it once (the old dismiss-time retry) and stops.
5. `flush()` with nothing pending does nothing; `flush()` twice is safe.
6. `flush()` while a write is in flight, with an edit landing during it →
   both land ([1, 2]).

### Decisions E2 must respect
- The view must NOT capture itself in the write closure (Sendable). It may
  capture `roomService` (a `@MainActor` class → Sendable) and
  `writeStatus` (a `@MainActor` class → Sendable).
- The view's `writeState` @State, `isDirty`, `writeTask` and `gate` all go
  away; `isDirty`/`needsRetry`/`gate` are the saver's business now.
- `seededShowBroughtBy` still needs a home. It is NOT the same thing as
  the saver's `lastWritten` (the seed value was never written by this
  session), so keep it as view state and let the write closure update it
  after the brought-by RPC succeeds — the closure cannot touch `@State`,
  so either the view updates it when the status turns `.saved`, or the
  box carries it. Pick one in E2 and note it for E4.
- Submits are ordered by the main actor's queue (the view's `Task { await
  saver.submit(...) }` runs on the main actor, FIFO), so the newest draft
  is the one that lands. E2 should submit the CURRENT form values, not a
  value captured when the edit happened.
- The view must create the saver where `roomService` is available (the
  stack-level `.task`), and `onDisappear` becomes
  `Task { await saver.flush() }`.
