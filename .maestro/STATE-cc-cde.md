# STATE cc-cc-cde
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/client-local-state  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/client-local-state
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: E4
- [x] C1 LoadPhase enum + RoomService phase tracking
- [x] C2 RoomDetailView reads phase; delete hasLoadedInitialData
- [x] C3 phase table tests
- [x] D1 claim emphasis derived from rsvps data (no stored bool/timer)
- [x] D2 declarative stagger (delete appearedIndices + staggerAppear)
- [x] E1 DraftSaver actor
- [x] E2 RoomSettingsSheet hands off to saver
- [x] E3 DraftSaver tests
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

## E1 — what landed

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
`@Sendable` closure may not capture the View struct (not `Sendable`).

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

## E2 — what landed (read this before E3)

**Commit** `6230c41` "E2: settings sheet hands off to saver". Only
`GamesRoom/Views/RoomSettingsSheet.swift` changed.

### Deleted anchors (all gone from RoomSettingsSheet.swift)
- `.task(id: draft)` — the 600ms debounce task on the NavigationStack.
- `writeTask` — the in-flight handle the dismiss path refired.
- `isDirty` — "an edit no write has captured yet".
- `gate` — the view's own `WriteGate` (the saver owns the rule now).
- `writeState` — the `@State`; replaced by `DraftWriteStatus`.
- `draft` — the counter every edit bumped.
- `bumpDraft()`, `needsRetry`, `writeAll()`.

### What replaced them
- `@StateObject private var writeStatus = DraftWriteStatus()` — the status
  object; the status section now reads `writeStatus.state`.
- `@State private var saver: DraftSaver<RoomSettingsDraft>?` — the actor.
- `makeSaver()` — builds the actor with the write closure. The closure
  captures ONLY `roomService` (a `@MainActor` class → Sendable),
  `writeStatus` (a `@MainActor` class → Sendable) and `room.id` (UUID).
  It never captures the view.
- `persistRoomSettings(service:roomId:draft:)` — a file-level `private
  func`, not a method on the view, because the `@Sendable` write closure
  may not capture the view. It does exactly what the old `writeAll()` did,
  in the same order: `updateRoom` → `setShowBroughtBy` →
  `updateHostJournal` → `setSeasonSubtitle`; the journal/subtitle writes
  are skipped when the settings write throws.
