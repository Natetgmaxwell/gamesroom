# STATE S4

STATE: ALL STEPS DONE (9 of 9). Lane complete.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 9 notes (S4.9: report, commit 392cb10)

The report. `bash .maestro/fastgate.sh --compile` -> FASTGATE: PASS
(302 unit cases, parse-check 64/64, xcodegen + xcodebuild BUILD SUCCEEDED,
no ` error:` line). `.maestro/S4_REPORT.md` was rewritten from scratch; it
replaced an unrelated `polish/s4-chrome` report of the same name that was
carried in the tree.

### How the before column was produced

The audit's own source, not a re-derivation: `git archive febbae3` extracted
to a scratch directory and counted with the same script as the after column.
The audit says it read febbae3 the same way (`03-spacing.md` line 3).

Patterns, unchanged from `03-spacing.md`:

```text
spacing  grep -cE 'spacing: [0-9]'
padding  grep -cE '\.padding\((\.[a-z]+, )?[0-9]'
sysFont  grep -cE '\.system\(size:'
radius   grep -cE 'cornerRadius: [0-9]'
opacity  grep -cE 'opacity\([0-9]'
frame    grep -cE '\.frame\((width|height|maxWidth): [0-9]'
```

Scope: every `.swift` under `GamesRoom/Views`, plus
`GamesRoomWidgets/GamesRoomWidgets.swift` and
`GamesRoomWatch/GamesRoomWatchApp.swift`. That is the audit's own file set.
`Theme.swift` and `GamesRoom/Auth/SignInView.swift` sit outside the audit's
table and are outside this count, for consistency with it.

**The before column reproduces the audit file for file.** Totals come out at
160 / 102 / 13 / 58 / 213 / 47 against the audit's published
160 / 102 / 13 / 58 / 212 / 47. The one-line difference is
`AppSettingsView.swift:20`, a doc comment containing the word `opacity`,
which the audit's "Clean" row listed as 0. Commented lines are counted, as
the audit specifies.

### Totals, febbae3 -> now

| Pattern | Before | After | Removed | Cut |
|---|---|---|---|---|
| `spacing: <n>` | 160 | 87 | 73 | 46% |
| `.padding(...)` | 102 | 46 | 56 | 55% |
| `.system(size:)` | 13 | 11 | 2 | 15% |
| `cornerRadius: <n>` | 58 | 5 | 53 | 91% |
| `opacity(<n>)` | 213 | 39 | 174 | 82% |
| `.frame(w/h: <n>)` | 47 | 38 | 9 | 19% |

The 174 removed opacities are 162 type greys (`primaryText.opacity`), 8
`.red.opacity(0.85)` error lines moved to `Palette.loss`, 2 hero-card fills
absorbed by `sectionCard`, and 2 live-card pill backgrounds dropped with the
pills.

The 39 left are 37 real sites (10 error reds, 7 mascot ink, 5 share-card
cream, 7 accent washes, 3 disabled washes, 2 scrims, 2 surface and hairline
washes, 1 accent label), plus the `AppSettingsView` comment and the widget's
`.activityBackgroundTint(.black.opacity(0.8))`.

### What is left, and why

- `cornerRadius:` at 5 sites only: `SeasonStatCardView.swift:75,107` (16, 24)
  and `SeasonComparisonViews.swift:242,559,562` (2, 2.5, 2.5). The first pair
  is the exempt share-image export (audit #28), the second the exempt season
  bar radii.
- `.system(size:)` at 11 sites: 9 in the exempt share card, 1 in
  `ChipScanSheet.swift:305` (a 10pt count inverted on a chip swatch), 1 in
  `RoomSettingsSheet.swift:1370` (an 18pt SF Symbol in a Menu label).
- `primaryText.opacity` appears nowhere outside the four token definitions in
  `Theme.swift`. Zero call sites in the whole app tree.
- The 10 remaining `.red.opacity(0.85)` error lines belong to finding #24's
  family, which this lane's brief did not cover.
- `spacing: 0` is 31 of the 87 remaining spacing literals. It is not an
  off-token value; the audit counts it and so does the report.

The full per-file table, the method, the residuals and the gate output are in
`.maestro/S4_REPORT.md`.

### Scripts

In `.maestro/playbooks/Working/`:

- `s4-literal-counts.sh` - the Views-only counter (step 8's).
- `s4-count-all.sh` - whole-tree counter, any root.
- `s4-count-compare.sh` - before/after table, any pair of roots.
- `s4-report-rows.sh` - emits the report's markdown rows.

### Lane summary

| Step | Commit | Subject |
|---|---|---|
| 1 | c785d83 | S4.1: button, secondary-action, grey and radius tokens |
| 2 | 2db641a | S4.2: one primary button |
| 3 | 90bc279 | S4.3: one secondary-action style |
| 4 | 0eacf31 | S4.4: one card chrome; ArrivalCard single inset |
| 5 | 3ece3d8 | S4.5: list text shares one leading edge |
| 6 | 78e143b | S4.6: spacing on the two rhythms |
| 7 | 04a5773 | S4.7: reader card, scan sheets, pack detail on the system |
| 8 | bbf6d14 | S4.8: greys and radii from tokens |
| 9 | 392cb10 | S4.9: report |

Each work commit is followed by an `S4.N: tick box and record notes` commit
that ticks the brief and rewrites this file.

24 files under `GamesRoom/` changed across the lane - `Theme.swift`, 15 in
`GamesRoom/Views/`, 8 in `GamesRoom/Views/Components/` - 814 insertions and
759 deletions. The 6 audit documents under `docs/audit/2026-11-08/` were added
by TARS in the lane's setup commit (`1a44da0`), not by this lane. No logic,
state, condition, string, view order or file structure moved. No file outside
ALLOWED FILES was touched, no test was deleted or weakened, no migration was
written, and `main` was never touched.
