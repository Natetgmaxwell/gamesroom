---
type: report
title: "Task C+D+E — three view-layer compensations removed (load phase, one-shot visuals, settings write sequencing)"
created: 2026-11-11
tags:
  - task-c
  - task-d
  - task-e
  - load-phase
  - declarative-animation
  - draft-saver
  - state-machines
  - report
related:
  - '[[cc-cde]]'
  - '[[STATE-cc-cde]]'
---

# Task C + D + E — three view-layer compensations removed

Branch `cc/client-local-state`, based on `7e7bf4b`. Nine step commits, in order:
`2836950` C1 · `e1d1146` C2 · `32655aa` C3 · `11c5405` D1 · `6b20ee8` D2 ·
`87565c5` E1 · `6230c41` E2 · `d11b922` E3. Nothing was merged, pushed, rebased or
version-bumped, no migration or Supabase call changed, and no simulator was run.
`GamesRoom.xcodeproj/project.pbxproj` is restored after every gate run and is not in
the diff.

Each section below answers the same three questions: **what was deleted** (with the
grep anchor that proves it), **what replaced it**, and **what the user can notice**
(the behaviour differences that could not be avoided).

| | Before | After |
|---|---|---|
| "is the room still loading?" | inferred from the shape of the data, in a view flag | an explicit phase in the store |
| "the user just claimed a seat" | a `@State` bool cleared by a 500 ms `Task` | a question the roster answers |
| "the award rows have appeared" | a `Set<Int>` of appeared indices | a delay in the row's transaction |
| "the settings write" | a view-lifecycle debounce + a write handle | an actor that owns the sequencing |

---

## C — "still loading" is a store fact, not a data-shape guess

### Deleted

`grep -n "hasLoadedInitialData" GamesRoom/Views/RoomDetailView.swift` — **3 hits at the
base, 0 in code now** (the name survives only in one explanatory comment at
`RoomDetailView.swift:840`, which says what used to own the question):

| base line | what it was |
|---|---|
| `RoomDetailView.swift:149` | `@State private var hasLoadedInitialData: Bool = false` — the flag |
| `RoomDetailView.swift:421` | `hasLoadedInitialData = true` — the set site, after `await refresh()` in `.task` |
| `RoomDetailView.swift:859` | `hasLoaded: hasLoadedInitialData` — the read, inside `V0State.resolve(...)` |

