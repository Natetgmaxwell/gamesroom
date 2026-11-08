---
type: report
title: "S4 — Visual finish: before/after literal counts"
created: 2026-11-08
tags:
  - s4
  - spacing
  - tokens
  - grey-scale
  - radii
  - report
related:
  - '[[S3_REPORT]]'
  - '[[S5A_REPORT]]'
---

# S4 — Visual finish report

Branch `s4/finish`, based on `main` @ `febbae3` (shipped 1.2.3). Steps 1 to 9 of
`.maestro/briefs/BRIEF-S4.md` are done and committed. This is the step 9 report:
the literal counts from `docs/audit/2026-11-08/03-spacing.md` re-run against the
finished tree, per file, before and after.

> This file replaces an unrelated `polish/s4-chrome` report of the same name that
> was carried in the tree. Nothing from that lane was kept.

## What landed

Nine steps, one per iteration, each gated. The visual system the audit asked for:

| Concern | Before | After |
|---|---|---|
| Primary button | 4 geometries (pad 10/12/14, radius 10/12/Capsule) | one `PrimaryButtonStyle`, full width, pad 14, radius 12 |
| Secondary action | 3 competing styles (trailing chevron, outlined box, inline) | one centred grey caption, `SecondaryTextAction` |
| Card chrome | hand-rolled radius 14 / 1pt stroke on the two most prominent cards | one `sectionCard` shape, radius 12, 0.5pt stroke |
| Type greys | 13 distinct `primaryText.opacity` levels, 162 call sites | 4 tokens, 0 call sites outside `Theme.swift` |
| Corner radii | 9 distinct values, 58 sites | 3 tokens; 4 values and 5 sites left, all exempt |
| Spacing and padding | 262 literal `spacing:` and `.padding()` values | 133 |

New tokens in `GamesRoom/Theme.swift`:

```text
Palette.secondaryText = primaryText.opacity(0.55)   Palette.tertiaryText = primaryText.opacity(0.4)
Palette.labelText     = primaryText.opacity(0.7)    Palette.bodyMuted    = primaryText.opacity(0.8)
Layout.buttonVertical = 14    Layout.buttonRadius = 12    Layout.cardRadius = 12
Layout.smallRadius    = 8     Layout.rowIconWidth = 28    Layout.fieldInset  = 12
```

## Method

The audit's own method, unchanged. `grep -cE` per pattern, counting lines:

```text
spacing  grep -cE 'spacing: [0-9]'
padding  grep -cE '\.padding\((\.[a-z]+, )?[0-9]'
sysFont  grep -cE '\.system\(size:'
radius   grep -cE 'cornerRadius: [0-9]'
opacity  grep -cE 'opacity\([0-9]'
frame    grep -cE '\.frame\((width|height|maxWidth): [0-9]'
```

- **Before**: `git archive febbae3`, extracted to a scratch directory, counted with the
  same script. This is the audit's own source (`03-spacing.md` line 3), so the before
  column is the audit's table, not a re-derivation of it.
- **After**: the same script over the working tree at `s4/finish` tip (`4b95c20`).
- **Scope**: every `.swift` under `GamesRoom/Views`, plus
  `GamesRoomWidgets/GamesRoomWidgets.swift` and `GamesRoomWatch/GamesRoomWatchApp.swift`.
  That is exactly the file set the audit's table covers. `GamesRoom/Theme.swift` and
  `GamesRoom/Auth/SignInView.swift` are outside the audit's table and are outside this
  count, for consistency with it.
- Commented lines are counted, as the audit specifies. That is why `AppSettingsView.swift`
  shows one opacity hit on both sides: it is the word `opacity` inside a doc comment.

**Reconciliation with the audit.** The before column reproduces
`03-spacing.md` file for file. The totals row comes out at 160 / 102 / 13 / 58 / 213 / 47
against the audit's published 160 / 102 / 13 / 58 / 212 / 47. The single-line difference
is `AppSettingsView.swift`'s commented `opacity(0.x)`, which the audit's "Clean" row
listed as 0. Everything else matches exactly.

## Per-file counts

Before is `febbae3`, after is the `s4/finish` tip.

