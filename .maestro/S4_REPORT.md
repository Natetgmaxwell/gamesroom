---
type: report
title: S4 — Chrome stragglers report (CTA weight inventory)
created: 2026-10-22
tags:
  - s4
  - cta
  - polish
  - inventory
related:
  - '[[S4_CHROME]]'
  - '[[S3_REPORT]]'
---

# S4 — Chrome stragglers

Branch: `polish/s4-chrome` (base `4b9c81a`).

T1 mascot copy, T2 room name once, T3 chip scan sheet margins and T4 season bar labels are
committed and gated. T5 below is an inventory only: no Swift file was touched.

Gate on the T5 tip, last lines: `Ran 286 cases: 286 passed, 0 failed.`,
`parse-check-swiftui: pass=63 fail=0`, `Executed 16 tests, with 0 failures`, `GATE: PASS`.

## CTA pairs

Search run:

```text
grep -rn "borderedProminent\|background(Theme.Palette.accent)" GamesRoom/Views
```

15 hits, and **zero** for `borderedProminent`. Every prominent CTA in the app is hand-built:
a `Text` (or `HStack` of `Image` + `Text`) label carrying `.background(Theme.Palette.accent)`
inside `.buttonStyle(.plain)`. So a pair can only collide when two of those fills, or two of
those accent outlines, share a row or a stack.

Same visual weight, found:

| Where | Pair | Weight | Likely primary |
| --- | --- | --- | --- |
| `GamesRoom/Views/ArrivalCard.swift:101` + `:116` | "Skip: texted" and "Skip: away", side by side in one `HStack(spacing: 8)` | identical: caption semibold, accent text, 12x8 padding, 1px accent stroke, corner 8 | neither. The only filled button in the row is "Forfeit" (`ArrivalCard.swift:86`), so the two Skips are peers with no ranking between them. |
| `GamesRoom/Views/RoomDetailView.swift:2439`, `:2459`, `:2480` | "Withdraw more", "Count your CAH cards", "Score a round", stacked in the at-play card | identical to each other: caption/body semibold, accent text, 12 vertical, 1px accent stroke, corner 12 | the filled CTA above them (`RoomDetailView.swift:2418`, "Withdraw to play" or the pack scan title). The three outlines are peers, one per row. |

Not equal weight, recorded so the absence is deliberate:

| Where | Pair | Difference |
| --- | --- | --- |
| `ChipScanSheet.swift:267` + `:278` | "Done" over "Re-scan" | fill body medium 16 vertical vs outline caption semibold 12 |
| `CAHCardScanSheet.swift:221` + `:232` | "Done" over "Re-scan" | same shape as the chip sheet |
| `QuestionBoxViews.swift:197` + `:207` | "Done" beside "Pass" | accent fill vs hairline stroke, body semibold vs body regular |
| `RoomPage.swift:673` + `:685` | "Create a room" over "Ask a friend for a join code" | accent fill 14 vertical vs hairline outline 12, and the code comment records the P0.2 decision |
| `RoomDetailView.swift:1908` + `:1918` | "Claim seat" + "Can't make it" | accent fill vs `TrailingTextAction` plain text |
| `RoomDetailView.swift:1965` + `:1982` | "I'm here. Reclaim N CC" + "Release my seat" | accent fill vs plain text |
| `RoomDetailView.swift:2048` + `:2057` | "Re-accept" + "Re-decline" | accent fill vs plain text |
| `RoomDetailView.swift:2828` + `:2839` | "Send" beside "Skip" | accent fill vs plain caption text |

Solo fills, no pair to rank: `CAHCardScanSheet.swift:145` "Scan cards", `ChipScanSheet.swift:172`
"Scan chips", `RoomDetailView.swift:1127` "Add an event", `RoomDetailView.swift:3979` "Generate
scoped code", `RoomDetailView.swift:3276` "Dispensed", `RoomPage.swift:623` "Resume".

Accent fills that are not buttons, excluded: `RoomPage.swift:411` and `:477` live dots,
`TrajectorySparkline.swift:46` sparkline stroke.

### Notes

- In both scan sheets "Done" carries the heavier fill while "Re-scan" is the live action for
  the whole time `attemptsRemaining > 0`. The weight reads backwards, but it is a copy and
  weighting decision, not a collision, and this task changes no code.
- Outside the search: sheet toolbars (`WithdrawChipsSheet.swift:103`, `AddEventSheet.swift:147`,
  `EditEventSheet.swift:80`, `JoinRoomSheet.swift:86`, `HostScoreEntrySheet.swift:152`,
  `ChipScanSheet.swift:104`, `QuestionBoxViews.swift:445`, `RoomDetailView.swift:2907`) and the
  destructive `confirmationDialog` actions (`AppSettingsView.swift:147`, `RoomSettingsSheet.swift:520`)
  rely on iOS placement and `role:` rather than Theme tokens. Cancel is forced to
  `Theme.Palette.primaryText` and the confirm action carries `.tint(Theme.Palette.accent)`, so
  those pairs are separated too, but they are the one place prominence comes from the platform
  instead of the palette.

## T6 — Final gate and report

Gate run on the tip of `polish/s4-chrome` with `bash .maestro/gate.sh`, last 15 lines of output:

```text
GATE unit: running build-and-run-tests.sh
Ran 286 cases: 286 passed, 0 failed.
parse-check-swiftui: scanning 63 file(s) with iphoneos SDK
parse-check-swiftui: pass=63 fail=0
GATE sweep: xcodegen + ScreenshotSweepTests
	 Executed 16 tests, with 0 failures (0 unexpected) in 148.280 (148.295) seconds
	 Executed 16 tests, with 0 failures (0 unexpected) in 148.280 (148.296) seconds
	 Executed 16 tests, with 0 failures (0 unexpected) in 148.280 (148.297) seconds
** TEST SUCCEEDED **
GATE: PASS
```

`git diff --stat 4b9c81a..HEAD`:

```text
 .maestro/S4_REPORT.md                              | 77 ++++++++++++++++++++++
 .maestro/playbooks/S4_CHROME.md                    | 28 ++++++++
 GamesRoom/Services/MascotEngine.swift              |  4 +-
 GamesRoom/Views/ChipScanSheet.swift                |  1 +
 .../Views/Components/SeasonComparisonViews.swift   | 54 +++++++++++----
 GamesRoom/Views/RoomDetailView.swift               | 17 ++---
 6 files changed, 156 insertions(+), 25 deletions(-)
```

Every path is inside the allowed set for this stage: the three chrome views, the mascot engine,
this report and the playbook itself. No `main.swift`, no `Tests/`, no `GamesRoomUITests/` and no
project file landed in the range, and no image was attached to any T1 to T6 task.
`GamesRoom.xcodeproj/project.pbxproj` is regenerated by `xcodegen` during every gate run, so it
was restored with `git checkout -- GamesRoom.xcodeproj/project.pbxproj` before staging.