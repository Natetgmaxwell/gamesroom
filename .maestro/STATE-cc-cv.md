# STATE cc-cv
Base: 6ecea66755cfa13519f30e0ca4461428045c7636  Branch: cc/casino-visible
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: ALL STEPS DONE
- [x] CV1 where casino is hidden — facts
- [x] CV2 picker shows the always-on casino row
- [x] CV3 member renders include casino
- [x] CV4 tests repointed + report

## CV4 DONE (commit "CV4: tests repointed + report")

What CV4 changed:

- Re-verified the repoint rule (design 4: "repoint, never delete"): no Foundation test and no
  `ScreenshotSweepTests` assertion encoded "casino is absent from the picker / from a member
  render". `main.swift`'s registry case, `TestsNextNight.swift:137` and `TestsS1.swift:42` all
  already assert casino FIRST, so nothing was repointed and nothing was deleted. The sweep never
  opens the picker's pack section and asserts no pack name or option count.
- Made the two surfaces Foundation-testable instead of copying their rules into a test
  (`AGENTS.md`: one pure type, one table test — a second copy of a rule is a bug):
  - `GamesRoom/Models/NextNight.swift` now owns `NightPackOrder.displayNames(for:)`,
    `NightPackOrder.caption(for:)` ("Casino · Monopoly Deal"), `NightPackPicker.rows(catalog:)`,
    `NightPackPicker.tickableSet(seed:)` and `NightPackPicker.isAlwaysOn(_:)`.
  - `GamesRoom/Views/AddEventSheet.swift` asks `NightPackPicker` for its rows, its seed and its
    readonly guard. Behaviour is unchanged: the catalog, the row order, the seed filter and the
    `togglePack` guard compute exactly what they computed in CV2.
  - `GamesRoom/Views/RoomDetailView.swift`'s `BriefingSlot` asks `NightPackOrder.caption(for:)`
    for the member's games line. Same line as CV3, one copy of the rule.
  - `save()` is untouched: it still files casino first and dedupes.
- New Foundation test file `TestsCasinoVisible.swift` (24 table-driven cases), registered in
  `build-and-run-tests.sh` and called from `main.swift`:
  - the picker's ROWS: casino present, first, listed once (live registry + 5 catalog shapes);
  - the picker's TICKABLE SET: the always-on pack is never in it, whatever the seed — this is
    "readonly" at the state level; the only difference between rows and tick set is the always-on
    pack;
  - the member's PACK LIST and LINE: casino first, once, retired packs dropped, never empty, and
    the exact line "Casino · Monopoly Deal".
- `REPORT-task-CV.md` is finished: §10 (CV3 as built) and §11 (CV4 as built, the repoint check,
  the member before/after, the UI-only items left for the orchestrator's sweep, and the
  stop-and-report note that `docs/STATE-MACHINES.md` has no entry for the new pack-order/picker
  derivation — that file is outside this lane's allowed files).
- Verification: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (654 cases, 74/74 SwiftUI
  parse-checks); `bash .maestro/fastgate.sh --compile` -> FASTGATE: PASS (simulator-less iOS
  build succeeded).

The lane is done: the host's picker lists casino first as a readonly pre-ticked row, the
member's card names the night's games with casino first, and both read from one pinned rule.