| File | spacing | padding | sysFont | radius | opacity | frame |
|---|---|---|---|---|---|---|
| `AddEventSheet.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 1 | 0 -> 0 |
| `AppSettingsView.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 1 | 0 -> 0 |
| `ArrivalCard.swift` | 4 -> 1 | 6 -> 6 | 0 -> 0 | 5 -> 0 | 1 -> 0 | 0 -> 0 |
| `CAHCardScanSheet.swift` | 8 -> 1 | 8 -> 0 | 0 -> 0 | 5 -> 0 | 7 -> 1 | 0 -> 0 |
| `ChipScanSheet.swift` | 12 -> 2 | 9 -> 0 | 1 -> 1 | 5 -> 0 | 10 -> 1 | 1 -> 1 |
| `Components/ConfettiBurst.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 | 1 -> 1 |
| `Components/DrowningBadge.swift` | 5 -> 1 | 3 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 0 | 0 -> 0 |
| `Components/LeaderboardRow.swift` | 6 -> 2 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 4 -> 0 | 4 -> 3 |
| `Components/MascotBubble.swift` | 1 -> 1 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 |
| `Components/MascotConfigSection.swift` | 2 -> 2 | 1 -> 1 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 |
| `Components/SeasonComparisonViews.swift` | 15 -> 15 | 6 -> 6 | 0 -> 0 | 3 -> 3 | 15 -> 2 | 9 -> 9 |
| `Components/SeatGridView.swift` | 5 -> 5 | 0 -> 0 | 0 -> 0 | 2 -> 0 | 8 -> 3 | 0 -> 0 |
| `Components/SessionRoundTimeline.swift` | 4 -> 4 | 4 -> 4 | 0 -> 0 | 1 -> 0 | 6 -> 0 | 2 -> 2 |
| `Components/TrajectorySparkline.swift` | 1 -> 1 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 6 |
| `CreateRoomSheet.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 3 -> 1 | 0 -> 0 |
| `EditEventSheet.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 1 | 0 -> 0 |
| `HostScoreEntrySheet.swift` | 3 -> 3 | 3 -> 3 | 0 -> 0 | 2 -> 0 | 3 -> 2 | 1 -> 1 |
| `HostScoringDashboard.swift` | 7 -> 7 | 3 -> 3 | 0 -> 0 | 6 -> 0 | 10 -> 5 | 6 -> 6 |
| `JoinRoomSheet.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 1 | 0 -> 0 |
| `MascotFaceView.swift` | 2 -> 2 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 7 -> 7 | 1 -> 1 |
| `MemberCalendarSettingsSheet.swift` | 2 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 0 | 0 -> 0 |
| `PackDetailView.swift` | 4 -> 0 | 1 -> 0 | 1 -> 0 | 0 -> 0 | 4 -> 0 | 0 -> 0 |
| `PackStoreView.swift` | 1 -> 1 | 1 -> 1 | 0 -> 0 | 0 -> 0 | 2 -> 0 | 1 -> 0 |
| `QuestionBoxViews.swift` | 10 -> 2 | 5 -> 0 | 1 -> 0 | 5 -> 0 | 8 -> 0 | 0 -> 0 |
| `RoomDetailView.swift` | 41 -> 20 | 34 -> 11 | 0 -> 0 | 16 -> 0 | 60 -> 2 | 6 -> 4 |
| `RoomNotificationPrefs.swift` | 7 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 1 | 0 -> 0 |
| `RoomPage.swift` | 7 -> 4 | 5 -> 0 | 0 -> 0 | 5 -> 0 | 13 -> 0 | 5 -> 3 |
| `RoomSettingsSheet.swift` | 7 -> 7 | 3 -> 3 | 1 -> 1 | 0 -> 0 | 20 -> 3 | 3 -> 0 |
| `SeasonStatCardView.swift` | 3 -> 3 | 8 -> 8 | 9 -> 9 | 2 -> 2 | 5 -> 5 | 1 -> 1 |
| `WithdrawChipsSheet.swift` | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 2 -> 1 | 0 -> 0 |
| `GamesRoomWatch/GamesRoomWatchApp.swift` | 1 -> 1 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 |
| `GamesRoomWidgets/GamesRoomWidgets.swift` | 2 -> 2 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 1 | 0 -> 0 |
| **Total** | **160 -> 87** | **102 -> 46** | **13 -> 11** | **58 -> 5** | **213 -> 39** | **47 -> 38** |

