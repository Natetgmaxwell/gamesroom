# STATE cc-cc-cde
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/client-local-state  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/client-local-state
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: E1
- [x] C1 LoadPhase enum + RoomService phase tracking
- [x] C2 RoomDetailView reads phase; delete hasLoadedInitialData
- [x] C3 phase table tests
- [x] D1 claim emphasis derived from rsvps data (no stored bool/timer)
- [x] D2 declarative stagger (delete appearedIndices + staggerAppear)
- [ ] E1 DraftSaver actor
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