Also deleted: the **V0.100 comment block** — 14 lines above the declaration explaining
the forever-spinner bug the flag patched ("a freshly-created room with no events + no
leaderboard rows + no briefing pins the state machine at `.loading` forever"), and the
8-line comment inside `.task` explaining why the flag was flipped *after* the refresh
resolved (so a failed refresh did not leave a perpetual spinner).

### Replaced

- **`GamesRoom/Services/LoadPhase.swift`** (new, Foundation-only): `enum RoomLoadPhase:
  Equatable { case idle, loading, loaded }` plus three **pure** table functions —
  `phase(in:for:)` (missing key → `.idle`), `begin(in:for:)` (`.idle` → `.loading`;
  **`.loaded` stays `.loaded`**) and `finish(in:for:)` (→ `.loaded`, success *or*
  failure). Pure on purpose: the Foundation runner can pin the transitions without a
  store, a network or a view.
- **`RoomService`**: `@Published private(set) var roomLoadPhase: [UUID: RoomLoadPhase]
  = [:]`, `func loadPhase(_ roomId: UUID) -> RoomLoadPhase`, and
  `func withRoomLoadPhase<T>(roomId:_ body:) async -> T` — the phase opens around the
  load and closes in a `defer`, so it lands on `.loaded` whether the load succeeded or
  threw. The table is purged with the rest of the store's caches on sign-out.
- **`RoomDetailView`**: `refresh(force:)` is now a one-line wrapper around the phase
  (`await roomService.withRoomLoadPhase(roomId: room.id) { await loadRoomContent(force:
  force) }`), with the old 70-line body moved verbatim into a new
  `loadRoomContent(force:)`. The view reads the store: `hasLoaded: roomService.loadPhase(
  room.id) == .loaded`.

### Behaviour differences

1. **The phase survives the view.** The old flag was `@State` on the view instance, so
   a freshly-created `RoomDetailView` started at "not loaded" and could flash the
   spinner for one refresh. The phase lives in the store, keyed by room, so it survives
   the view's re-creation (a tab switch, a nav-stack rebuild) and the spinner does not
   come back. **Better, but different.**
2. **The phase is per room and shared.** Two surfaces showing the same room now share
   one phase; the old flag was per view instance.
3. **Failure still lands on `.loaded`** — deliberate, and identical to the old
   behaviour ("a long-running fetch failure shouldn't leave the user on a perpetual
   spinner"). Errors surface through the existing error paths; the phase only claims
   "the first load finished".
4. **A refresh of a loaded room stays `.loaded`** — the brief's hard requirement.
   Pull-to-refresh never re-shows a spinner over content the user is reading.

### Tests

`TestsLoadPhase.swift` (new, 7 cases): unknown room → `.idle`; `.idle → .loading →
.loaded`; a loaded room stays loaded when a second refresh starts; a refresh already in
flight stays `.loading`; a failed first load still lands on `.loaded`; phases are per
room, not global; `begin`/`finish` leave other rooms untouched.

### One deviation from the brief's file list, flagged

The brief's "Allowed files" list names `GamesRoom/Services/LoadPhase.swift` but **not**
`GamesRoom/Services/RoomService.swift` — while step C1 explicitly requires the phase to
live in `RoomService` ("Replace with an explicit load phase owned by RoomService",
"`@Published private(set) var roomLoadPhase` … in RoomService"). The two instructions
cannot both be satisfied, so **C1's instruction won** and `RoomService.swift` was edited
(33 added lines: the phase table, `loadPhase(_:)`, `withRoomLoadPhase`, and the sign-out
purge). Reporting it rather than burying it.

---

## D — one-shot visuals derived from the data

### D1 — the claim celebration

**Deleted** — `grep -n "justClaimed" GamesRoom/Views/RoomDetailView.swift`: **4 hits at
the base, 0 now**:

| base line | what it was |
|---|---|
| `2919` | `@State private var justClaimed: Bool = false` |
| `2965` | `justClaimed = true` (inside `.onChange(of: rsvps)`) |
| `2966` | `Task { try? await Task.sleep(for: .milliseconds(500)); justClaimed = false }` — the reset, with **no `isCancelled` guard** (it could write to `@State` after the view was gone) |
| `3010` | `if isYours && justClaimed` — the confetti condition |

The whole `.onChange(of: rsvps)` block that drove them is gone.

**Replaced**

- `mySeatClaimed` — a computed property that asks the roster:
  `rsvps.contains { $0.memberId == me && $0.state == .claimed }` (guarded on
  `currentUserId`). No stored transient.
- The grid owns the animation input: `.animation(reduceMotion ? nil : Theme.Motion.fade,
  value: rsvps)`.
- The cell's own transition moved from an inline `.spring(response: 0.3,
  dampingFraction: 0.7)` to the token `Theme.Motion.popIn` — which **is** that same
  spring (`Theme.swift:198`), so the motion is unchanged; it is tokenised, not altered.
- The confetti condition is now `isYours && mySeatClaimed`.

**Behaviour differences (cannot be avoided)**

1. **The celebration now lasts as long as the seat is claimed, not 500 ms.** The 500 ms
   window was a *timer* — a duration the data cannot express — so it could not survive
   the move to data-bound state without a timer, which the brief forbids. What the user
   actually sees is unchanged: `ConfettiBurst` owns its own one-shot timing
   (`@State burst` + `onAppear` → `withAnimation(.easeOut(duration: 0.45))`, fading to
   opacity 0 and scale 1.4), so the burst is a single burst either way. What changed is
   the **condition that keeps the burst view mounted**, not the burst itself.
2. **The burst no longer re-fires on unrelated roster changes.** The old
   `.onChange(of: rsvps)` set `justClaimed = true` on **any** roster change on which my
   seat happened to be claimed — so another member claiming a seat re-triggered *my*
   celebration. The new code fires the burst exactly when my own claim appears. **This
   is the behaviour the brief asked for, and it is a visible change** for a host
   watching the grid fill up.
3. **A warm-cache room open now celebrates.** `rsvps` is a store cache read
   (`roomService.cachedEventRSVPs(eventId:)`), so on a cold open the roster arrives
   after the first render and both old and new code celebrate; but with the roster
   already cached, the old code never saw a *change* and stayed silent, while the new
   code mounts `ConfettiBurst` on first render and celebrates. A cold open is
   unchanged; a warm open shows one burst that used to be missing.

### D2 — the staggered award rows

**Deleted** — `grep -n "appearedIndices\|staggerAppear" GamesRoom/Views/RoomDetailView.swift`:
**8 hits at the base (6 of them code), 0 now**:

| base line | what it was |
|---|---|
| `3982` | `@State private var appearedIndices: Set<Int> = []` |
| `4095` | `.opacity(appearedIndices.contains(idx) ? 1 : 0)` |
| `4096` | `.offset(y: appearedIndices.contains(idx) ? 0 : 6)` |
| `4097` | `.onAppear { staggerAppear(idx: idx) }` |
| `4106` | `private func staggerAppear(idx: Int)` — the def |
| `4111` | `_ = appearedIndices.insert(idx)` — inside `withAnimation(Theme.Motion.fade)`, after `try? await Task.sleep(for: .milliseconds(idx * 50))` and a `Task.isCancelled` guard |

**Replaced**

- The awards list **container is now always rendered** — the empty-state
  `Text("Awards haven't been declared yet.")` moved *inside* the `VStack`, so the
  container is already in the hierarchy when the async awards land.
- The container owns the group animation: `.animation(reduceMotion ? nil :
  Theme.Motion.fade, value: sortedAwards)`.
- A new private **`StaggeredAwardRow`** puts the per-row delay in the row's
  **transaction** (`Theme.Motion.fade.delay(Double(index) * 0.05)`) and lets the row's
  *content* own the transition (`.transition(.opacity.combined(with: .offset(y: 6)))`).
  Same 6 pt distance, same fade, no scale, no spring — the old motion, expressed as a
  property of the transaction instead of as remembered state.

**Behaviour differences (cannot be avoided)**

1. **The entrance fires when the award list CHANGES, not on the card's first paint.**
   A mount-time entrance cannot be expressed without stored appearance state, which is
   exactly what D2 removes; the brief names this fallback explicitly ("use the
   group-level animation and note it in the REPORT"). With a warm cache the rows are
   simply present when the card appears; with a cold cache they cascade in when the
   awards land — which is the case a user actually sees.
2. **The drowning badge's "you've opted in" footnote now fades with its row's delay**
   instead of appearing instantly. `DrowningBadge.swift` is outside the allowed file
   list, so the footnote could not be opted out of the row's transaction.
3. **The dividers between rows still appear instantly** (no transition) — unchanged
   from the old behaviour.

**Reduced motion**: both D1 and D2 gate on `\.accessibilityReduceMotion` — the grid
animation becomes `nil`, the award rows' transaction animation becomes `nil` — so the
rows are simply there. Only `Theme.Motion` tokens are used.

---

## E — the settings write sequencer moved out of the view

### Deleted — `GamesRoom/Views/RoomSettingsSheet.swift`

| anchor | base lines | what it was |
|---|---|---|
| `.task(id: draft)` | `202` (code), `28` + `105` + `213` + `869` (comments) | the 600 ms debounce, attached to the **NavigationStack** (because a Form-attached `.task` is cancelled by a sub-sheet push) |
| `writeTask` | `114` (decl), `215` + `216` (read), `959` (write) | the in-flight handle the dismiss path refired |
| `bumpDraft()` | `871` (def) + **16 call sites** (`301`–`323`) | the draft counter every field's `.onChange` bumped |
| `draft` | `109` (decl), `202` + `203` (the `.task(id: draft)`), `213` (comment), `223`, `872` | the counter itself |
| `isDirty` | `113` (decl), `873`, `883`, `907` | "an edit no write has captured yet" |
| `needsRetry` | `882` (def), `219` (read) | the dismiss-time retry predicate |
| `writeAll()` | `892` (def), `206`, `220`, `224` + 2 comments | the write itself |
| `gate: WriteGate` | `120` (decl), `899` | the **view's own copy** of the serialisation rule |
| `writeState: WriteState` | `108` | the status `@State` |

After this change, `grep -n "task(id: draft)\|writeTask\|bumpDraft\|writeAll()\|needsRetry"
GamesRoom/Views/RoomSettingsSheet.swift` → **no hits**.

### Replaced

- **`GamesRoom/Services/DraftSaver.swift`** (new, Foundation + Combine):
  - `actor DraftSaver<Payload: Sendable>` — `submit(_ draft:)` (coalesces: cancels the
    pending debounce and schedules one `Task.sleep` **inside the actor**),
    `flush() async` (drains the write on the wire, writes the pending draft now,
    retries a refused draft once), `lastWrittenDraft()`, and
    `init(debounce:write:)` — **both injected**, so the tests run in milliseconds with
    no network.
  - `RoomSettingsDraft` — the payload. **This type did not exist in the repo**; the
    brief assumed it. It is defined in `DraftSaver.swift` (a new `Models/` file is
    outside the allowed list) and holds exactly the values `writeAll()` persisted.
  - `DraftWriteStatus` — a `@MainActor ObservableObject` that holds the `WriteState`
    and routes `edited/begin/succeed/fail` to it. It exists because the write closure
    runs off the main actor and cannot touch the view's `@State`, and because a
    `@Sendable` closure may not capture the View struct.
  - The serialisation rule is **not re-implemented**: the saver composes the existing
    `WriteGate` (`Models/WriteState.swift`).
- **`submitDraft()`** — the single funnel every field's `.onChange` calls. It reads the
  form's *current* values (`currentDraft()`) and submits them:
  `Task { @MainActor in await saver.submit(draft) }` (the `@MainActor` keeps the
  submits FIFO-ordered, so the newest draft is the one that lands).
- **`makeSaver()`** — builds the actor. The `@Sendable` write closure captures only
  `roomService` (a `@MainActor` class → Sendable), `writeStatus` (same) and `room.id`
  (UUID). **It never captures the view.**
- **`persistRoomSettings(service:roomId:draft:)`** — a file-level `private func`, not a
  method on the view, because the closure may not capture the view. It does exactly
  what `writeAll()` did, in the same order: `updateRoom` → `setShowBroughtBy` →
  `updateHostJournal` → `setSeasonSubtitle`; the journal/subtitle writes are skipped
  when the settings write throws.
- **`onDisappear`** — `Task { @MainActor in await saver.flush() }`.
- The saver is built in the stack-level `.task` (where `roomService` is available),
  with a belt-and-braces lazy create in `submitDraft()` so an edit can never be dropped
  because the saver was not there yet.

### Behaviour differences (cannot be avoided)

1. **A change back to the last acknowledged value now schedules a write.** The old
   guard `if newValue != seededShowBroughtBy { bumpDraft() }` swallowed it. The saver
   captures the payload at **submit** time while the old code read the form at **fire**
   time, so swallowing it would have left a stale payload behind and the write would
   land a value the user had already changed away from. The write is idempotent (the
   server already holds that value), but it is a write the old code did not make.
2. **The "seed moves with every successful write" baseline is gone.**
   `seededShowBroughtBy` is now only the seed (`nil` until it is read) and
   `seededSeasonSubtitle` only the seeded subtitle. Neither is compared against a field
   any more, and the write closure no longer reports the acknowledged value back —
   nothing needs it. The seed's role ("have we seeded yet?") is kept.
3. **The dismiss path no longer writes twice.** The old `onDisappear` wrote again
   whenever `draft > 0` and no write was in flight; `flush()` writes only what is
   pending.
4. **The seed guards became two explicit flags** — `isSeedingShowBroughtBy` and
   `isSeedingSeasonSubtitle`, set right before the seed is applied and cleared by the
   `onChange` that carries it — instead of comparing the field to an acknowledged value.
5. **A refused write is remembered, not pending.** It is retried once per `flush()`
   call; a second flush retries it again (the sheet flushes once, so the user-visible
   behaviour matches the old "at most one retry per dismiss"). A refused write is never
   retried on its own — no retry storm.
6. **The re-write is not fired the instant an in-flight write ends.**
   `WriteGate.end()` only reports a "refire" when a `fire()` attempt was refused
   *while* the write was on the wire. If the write finishes **before** the pending
   edit's own debounce elapses, the edit waits out its own 600 ms window and is written
   then. The user-visible promise ("an edit lands within ~600 ms") still holds,
   because the window is measured from the edit, not from the write's end. `flush()` is
   different by design: it writes the pending draft immediately, so a dismiss writes it
   at once.
7. **`lastWrittenDraft()` only advances on success** — it is `nil` after a refused
   write; there is no "last attempted draft".
8. **The payload is captured at submit time** (see 1). The old code read the form at
   fire time, so a value typed and then changed within the debounce window was written
   as the *latest* value; now the draft that was submitted is what is written, and a
   later edit submits a later draft. Both land — the last one wins — but the write
   carries the value that was submitted, not the value the form happened to hold.
   Because every field's `.onChange` submits the form's current values, the pending
   draft always mirrors the form — including a value the open-time seed applied, which
   is carried by the next submit (the seed's own change is deliberately not submitted,
   because the server already holds that value).

### Tests

`TestsDraftSaver.swift` (new, 7 cases): N rapid submits → exactly one write with the
newest draft; a flush right after a submit lands the write immediately (the debounce is
2 s in that test, the flush returns in well under a second); an edit during an
in-flight write (parked on a latch, not a sleep guess) → exactly **one** more write,
with the newer draft; a refused write is not retried on its own; a flush retries a
refused draft exactly once; a flush with nothing pending writes nothing; the real
`RoomSettingsDraft` is a usable payload. The recorder is an **actor** (a `@Sendable`
closure may not capture a mutable array) and the latch is a lock-protected
`@unchecked Sendable` final class.

---

## What was NOT changed — one instance of the E pattern survives, deliberately

**`RoomSettingsCasinoSheet` still owns a view-lifecycle debounce.** In the same file
(`RoomSettingsSheet.swift:1812-1814`):

```swift
.task(id: draftKey) {
    guard loadedConfig != nil, let saved = savedDraftKey, saved != draftKey else { return }
    try? await Task.sleep(for: .milliseconds(600))
    guard !Task.isCancelled else { return }
    await save()
}
```

followed by an `.onDisappear` flush of the same values. This is the **same
anti-pattern E removed** — a `.task(id:)`-attached debounce whose lifetime is the
view's — but it belongs to a **different surface**: the "Casino chips" preset config
(`updateCasinoConfig`), with its own payload, not the room settings draft that E's
steps named (`task(id: draft)`, `writeTask`, `writeAll`). Converting it is a separate
change with its own payload type and its own tests, and it is not one of E's steps.
**Flagged here so the next task can pick it up** rather than left to be discovered.

The other sub-sheets (`RoomSettingsSocialSheet`, `RoomSettingsOperationsSheet`,
`RoomSettingsMembersSheet`) have **no** write debounce of their own: their fields are
hoisted bindings that funnel through the hub's `submitDraft()`.

Two other `Task.sleep` sites survive in the views and are **out of scope** — they are
not one-shot visual events and not the settings write: `RoomDetailView.swift:303` and
`:316` (a toast timer), `:2196` and `:2264` (a 5-second hint timer).

---

## UI tests and the screenshot sweep

- **`GamesRoomUITests/iPadEmptyRoomContentTests.swift`** mentions `hasLoadedInitialData`
  in a comment (`:56`) and in an assertion message (`:92`). The test asserts
  **behaviour** — that an empty room renders "No nights on the books yet" and the "Add
  an event" CTA instead of a perpetual spinner — and that behaviour is preserved by the
  store phase, so the test still passes. Per the brief ("never edit UI tests") it was
  **not** edited; its comment now names a flag that no longer exists.
- **`GamesRoomUITests/ScreenshotSweepTests.swift`** — `test_14_awards_ceremonial_card`
  asserts an award caption exists. The rows still render (D2 changed *how* they enter,
  not *whether* they exist). **No sweep or XCUITest assertion references the staggered
  appear or the claim glow**, so nothing had to be reported as broken and no UI test
  was touched.

---

## Files touched

| file | change |
|---|---|
| `GamesRoom/Services/LoadPhase.swift` | **new** — `RoomLoadPhase` + pure table transitions |
| `GamesRoom/Services/DraftSaver.swift` | **new** — `DraftSaver` actor, `RoomSettingsDraft`, `DraftWriteStatus` |
| `GamesRoom/Services/RoomService.swift` | the phase table + `loadPhase(_:)` + `withRoomLoadPhase` (+ sign-out purge) |
| `GamesRoom/Views/RoomDetailView.swift` | reads the phase (C); claim emphasis from the roster (D1); declarative stagger (D2) |
| `GamesRoom/Views/RoomSettingsSheet.swift` | the write sequencer moved to the saver (E) |
| `TestsLoadPhase.swift` | **new** — 7 cases |
| `TestsDraftSaver.swift` | **new** — 7 cases |
| `main.swift` | the two runner registrations |
| `build-and-run-tests.sh` | the two SRC list entries |
| `REPORT-task-CDE.md` | this file |

---

## Outside the allowed file list — reported, not edited

- **`docs/STATE-MACHINES.md:428`** — the "Left alone on purpose" list still names
  `justClaimed` as view ephemera ("view ephemera such as `packsExpanded` and
  `justClaimed`"). D1 removed `justClaimed`, so that line is now **stale**. The doc
  is not in this task's allowed file list, so it was left alone — it needs one line
  removed (or the entry reworded) by whoever owns the doc.
- **`docs/STATE-MACHINES.md:44`** — documents `V0State.resolve(hasLoaded:phase:
  activeEvent:myRSVP:hasWithdrawn:)`. The signature is unchanged and still correct;
  only the *meaning* of the `hasLoaded` argument moved (from a view flag to the
  store's phase). No edit needed.
- **`docs/loop-artifacts/V0.70_LOOP.md:20`** — a historical artifact describing the
  original `appearedIndices` stagger. History, left alone.
- **`GamesRoom/Views/Components/ConfettiBurst.swift`** — untouched; it already owned
  its one-shot timing, which is what made the D1 change possible without a timer.
- **`GamesRoom/Models/WriteState.swift`** — untouched; the saver reuses its
  `WriteGate` rather than writing a second copy of the rule.

---

## Gate

```text
Ran 606 cases: 606 passed, 0 failed.
parse-check-swiftui: scanning 74 file(s) with iphoneos SDK
parse-check-swiftui: pass=74 fail=0
FASTGATE: PASS
```

606 unit cases at the tip, from 592 at the base `7e7bf4b` (+7 from `TestsLoadPhase.swift`
in C3, +7 from `TestsDraftSaver.swift` in E3). The `--compile` leg ran
`xcodebuild` against `generic/platform=iOS Simulator` and succeeded (the gate fails if
it does not; the script does not echo the line). `GamesRoom.xcodeproj/project.pbxproj`
was restored after the run and is not in the diff. The full `.maestro/gate.sh` (19-screen
screenshot sweep) was **not** run — it needs a simulator, which this task forbids.
