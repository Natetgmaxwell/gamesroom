# STATE S4

STATE: step 8 of 9 done. Next: step 9.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 8 notes (S4.8: greys and radii from tokens, commit bbf6d14)

Greys (#25) and radii (#26). Styling only: every change is a
literal -> token swap on an existing modifier. No logic, state,
string, condition or view-order change; 174 lines moved, 174
lines back.

### Greys (#25)

Every `Theme.Palette.primaryText.opacity(x)` in `GamesRoom/Views` is
gone - 153 sites across 21 files. The four token definitions in
`Theme.swift` (secondaryText 0.55, tertiaryText 0.4, labelText 0.7,
bodyMuted 0.8) are now the only `primaryText.opacity` calls in the
whole app tree.

| Was | Now | Sites |
|---|---|---|
| 0.55 | `secondaryText` | 99 |
| 0.6 | `secondaryText` | 6 |
| 0.5 | `secondaryText` | 1 |
| 0.7 | `labelText` | 16 |
| 0.4 (+ one written `0.40`) | `tertiaryText` | 14 |
| 0.3 | `tertiaryText` | 4 |
| 0.45 | `tertiaryText` | 2 |
| 0.28 | `tertiaryText` | 1 |
| 0.8 | `bodyMuted` | 6 |
| 0.75 / 0.78 / 0.85 | `bodyMuted` | 3 |

The one conditional grey - `SeasonComparisonViews.swift:203`, the
season row's chevron, `primaryText.opacity(enabled ? 0.4 : 0)` -
became `enabled ? Theme.Palette.tertiaryText : .clear`, so the
disabled chevron stays invisible and the enabled one keeps the
tertiary grey.

Greys that move: 0.5 -> 0.55, 0.6 -> 0.55, 0.75/0.78/0.85 -> 0.8,
0.28/0.3/0.45 -> 0.4. The other 128 sites keep their exact value -
0.55, 0.7, 0.4 and 0.8 are the token values. Two of the movers are
chart geometry rather than type: the season bar's ghost fill (0.28)
and the season trace's solid line (0.85) now sit on the grey scale
too, so the charts and the labels read as one system.

### Radii (#26)

21 shapes across 9 files, by context:

- `buttonRadius` (12) - the interactive shapes: the member-select
  row and the close button in `HostScoringDashboard`, the
  member-select row in `HostScoreEntrySheet`, "Generate scoped code"
  in `RoomDetailView`, and "Log round" in `HostScoringDashboard`.
- `cardRadius` (12) - the card chrome: the room row in `RoomPage`,
  the seat cell in `SeatGridView` (a tile in a grid, not a button).
- `smallRadius` (8) - the small elements: the three ArrivalCard
  mini-buttons ("Forfeit", "Skip: texted", "Skip: away"), the ask
  field and the member-note field (hairline strokes), the "Dispensed"
  mini-button, the member-name badge in `HostScoringDashboard`, the
  "corrected" badge in `SessionRoundTimeline`, and the confetti
  particle in `ConfettiBurst`.

Six shapes actually change size: the four that were radius 10 (the
two member-select rows, the close button, the seat cell, "Generate
scoped code") are now 12, matching every other control. The rest were
already at their token's value, so 8 -> 8 and 12 -> 12 are invisible.
The "corrected" badge (4 -> 8) and the confetti particle (2 -> 8,
clamped by SwiftUI to 3 on a 6x10 rect) move by a hair.

### What is left, and why

`cornerRadius: <n>` now appears in `GamesRoom/Views` only at:

- `SeasonStatCardView.swift:75,107` (16, 24) - the share-card export,
  exempt by design (audit #28).
- `SeasonComparisonViews.swift:242` (2) and `:559,562` (2.5) - the
  season bar and its end caps, the brief's exempt bar radii.

`opacity(<n>)` still appears in Views, but not as a `primaryText`
grey any more: accent washes (0.12/0.14/0.18), disabled washes
(0.35), the scan-sheet scrim (0.45), the mascot's ink ladder
(0.5-0.9), the exempt share card's palette, and 12 error lines still
on `.red.opacity(0.85)`. Those reds are the finding #24 family and
step 8's brief scopes them out ("map every `primaryText.opacity(x)`"),
so they are carried for TARS.

### Literal counts (the audit's method)

Patterns, reproduced from `docs/audit/2026-11-08/03-spacing.md` and
verified to match its febbae3 table exactly, file by file:

```text
spacing  grep -cE 'spacing: [0-9]'
padding  grep -cE '\.padding\((\.[a-z]+, )?[0-9]'
sysFont  grep -cE '\.system\(size:'
radius   grep -cE 'cornerRadius: [0-9]'
opacity  grep -cE 'opacity\([0-9]'
frame    grep -cE '\.frame\((width|height|maxWidth): [0-9]'
```

Febbae3 -> now, for the 23 files step 8 touched (the now column also
carries steps 1-7's work on the same files):

| File | spacing | padding | sysFont | radius | opacity | frame |
|---|---|---|---|---|---|---|
| RoomDetailView.swift | 41 -> 20 | 34 -> 11 | 0 -> 0 | 16 -> 0 | 60 -> 2 | 6 -> 4 |
| Components/SeasonComparisonViews.swift | 15 -> 15 | 6 -> 6 | 0 -> 0 | 3 -> 3 | 15 -> 2 | 9 -> 9 |
| Components/SeatGridView.swift | 5 -> 5 | 0 -> 0 | 0 -> 0 | 2 -> 0 | 8 -> 3 | 0 -> 0 |
| Components/SessionRoundTimeline.swift | 4 -> 4 | 4 -> 4 | 0 -> 0 | 1 -> 0 | 6 -> 0 | 2 -> 2 |
| Components/DrowningBadge.swift | 5 -> 1 | 3 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 0 | 0 -> 0 |
| Components/LeaderboardRow.swift | 6 -> 2 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 4 -> 0 | 4 -> 3 |
| Components/MascotConfigSection.swift | 2 -> 2 | 1 -> 1 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 |
| Components/MascotBubble.swift | 1 -> 1 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 |
| Components/ConfettiBurst.swift | 0 -> 0 | 0 -> 0 | 0 -> 0 | 1 -> 0 | 0 -> 0 | 1 -> 1 |
| RoomPage.swift | 7 -> 4 | 5 -> 0 | 0 -> 0 | 5 -> 0 | 13 -> 0 | 5 -> 3 |
| RoomSettingsSheet.swift | 7 -> 7 | 3 -> 3 | 1 -> 1 | 0 -> 0 | 20 -> 3 | 3 -> 0 |
| HostScoringDashboard.swift | 7 -> 7 | 3 -> 3 | 0 -> 0 | 6 -> 0 | 10 -> 5 | 6 -> 6 |
| HostScoreEntrySheet.swift | 3 -> 3 | 3 -> 3 | 0 -> 0 | 2 -> 0 | 3 -> 2 | 1 -> 1 |
| QuestionBoxViews.swift | 10 -> 2 | 5 -> 0 | 1 -> 0 | 5 -> 0 | 8 -> 0 | 0 -> 0 |
| ChipScanSheet.swift | 12 -> 2 | 9 -> 0 | 1 -> 1 | 5 -> 0 | 10 -> 1 | 1 -> 1 |
| CAHCardScanSheet.swift | 8 -> 1 | 8 -> 0 | 0 -> 0 | 5 -> 0 | 7 -> 1 | 0 -> 0 |
| ArrivalCard.swift | 4 -> 1 | 6 -> 6 | 0 -> 0 | 5 -> 0 | 1 -> 0 | 0 -> 0 |
| PackDetailView.swift | 4 -> 0 | 1 -> 0 | 1 -> 0 | 0 -> 0 | 4 -> 0 | 0 -> 0 |
| PackStoreView.swift | 1 -> 1 | 1 -> 1 | 0 -> 0 | 0 -> 0 | 2 -> 0 | 1 -> 0 |
| MemberCalendarSettingsSheet.swift | 2 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 0 | 0 -> 0 |
| RoomNotificationPrefs.swift | 7 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 1 | 0 -> 0 |
| CreateRoomSheet.swift | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 3 -> 1 | 0 -> 0 |
| WithdrawChipsSheet.swift | 0 -> 0 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 2 -> 1 | 0 -> 0 |

### Gate

`bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases,
parse-check 64/64). Also type-checked the whole app source tree
(123 files) against the iOS 27 simulator SDK with the cached Supabase
module (`swiftc -typecheck`, deployment target 26.0): 0 errors.

### Residuals, deliberately left alone

- The "Add an event" CTA keeps its `.padding(.top, 4)`
  (`RoomDetailView.swift:1178`).
- `SeasonComparisonViews.swift` still has 2/3/6/8/10 gaps of its own
  (a different card family; no finding lists it).
- The room page's icon-less rows (round history, notes, seasons) still
  start at their container's left edge - carried over from step 5.
- 12 error lines still on `.red.opacity(0.85)` outside the two sheets
  step 7 took (finding #24's family, outside this step's brief).
- `MascotFaceView`'s ink opacity ladder is drawing, not type grey.

Next iteration is step 9 only: the report. Run
`bash .maestro/fastgate.sh --compile`, re-run the literal counts above
and write `.maestro/S4_REPORT.md` with the before/after per file.

Note for step 9: `.maestro/S4_REPORT.md` already exists in this tree
from a different lane (the old `polish/s4-chrome` "Chrome stragglers"
report). The brief says step 9 writes `.maestro/S4_REPORT.md`, so that
file is replaced, not appended to.