- `submitDraft()` — the single funnel every field's `.onChange` calls. It
  reads the CURRENT form values (`currentDraft()`) and submits them:
  `Task { @MainActor in await saver.submit(draft) }`. The `@MainActor`
  keeps the submits ordered (FIFO on the main actor's queue), so the
  newest draft is the one that lands.
- `onDisappear` — `Task { @MainActor in await saver.flush() }`.

### The seed guard changed (read this before E4)
The old code compared the field to the last value the server acknowledged:
`if newValue != seededShowBroughtBy { bumpDraft() }`. That guard did two
jobs: (1) swallow the open-time seed, (2) swallow a change back to the
acknowledged value. Job (2) is unsafe with the saver: the saver captures
the payload at SUBMIT time, while the old code read the form at FIRE
time — so a swallowed change left a stale payload behind and the write
landed the value the user had already changed away from. The new guard is
job (1) only: the seed's one change is swallowed by
`isSeedingShowBroughtBy` / `isSeedingSeasonSubtitle` (two flags set right
before the seed is applied and cleared by the `onChange` that carries it),
and EVERY later change submits. The payload therefore always mirrors the
form — which is what the old code got by reading the form at fire time.

Consequences to report in E4:
1. A change back to the last acknowledged value now schedules a write. It
   is idempotent (the server already holds that value), but it is a write
   the old code did not make.
2. The "seed moves with every successful write" baseline is gone:
   `seededShowBroughtBy` is now only the seed (`nil` until it is read) and
   `seededSeasonSubtitle` only the seeded subtitle. Neither is compared
   against a field any more, and the write closure no longer reports the
   acknowledged value back (nothing needs it).
3. The dismiss path no longer writes twice: the old `onDisappear` wrote
   again whenever `draft > 0` and no write was in flight; the saver's
   `flush()` writes only what is pending.
4. `seededShowBroughtBy` keeps its "have we seeded?" role: `nil` until the
   open-time seed has been read.

### Verification
`bash .maestro/fastgate.sh --compile` → `FASTGATE: PASS`
(599 unit cases, 74 parse-check files, `BUILD SUCCEEDED`; no new warnings
in RoomSettingsSheet.swift / DraftSaver.swift).

### Notes for E3
`DraftSaver.swift` was NOT touched in E2, so the tests are written against
the E1 API:
- `init(debounce:write:)` — both injected; use a 10ms debounce.
- `submit(_:)` — coalesces; one write after the debounce.
- `flush() async` — drains the wire, writes the pending draft now, retries
  a refused draft once.
- `lastWrittenDraft()` — the draft the last write captured.
- The write closure is `@Sendable (Payload) async throws -> Void`, and the
  actor is generic: the test payload can be a plain `Int`/`String`
  (Sendable) instead of `RoomSettingsDraft`.
- The recorder the closure writes into must be Sendable — use an actor (or
  a lock-protected box), not a plain mutable array captured by the closure.
- The three cases the brief names: N rapid submits → exactly 1 write after
  quiescence; flush right after submit → the write lands with the latest
  draft; an edit during an in-flight write → exactly one more write, with
  the newer draft.
- The new test file must be added to BOTH `main.swift` (the runner call)
  and the SRC list in `build-and-run-tests.sh`, or the gate will not see it.

## E3 — what landed

**Commit** `d11b922` "E3: saver tests". Three files:
`TestsDraftSaver.swift` (new), `build-and-run-tests.sh` (one SRC line),
`main.swift` (one runner call, `runDraftSaverTests(runner)`).

**New file** `TestsDraftSaver.swift` at the repo root, next to
`TestsLoadPhase.swift` — the same shape: a `run…Tests(_ runner: TestRunner)`
function, seven cases, Foundation only.

### The seven cases (all green, 606 unit cases total, 599 before)

1. **N rapid submits → exactly one write.** Five submits 100 ms apart
   (debounce 100 ms) → exactly one write, carrying the newest draft (5).
   A flush afterwards writes nothing more, so nothing was left pending.
2. **Flush right after a submit → the write lands with the latest draft.**
   The debounce is 2 s and the flush still lands the write immediately
   (asserted: the flush returned in under a second), so dismissing the
   sheet never waits out the debounce.
3. **An edit during an in-flight write → exactly one more write.** The
   first write is parked in a latch so it is genuinely on the wire; three
   edits (2, 3, 4) land while it is parked; after the latch opens there is
   exactly ONE more write, carrying 4. This is the "an edit that lands
   during a write queues exactly one re-write" rule.
4. **A refused write is not retried on its own.** The write closure throws;
   one attempt, no retry storm, and `lastWrittenDraft()` stays `nil`.
5. **A flush retries a refused draft exactly once.** One flush → two
   attempts (the write + the dismiss-time retry), no more.
6. **A flush with nothing pending writes nothing** (and is safe twice).
7. **The real `RoomSettingsDraft` is a usable payload** — the saver
   carries the app's actual draft type, not just a test Int.

### Test doubles

- `DraftWriteRecorder<Payload: Sendable>` — an **actor**. The saver's
  write closure is `@Sendable`, so a plain mutable array captured by it
  would not compile; this is the "recorder must be Sendable" gotcha from
  the E2 handoff, honoured.
- `DraftWriteLatch` — a `@unchecked Sendable` final class with an
  `NSLock` (the repo's existing pattern, cf. `QuestionBoxPush.swift`),
  parking a write until the test releases it. This is what makes case 3
  deterministic: no sleeps guess at "is the write in flight yet?".
- `DraftSaverTestError.refused` — the refusal the refusing writer throws.

### Notes for E4 (new behaviour facts the tests pinned)

1. **The re-write is not fired the instant the in-flight write ends.**
   `WriteGate.end()` only reports "refire" when a `fire()` attempt was
   refused *while* the write was on the wire. If the write finishes
   BEFORE the pending edit's own debounce elapses, the edit is not written
   early — it waits out its own 600 ms window and is written then. The
   user-visible promise ("an edit lands within ~600 ms") still holds,
   because the window is measured from the edit, not from the write's
   end. `flush()` does not have this property: it writes the pending
   draft immediately, so dismissing the sheet writes it at once.
2. **A refused draft is remembered, not pending.** It is retried once per
   `flush()` call. A second flush retries it again (the saver keeps
   `failedDraft` until a flush takes it). The old view retried at most
   once per dismiss; the saver can be flushed more than once in
   principle, though the sheet flushes once.
3. **`lastWrittenDraft()` only advances on a success.** It is `nil` after
   a refused write — there is no "last attempted draft".
4. **The payload is captured at SUBMIT time** (case 1 writes 5, the last
   value submitted, not the last value the form happened to hold). This
   is the difference from the old view code, which read the form at FIRE
   time; E2 already adjusted the seed guard to match.

### Verification

`bash .maestro/fastgate.sh --compile` → `FASTGATE: PASS`
(606 unit cases, 74 parse-check files, `BUILD SUCCEEDED`).
The seven cases were run four extra times back-to-back with no flake.

