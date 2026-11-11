# Task C+D+E: remove three view-layer compensations

## Why, one line each
- C: RoomDetailView infers "still loading" from data shape via `hasLoadedInitialData` (grep it — 3 hits; the V0.100 comment block above its use explains the forever-spinner bug it patched). Replace with an explicit load phase owned by RoomService.
- D: one-shot visual events are stored as @State and reset by timers: `justClaimed` + a 500ms reset Task (about 4 hits), `appearedIndices` Set + per-row `Task.sleep(idx * 50)` stagger (about 6 hits). Replace with declarative, data-bound animation: no stored transient state, no Task.sleep in view code, no isCancelled guards.
- E: RoomSettingsSheet owns write sequencing through view lifecycle: `.task(id: draft)` 600ms debounce attached to the NavigationStack (a sub-sheet push would cancel a Form-attached task), plus onDisappear flush and a writeTask refire for the edit-landed-mid-write race (grep `task(id: draft)` and `writeTask` in RoomSettingsSheet.swift). Replace with a DraftSaver actor that owns (draft, lastWritten); the view only submits and flushes.

## HARD RULES
- You are in your own worktree. Work ONLY here. Never touch ~/Projects/games-room (the main checkout), other worktrees, the live Supabase DB, deploys, or Maestro/opencode config or processes you did not start.
- Never merge, never push, never switch branches, never bump versions, never run a simulator.
- NEVER `git add` ghost duplicates (files whose names match `* [0-9]*.*`). Always `git add` explicit paths.
- One step per iteration: read `.maestro/STATE-cc-cde.md`, do the next step, run the gate, commit with the given message, rewrite STATE, EXIT.
- Before every commit: `git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null; git status --porcelain | grep -E " [0-9]" && echo GHOST-DUP STOP`.
- GATE: `bash .maestro/fastgate.sh` — its last line must read `FASTGATE: PASS`. If it fails, fix YOUR change, never the gate script.
- Read code with `grep -n` plus ~60 lines of context around hits; never read whole files.
- New `.swift` files must be added to BOTH explicit lists: the SRC list in `build-and-run-tests.sh` AND the runner calls in `main.swift` at repo root. A file missing from either breaks a gate you cannot see.
- Progress = ticked steps / total. Only declare the run complete when STATE reads `ALL STEPS DONE`.

## Steps
- [ ] C1. New file `GamesRoom/Services/LoadPhase.swift`: `enum RoomLoadPhase: Equatable { case idle, loading, loaded }`. In RoomService add `@Published private(set) var roomLoadPhase: [UUID: RoomLoadPhase] = [:]` and `func loadPhase(_ roomId: UUID) -> RoomLoadPhase` (missing key = .idle). At the room refresh entry points RoomDetailView calls (grep RoomDetailView.swift for `refresh(force:` and follow into RoomService loaders): on start, only transition .idle → .loading — a refresh while .loaded STAYS .loaded (pull-to-refresh must never re-show a spinner); on completion (success OR failure) → .loaded. Failure-to-loaded is deliberate: the phase means "first load finished"; errors surface through existing error paths.
- [ ] C2. RoomDetailView: replace the `if !hasLoadedInitialData { return .loading }` branch with the store phase; DELETE `hasLoadedInitialData`, all its set sites, and the V0.100 comment block. Gate must pass.
- [ ] C3. New Foundation test file (find where existing table tests live by grepping `main.swift` for test registrations; copy that pattern): idle → loading → loaded; .loaded stays .loaded when a second refresh starts; unknown room → .idle. Register the file in `main.swift` and `build-and-run-tests.sh`.
- [ ] D1. Seat grid (grep `justClaimed` in RoomDetailView.swift): remove the @State bool, the 500ms reset Task, and the onChange that drives them. Replace with emphasis derived FROM the rsvps data: my-seat state computed as `rsvps.contains { $0.memberId == me && $0.state == .claimed }`, animation attached with `.animation(Theme.Motion.fade, value: rsvps)` or scoped `withAnimation` at the change. CONSTRAINT: no stored transient, no Task.sleep, no asyncAfter. Reduced-motion safe (use Theme.Motion tokens only).
- [ ] D2. Stagger (grep `appearedIndices`): delete the Set and `staggerAppear()`. Replace with declarative delay — e.g. row modifier `.animation(.easeOut(duration: 0.25).delay(Double(idx) * 0.05), value: <the data the list renders>)`, or a container-level `.animation(..., value: rows)`. Visual goal: rows fade in staggered on first render with zero stored appearance state. If a per-row entrance that fires only on scroll-into-view is impossible without stored state, use the group-level animation and note it in the REPORT.
- [ ] E1. New file `GamesRoom/Services/DraftSaver.swift`: `actor DraftSaver` with `submit(_ draft:)` — coalesces: cancels any pending debounce, schedules one write after 600ms via Task.sleep INSIDE the actor (debounce is a product decision; owning it in the model instead of the view lifecycle is the fix) — and `flush() async` (awaits an in-flight write, writes the pending draft immediately, safe to call repeatedly). Serial semantics: at most one write in flight; an edit that lands during a write queues exactly one re-write. Read RoomSettingsSheet's current `writeAll()` / `writeTask` logic first and port its actual write call. Inject both the write closure and the debounce interval so tests are fast and hermetic.
- [ ] E2. RoomSettingsSheet: remove `.task(id: draft)`, the onDisappear writeTask-refire block, and `writeTask` state. The field-change callback (the single funnel every field's `.onChange` already calls) now calls `saver.submit(draft)`; `onDisappear` becomes `Task { await saver.flush() }`. Behaviour unchanged from the user's side: edits land within ~600ms; dismissing never loses the last edit.
- [ ] E3. Foundation tests for DraftSaver: N rapid submits → exactly 1 write after quiescence; flush right after submit → write lands with the latest draft; edit during an in-flight write → exactly one more write fires with the newer draft.
- [ ] E4. `REPORT-task-CDE.md`: for each of C, D, E — what was deleted (grep anchors), what replaced it, and any behaviour difference you could not avoid.
- [ ] Final: gate, commit, STATE reads `ALL STEPS DONE`.

Commit messages, in order: `C1: room load phase in store`, `C2: view reads phase`, `C3: phase tests`, `D1: claim emphasis from data`, `D2: declarative stagger`, `E1: DraftSaver actor`, `E2: settings sheet hands off to saver`, `E3: saver tests`, `E4: report`.

## Allowed files
`GamesRoom/Views/RoomDetailView.swift`, `GamesRoom/Views/RoomSettingsSheet.swift`, `GamesRoom/Services/LoadPhase.swift` (new), `GamesRoom/Services/DraftSaver.swift` (new), ONE new Foundation test file in the existing test location, `main.swift` (runner list lines only), `build-and-run-tests.sh` (SRC list lines only), `REPORT-task-CDE.md`, `.maestro/STATE-cc-cde.md`.

## STOP AND REPORT (do not guess)
- The just-claimed glow must visually OUTLIVE the rsvps render pass — a timed highlight the data cannot express. Report it; do not add a timer.
- RoomSettingsSheet's write path cannot be funnelled through one actor without editing files outside the whitelist.
- Any XCUITest / ScreenshotSweepTests assertion references the staggered appear or the claim glow (never edit UI tests — report).
- The Foundation runner cannot construct RoomService or RoomSettingsDraft for tests (it should — both are already in the SRC list; if not, report).
