# STATE cc-cc-cde
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/client-local-state  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/client-local-state
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: D2
- [x] C1 LoadPhase enum + RoomService phase tracking
- [x] C2 RoomDetailView reads phase; delete hasLoadedInitialData
- [x] C3 phase table tests
- [x] D1 claim emphasis derived from rsvps data (no stored bool/timer)
- [ ] D2 declarative stagger (delete appearedIndices + staggerAppear)
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
