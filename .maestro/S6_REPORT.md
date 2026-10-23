---
type: report
title: "S6 — Room page rhythm + tap a seat to see who (Build 27) gate report"
created: 2026-10-23
tags:
  - v1.2.2
  - s6
  - rhythm
  - design-tokens
  - seat-popover
  - gate
related:
  - '[[S5B_REPORT]]'
  - '[[S5A_REPORT]]'
  - '[[S4_REPORT]]'
  - '[[S6_RHYTHM]]'
---

# S6 — Room page rhythm + tap a seat to see who

Branch `polish/s6-rhythm`, based on `main` = Build 26. Thirteen commits, `ac9ac5b` (the playbook) →
`0762601` (T7's notes). T1–T7 each gated and committed; this is **T8**: the gate on the tip, the diff,
the literal-spacing audit of the three cards, and which screenshots prove what.

Nothing was merged, pushed, rebased or version-bumped, and no migration, Supabase call or deploy
happened. `GamesRoom.xcodeproj/project.pbxproj` was restored after the gate (xcodegen rewrites it on
every run) and is not in the diff.

## Gate on the tip (`0762601`)

`bash .maestro/gate.sh`, whole output — the script prints only its decision lines:

```text
GATE unit: running build-and-run-tests.sh
Ran 302 cases: 302 passed, 0 failed.
parse-check-swiftui: scanning 64 file(s) with iphoneos SDK
parse-check-swiftui: pass=64 fail=0
GATE sweep: xcodegen + ScreenshotSweepTests
	 Executed 19 tests, with 0 failures (0 unexpected) in 197.728 (197.743) seconds
	 Executed 19 tests, with 0 failures (0 unexpected) in 197.728 (197.744) seconds
	 Executed 19 tests, with 0 failures (0 unexpected) in 197.728 (197.744) seconds
** TEST SUCCEEDED **
GATE: PASS
```

302 unit cases, 64 SwiftUI files parse-checked, 19 sweep tests, 0 failures. **The counts did not move
from the S5b tip** (302 / 64 / 19): S6 added no state and no unit case. Every change in this range is
verified by a screenshot or by an element-identity assertion, not by a new test case — see
"What is not verified" below.

One suite sits outside the gate: `QuestionBoxAcceptanceTests`. T4 retargeted
`test_acceptance6_staleCurrentlyIntoHiddenInBriefing` at the seat popover (T3 had broken it by deleting
the list it asserted on) and it passed when run by hand. `.maestro/gate.sh` does not run it, so a
regression there would not turn the gate red.

## File range

`git diff --stat main..HEAD`:

```text
 .maestro/playbooks/S6_RHYTHM.md                   |  82 ++++
 GamesRoom/Services/InMemorySweepSeeds.swift       |   3 +-
 GamesRoom/Theme.swift                             |  11 +
 GamesRoom/Views/QuestionBoxViews.swift            | 119 ++---
 GamesRoom/Views/RoomDetailView.swift              | 526 +++++++++++++++-------
 GamesRoomUITests/QuestionBoxAcceptanceTests.swift |  57 ++-
 GamesRoomUITests/ScreenshotSweepTests.swift      | 146 ++++--
 7 files changed, 656 insertions(+), 288 deletions(-)
```

Plus this report.

Every path is inside the playbook's allowed set (line 13) with one that needs naming:
**`GamesRoomUITests/QuestionBoxAcceptanceTests.swift`** is not on it. T3 handed the file to T4
explicitly ("T4: retarget it at the seat popover") precisely because T3 could not touch an assertion
against a surface T4 was about to restore, and it is not in the gate, so nothing noticed.

`Theme.swift` is 11 lines: the two new tokens from T1 and their doc comments. `InMemorySweepSeeds.swift`
is 3 lines (the `briefing` seed's RSVP rows, so the seat grid has claimed seats to tap). No new files
beyond this report.

## The literal audit

The rule T1 wrote: inside a card, lines that belong together sit `cardLineGap` (4) apart, groups sit
`cardGroupGap` (16) apart, **nothing else**. The audit is the task's own pattern, run over the three
structs' line ranges:

```bash
sed -n '1805,2098p' GamesRoom/Views/RoomDetailView.swift \
  | grep -n "spacing: [0-9]\|padding(.top, [0-9]\|padding(.vertical, [0-9]\|padding(.bottom, [0-9]"
# BriefingSlot  1805–2098
# CeremonialCard 2739–2936
# WitnessSlot (the live card) 2433–2738
```

**Twelve literals remain across the three cards. None of them sets the space between two groups of a
card body.** Every one is a control's own height, a row's own inset, or a spacing between an icon and
its own label inside a button label — the carve-out T2 wrote into the task and T7 repeated.

### `BriefingSlot` — the event card (2)

| Line | Literal | Why it stays |
| --- | --- | --- |
| `RoomDetailView.swift:1970` | `.padding(.vertical, 12)` | Inside the **"Claim seat"** button label, after `.frame(maxWidth: .infinity)` and before `.background(Theme.Palette.accent)`. It is the button's height. T2: "keep paddings INSIDE a button label". |
| `RoomDetailView.swift:2045` | `.padding(.vertical, 10)` | Inside the **"I'm here. Reclaim _n_ CC"** check-in button label, same position in the chain. Same carve-out. |

Note the two are not equal (12 vs 10). That is **not** a rhythm fault — neither number is a step
between groups — but it is a visible inconsistency: two full-width primary buttons in the same actions
group, 4pt different in height. Left alone because changing it is a visual change nobody asked for,
and it would need its own gate. Worth a decision from Nathan if it ever reads as an accident.

### `CeremonialCard` — the settled card (1)

| Line | Literal | Why it stays |
| --- | --- | --- |
| `RoomDetailView.swift:2808` | `HStack(spacing: 4)` | Inside `makeACallButton`'s **label**: "Make a call" + its chevron. An icon beside its own label is the same relationship T7 gave the live card's working-hand badges (`cardLineGap`, `RoomDetailView.swift:2531`), and a button label is the explicit carve-out. |

### `WitnessSlot` — the live card, "The night has started" / "The game is on" (9)

| Line | Literal | Why it stays |
| --- | --- | --- |
| `RoomDetailView.swift:2538` | `.padding(.vertical, 6)` | The **"Counted: _n_ pts, settled"** badge chip's own height, between its `.padding(.horizontal, 10)` and its capsule background. |
| `RoomDetailView.swift:2551` | `.padding(.vertical, 6)` | The **"Working hand: _n_ pts"** badge chip, same role. |
| `RoomDetailView.swift:2568` | `HStack(spacing: 8)` | Inside an attestation row, and **inert**: it sits either side of the `Spacer` that pushes the point amount to the trailing edge, so neither gap is visible. Commented at the line. |
| `RoomDetailView.swift:2577` | `.padding(.vertical, 6)` | Each attestation row's own inset — its height. One reading is one group; the rows themselves sit `cardGroupGap` apart via the outer stack. |
| `RoomDetailView.swift:2595` | `.padding(.vertical, 14)` | The passive **".done"** capsule's height (label, then background, then `Capsule()`). |
| `RoomDetailView.swift:2607` | `.padding(.vertical, 14)` | The **primary CTA** ("Withdraw to play" / "Score a round") label's height. |
| `RoomDetailView.swift:2627` | `.padding(.vertical, 12)` | The **"Withdraw more"** outline CTA label's height. |
| `RoomDetailView.swift:2646` | `.padding(.vertical, 12)` | The **"Count your CAH cards"** outline CTA label's height. |
| `RoomDetailView.swift:2674` | `.padding(.vertical, 12)` | The **"Score a round (host)"** outline CTA label's height. T7's own comment at `:2661` records that the `.padding(.top, 4)` that used to sit above it is gone, so it now takes the stack's `cardGroupGap` like every other group. |

### Adjacent literals that are not in the three cards

`SeatGridRow` (`RoomDetailView.swift:2225–2432`) is a subview of the event card, not one of the three
structs the task named, but T2's carve-out mentions "grid cell", so for completeness — **5**:

- `2259` `GridItem(.flexible(), spacing: 0)` and `2265` `LazyVGrid(columns: columns, spacing: 0)` — the
  chairs butt against each other by design; the hairlines are per-cell overlays, not gaps.
- `2268` `.padding(.vertical, 10)` — inside the seat cell.
- `2319` / `2353` `VStack(spacing: 3)` — the chair glyph and the member's initial inside one cell. **3
  is neither token, and deliberately so: a seat cell is not a card.** It is the tightest, densest
  element on the page and it should stay that way.

## The one open decision T2 handed to "T7 or T8"

T2 left two `VStack(spacing: 8)` behind and named them for a later task. T7 declined both; T8 has to
say which reading is right.

- `RoomDetailView.swift:2106` — `V0StateReEntryPills`, the declined card state's actions.
- `RoomDetailView.swift:3013` — `MemberNotePromptSection`.

**T8's reading: both stay, and here is the reason it is not a shrug.** A subview's internal rhythm is
not the card's rhythm. `V0StateReEntryPills` is a self-contained component that renders a caption, one
primary and one trailing action, and it has been reviewed as a unit since V0.106; `spacing: 8` is its
own design decision at its own scale. T2's rule is about the card **body** — the groups it stacks — and
T7 applied it to two card bodies. Substituting `cardGroupGap` here would widen a 24pt-tall control
cluster to 32pt inside a card whose other groups sit at 16, which is a visible change made silently in
the name of tokenisation.

**What would settle it is a screenshot, and there is not one.** `V0StateReEntryPills` renders only for a
`declined` RSVP, and `grep -rn declined GamesRoom/Services/InMemorySweepSeeds.swift GamesRoomUITests/`
returns **nothing**. The declined card state — one of the four RSVP states T2 rewrote — is never
rendered by any of the 19 sweep tests and is captured by no screenshot in the suite. So the argument
above is about the code, not about how it looks, and no reviewer can settle it from this range either.
A `-screenshots-state=declined` key (the switch arms are `InMemorySweepSeeds.swift:115` and
`RoomPage.swift:95`) plus one `test_19` would make it decidable in a few minutes. **Not built here: T8
is a report task, and a new sweep state is a code change that wants its own gate and its own commit.**

## The rhythm, measured off this gate's own screenshots

Every number below was measured from the attachments in `/tmp/gr-gate.xcresult` (extracted with
`xcrun xcresulttool export attachments`), at 3x on the iPhone 17 Pro (402pt wide), in **ink** boxes:
the card's solid-fill extent for the bottom edge, the first bright pixel row in the left text column
for a caption's top. Ink measurements include each font's line-height slack, so they are larger than
the tokens that produced them — the point is the ratio between a line step and a group step.

| Measurement | Value | Read |
| --- | --- | --- |
| `05` live card bottom → "Standings" glyph top | **33.7pt** | One `roomSectionGap` (32) plus slack. T6's post-fix number was 34.0. |
| `06` settled card bottom → "Standings" glyph top | **34.3pt** | Same. T7 measured 34.6. |
| `16` event card: title / date / place ink gaps | **8.7pt, 9.0pt** | Three lines from one `VStack(spacing: cardLineGap)`. |
| `16` place → description ink gap | **21.0pt** | ~2.4x the line gap, from `cardGroupGap`. |
| `16` description → "Edit details" ink gap | **18.7pt** | Same step again. |
| `16` event card bottom (614.7pt) → "Notes for next time" glyph top (648.7pt) | **33.7pt** | The notes section T5 lifted out of the card now takes exactly one page gap, like every other section. |
| `08` "Can't make it" ink centre vs screen centre | **201.0pt vs 201.0pt** | T2's centring is exact. The primary button above it spans 32.0–369.7pt, the full card content width. |

The T2 ratio — a line step about a third of a group step — is visible in the numbers above and is the
whole point of the token pair.

## The screenshots, by name

All 19 come from the same `ScreenshotSweepTests` run, in `/tmp/gr-gate.xcresult`. Export them with:

```bash
xcrun xcresulttool export attachments --path /tmp/gr-gate.xcresult \
  --test-id 'ScreenshotSweepTests/test_17_briefing_brought_by()' --output-path /tmp/shots
```

**The event card** (T2's two steps, T5's lift-out, T3's missing list) — `16-briefing` is the clearest
read: title/date/place as one tight block, description, "Edit details", the 3×2 seat grid, the
full-width primary, and "Can't make it" centred under it in caption grey, with **"Notes for next time"
now outside the card** on the page background. Also `04-room-page-upcoming-event-partial-seats` (same
card, partial seats), `08-claim-seat-card` (the same card in the unclaimed state — the one that shows
the centred decline button with nothing under it), `17-briefing-seat-grid` (the grid scrolled into
frame), `16b-briefing-scrolled-end` and `04b-upcoming-scrolled-end` (the page tail).

**The seat popover** (T4) — `17-seat-popover-brought-by`: Sam's claimed seat tapped, the popover
anchored to that chair, reading **"Sam"** over **"with Alex · first night · into Bouldering"** — the
whole `WhosComingList` caption, one seat at a time, in the spot the chair was tapped. Its sibling
`17-briefing-seat-grid` is the same page with the popover closed.

**The live card** (T7's `WitnessSlot`) — `05-room-page-tonight-live`: "The night has started", the
"Withdraw to play" CTA, and the gap down to "Standings". `09-host-scoring-dashboard-live` shows the same
card with the badges and attestations in the host scoring sheet.

**The settled card** (T7's `CeremonialCard`) — `06-room-page-settled-last-night`: "Felix held the
table", the settled caption wrapping to two lines, "Tonight's Star · Alex", the quote, and the
"Make a call" chevron row. `12-settled-view-with-deltas` shows it with the score deltas.

**T6's header unification** is verifiable in `16b-briefing-scrolled-end`: Packs and Members print a
bare `SectionTitle` on a row the height of the title itself, chevron and plus centred on it, both grey
subtitles gone, same 17pt left inset as Standings and Seasons.

**T4's `app.swipeUp()` finding changes what `04b` and `16b` are.** On this simulator build `app.swipeUp()`
is a no-op on the room page: measured over six calls the page title did not move, and `04b` came out
pixel-identical to `04`. Every "scrolled end" snapshot in this suite has been a lie until T4 replaced
the gesture with an explicit drag (`scrollUp`). `04b` and `16b` are now real end states, and `test_13`
was failing for the same reason (a taller page from T2's `cardGroupGap`, plus a `scrollIntoFrame` that
gave up on its first iteration).

## What is not verified

1. **No test asserts a frame.** Nothing in the 302 unit cases or the 19 sweep tests checks a gap, a
   height or an alignment. The entire claim of this slice — "sections 32 apart, lines 4 apart, groups
   16 apart" — is enforced by reading the source and confirmed by eye on screenshots. A regression of
   8pt would pass the gate.
2. **The declined card state has no coverage at all** (above). Neither a screenshot nor an element
   assertion.
3. **`QuestionBoxAcceptanceTests` is not in the gate.** T4's popover retarget passes when run by hand;
   nothing runs it automatically.
4. **`MemberNotePromptSection`'s `spacing: 8`** is the same open question as `V0StateReEntryPills`, and
   unlike the declined state, the host scoring sheet *is* in the sweep (`09`, `11`) — so if a future
   task wants to change that one, there is a screenshot to change it against.
5. **The `04b`/`16b` end states were previously wrong for an unknown number of releases**, so any
   earlier screenshot comparison that included them was comparing a duplicate of the frame above it.

## Follow-ups, in order

1. **A `-screenshots-state=declined` sweep key + `test_19`.** Cheap, and it converts the open
   `V0StateReEntryPills` question from a code-reading argument into a picture. Until then the declined
   card — one of four states T2 rewrote — is unproven.
2. **Decide the `12` vs `10` primary-button inset** in `BriefingSlot` (`:1970`, `:2045`). Either is
   defensible; having two is not, and it is 4pt of visible height on the same card.
3. **Add the acceptance suite to `.maestro/gate.sh`** (`-only-testing:GamesRoomUITests/QuestionBoxAcceptanceTests`),
   or record in the playbook that it is a hand-run suite. It has now been the right thing to touch twice.
4. **A frame assertion, if one is ever wanted.** One `XCTAssertEqual`-on-a-known-gap style check on a
   card would convert item 1 above from a source-reading convention into a gate. Design first: the
   tokens are the spec, and nothing enforces them.