### Totals

| Pattern | Before | After | Removed | Cut |
|---|---|---|---|---|
| `spacing: <n>` | 160 | 87 | 73 | 46% |
| `.padding(...)` | 102 | 46 | 56 | 55% |
| `.system(size:)` | 13 | 11 | 2 | 15% |
| `cornerRadius: <n>` | 58 | 5 | 53 | 91% |
| `opacity(<n>)` | 213 | 39 | 174 | 82% |
| `.frame(w/h: <n>)` | 47 | 38 | 9 | 19% |

Two of these numbers deserve a note.

**`opacity` is not the same as "greys still on literals".** Of the 174 removed, 162 were
type greys (`primaryText.opacity`). The other 12 were washes that moved onto tokens or
went away with the thing that drew them:

| Removed | Sites | What happened |
|---|---|---|
| `primaryText.opacity(...)` | 162 | mapped to `secondaryText` / `tertiaryText` / `labelText` / `bodyMuted` |
| `.red.opacity(0.85)` error text | 8 | moved to `Theme.Palette.loss` (the scan sheets and the prefs sheets) |
| `accent.opacity(0.10)` hero fill | 2 | absorbed by `sectionCard` (finding #2) |
| `accent.opacity(0.12)` pill background | 2 | the live card's pills became plain caption text (finding #7) |

The 39 that remain are almost all semantic washes, not type:

| Residual | Sites | Why it stays |
|---|---|---|
| `.red.opacity(0.85)` error text | 10 | finding #24's family, outside this lane's scope. `Theme.Palette.loss` exists and is the fix |
| `MascotFaceView` ink and sweat ladder (0.55-0.9) | 7 | drawing ink, not type grey |
| `SeasonStatCardView` own cream palette (0.08, 0.5, 0.7, 0.85) | 5 | exempt share-image export (audit #28) |
| accent washes (0.12, 0.14, 0.18) | 7 | accent fills on coloured surfaces, plus the gain/loss band |
| disabled accent washes (0.35) | 3 | the unfilled step of a progress arc |
| scan-sheet scrim (0.45) | 2 | `Palette.background.opacity(0.45)`, now on a token colour |
| surface and hairline washes (0.5, 0.6) | 2 | seat grid fills and strokes |
| accent label (0.8) | 1 | `RoomNotificationPrefs.swift:261` |

That is 37 real sites in `GamesRoom/Views`. The scope's other two are the
`AppSettingsView.swift` doc comment and `GamesRoomWidgets.swift:132`
(`.activityBackgroundTint(.black.opacity(0.8))`), which is a widget tint outside this
lane's scope.

**The `spacing` count is flattered by `spacing: 0`.** Thirty-one of the 87 remaining
`spacing:` literals are `spacing: 0`, which is not an off-token value; the audit
counted them and so does this report. Excluding them, the literal spacing values that
remain are 1, 2, 3, 4, 6, 8, 10, 12, 16 and 24 - appearing 1, 8, 1, 10, 6, 7, 4, 10, 5
and 1 times respectively.

## Residuals, and why each one stays

Every one of these was a deliberate call, not an oversight.

**Radii (4 distinct values and 5 sites left, all exempt).**

- `SeasonStatCardView.swift:75,107` - radius 16 and 24. The share-image export has
  its own brand palette and is exempt by design (audit #28). Touching it would change
  a rendered artefact that ships to other apps.
- `SeasonComparisonViews.swift:242,559,562` - radius 2 and 2.5. The season bar and its
  end caps, explicitly exempt in the brief ("leave 2/2.5 bar radii").

**`system(size:)` (11 left).**

- 9 in `SeasonStatCardView.swift` - the exempt share card.
- `ChipScanSheet.swift:305` - a 10pt semibold count drawn inverted on top of a chip
  swatch. It has to take its colour from the chip, so it cannot use the app's type scale.
- `RoomSettingsSheet.swift:1370` - an 18pt SF Symbol in a Menu label. An icon size, not
  a type size. A one-line change to `.font(.title3)` if TARS wants it.

**Opacity.** The table above covers it. The 10 `.red.opacity(0.85)` error lines are the
one substantive item left on the table, and they belong to finding #24.

**Spacing and padding (87 and 46 left).** The bulk is the room page, `RoomSettingsSheet`
and `HostScoringDashboard`. The specific residuals:

- `RoomDetailView.swift` keeps 20 `spacing:` and 11 `.padding()` literals. The room page
  has its own rhythm (`roomSectionGap` / `roomHeaderGap` / `roomRowInset` /
  `cardLineGap` / `cardGroupGap`), which the audit's own findings call for, and the
  literals that remain are the small in-card offsets those tokens do not name. The
  "Add an event" CTA keeps its `.padding(.top, 4)` at `RoomDetailView.swift:1178`.
- `SeasonComparisonViews.swift` keeps 15 `spacing:` and 6 `.padding()` literals. A
  different card family (charts, bands, axes) that no finding lists. Its radii are the
  exempt bar radii.
- `HostScoringDashboard.swift` keeps 7 `spacing:` and 3 `.padding()` literals: the
  round-stepper arc geometry and the member-select rows' internal offsets.
- `RoomSettingsSheet.swift` keeps 7 `spacing:` and 3 `.padding()` literals: `Form` rows,
  which the audit itself lists as native layout.
- `SeasonStatCardView.swift` keeps 3 `spacing:` and 8 `.padding()` literals - exempt.
- `SessionRoundTimeline.swift` keeps 4 and 4, `HostScoreEntrySheet.swift` 3 and 3,
  `ArrivalCard.swift` 1 and 6, `Components/MascotConfigSection.swift` 2 and 1,
  `PackStoreView.swift` 1 and 1 - each a small local rhythm that no finding names.

**Frames (38 left).** 9 removed. The remaining 38 are icon boxes, sparkline heights,
avatar sizes and chart geometry. The audit notes these are not defects: "Not every
literal is a defect (icon frames, sparkline heights, `spacing: 0`), but every one is
off-token."

## What was deliberately not done

- **Not one word of logic moved.** Every change is a literal swapped for a token on an
  existing modifier. 24 files under `GamesRoom/` (Theme.swift, 15 in `GamesRoom/Views/`,
  8 in `GamesRoom/Views/Components/`), 814 insertions, 759 deletions - the line counts
  nearly match because the diffs are mostly one-for-one replacements.
- **The share card, the widgets and the watch app were not tokenised.** The widget
  target does not source `Theme.swift` (audit #27), so tokens there would need the
  target's sources changed first. Out of scope for this lane.
- **The room page's icon-less rows** (round history, notes, seasons) still start at
  their container's left edge. Step 5 gave every row that has an icon a shared leading
  edge; a row with no icon has no icon column to share.

## Gate

`bash .maestro/fastgate.sh --compile`, on the `s4/finish` tip:

```text
Ran 302 cases: 302 passed, 0 failed.
parse-check-swiftui: scanning 64 file(s) with iphoneos SDK
parse-check-swiftui: pass=64 fail=0
FASTGATE: PASS
```

The `--compile` leg runs `xcodegen generate` then
`xcodebuild build -destination 'generic/platform=iOS Simulator'`. It printed no
` error:` line, and the script only reaches its final `FASTGATE: PASS` after
`grep -q "BUILD SUCCEEDED"` matches, so the build succeeded.
`GamesRoom.xcodeproj/project.pbxproj` was restored with `git checkout --` after the
build, so it is not in the commit.

## Files

```text
c785d83  S4.1: button, secondary-action, grey and radius tokens
2db641a  S4.2: one primary button
90bc279  S4.3: one secondary-action style
0eacf31  S4.4: one card chrome; ArrivalCard single inset
3ece3d8  S4.5: list text shares one leading edge
78e143b  S4.6: spacing on the two rhythms
04a5773  S4.7: reader card, scan sheets, pack detail on the system
bbf6d14  S4.8: greys and radii from tokens
```

Each work commit is followed by an `S4.N: tick box and record notes` commit that ticks
the step in `.maestro/briefs/BRIEF-S4.md` and rewrites `.maestro/STATE-S4.md`.
