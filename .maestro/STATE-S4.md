# STATE S4

STATE: step 7 of 9 done. Next: step 8.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 7 notes (S4.7: reader card, scan sheets, pack detail on the system, commit 04a5773)

Odd screens (#7, #19, #21, #22, #24, #30). Styling only: no logic,
state, string or condition changes, and no view reordering. The two
structural moves are the wrapping the findings ask for (the reader
card's question block, the attestation rows, the scan sheets' footer
group) and the two button rows that had to stack (the reader's
Done/Pass, the scan sheets' Done/Re-scan) because a full-width
primary cannot share a row with a secondary.

- Live card pills (#7) - "Counted: N pts, settled" and "Working
  hand: N pts" are plain accent captions now: no capsule, no accent
  wash, no 10pt/6pt inner padding, so the text starts on the card's
  leading edge like every other line (the pill used to push its own
  text 10pt right of the title's edge). The attestation readings are
  list rows, the same shape as the system banner: each takes
  `roomRowInset`, a hairline separates two of them, and the stack's
  own spacing is 0 so the hairline touches neither row. The row's
  label-to-amount gap is `cardLineGap`.
- Reader card (#19) - margin is `gutter` (32, the app's full-screen
  margin) instead of 28; the question wears `Theme.Typography.displayLarge`
  (new token: Fraunces 34) instead of the system New York serif at 34,
  so the app has one serif, not two; the card's groups sit
  `roomSectionGap` apart and the question block (ritual line, the
  question, "asked by", the first answer line) is one group
  (`cardLineGap`). Done is the app's one primary, full width, and
  Pass is the app's one secondary under it - they are no longer two
  equal-weight halves of a row (#31).
- Scan sheets (#21, #30) - both sheets (chips and CAH) now share one
  `edgePadding` inset for the whole flow (the camera preview and the
  caption block used to differ: the chips sheet padded 32, the CAH
  sheet padded nothing). The camera and the caption block are
  `cardGroupGap` apart, the caption lines `cardLineGap` apart, the
  sheet's bottom inset `roomSectionGap`. Every centred text carries
  `.multilineTextAlignment(.center)` - the orange caption used to hang
  from a left edge 7pt inside its neighbours. Errors are
  `Palette.loss` (was `Color.red.opacity(0.85)`), the upload scrim is
  `Palette.background.opacity(0.45)` (was `Color.black.opacity(0.45)`),
  and the preview's corner radius is `cardRadius`. On the result
  screen the Done button is the app's one primary and "Re-scan" is the
  app's one secondary under it (it was an accent-outlined box, a fifth
  button geometry).
- Pack detail (#22) - the nav title carries the pack name, so the
  header no longer prints it a second time; the header is the pack's
  mark (title face, `.imageScale(.large)`) and its scoring type, with
  the icon `cardInset` from the label. The outer stack is
  `cardGroupGap`, the section blocks are `cardLineGap`, and the
  ad-hoc `.padding(.top, 4)` on every section is gone.
- Prefs sheets (#24) - the notification prompt card and the calendar
  voice line are on the tokens: icon-to-text `cardInset`, the
  question and its button row `cardGroupGap` apart, the two-line
  toggle rows `cardLineGap`, the anchor-push row's stack
  `cardLineGap`, and the error lines are `Palette.loss`. The 2pt
  optical nudge that aligns each icon with its first text line is
  now `Theme.Layout.cardLineGap / 2` - the same value, off the
  magic number.

Literal counts for the seven files this step touched (the audit's
method, `grep -cE` per pattern; the febbae3 numbers are from
`docs/audit/2026-11-08/03-spacing.md`, the now numbers are this
branch after S4.7):

| File | spacing | padding | sysFont | radius | opacity | frame |
|---|---|---|---|---|---|---|
| RoomDetailView.swift (febbae3 -> now) | 41 -> 20 | 34 -> 11 | 0 -> 0 | 16 -> 3 | 60 -> 50 | 6 -> 4 |
| QuestionBoxViews.swift | 10 -> 2 | 5 -> 0 | 1 -> 0 | 5 -> 1 | 8 -> 5 | 0 -> 0 |
| ChipScanSheet.swift | 12 -> 2 | 9 -> 0 | 1 -> 1 | 5 -> 0 | 10 -> 9 | 1 -> 1 |
| CAHCardScanSheet.swift | 8 -> 1 | 8 -> 0 | 0 -> 0 | 5 -> 0 | 7 -> 6 | 0 -> 0 |
| PackDetailView.swift | 4 -> 0 | 1 -> 0 | 1 -> 0 | 0 -> 0 | 4 -> 4 | 0 -> 0 |
| RoomNotificationPrefs.swift | 7 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 4 | 0 -> 0 |
| MemberCalendarSettingsSheet.swift | 2 -> 0 | 1 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 4 | 0 -> 0 |

Every remaining `spacing: <n>` in those files is `spacing: 0` (a
stack whose children carry their own insets or a hairline) and every
remaining opacity is a `primaryText.opacity(x)` grey, which is step 8's
work.

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases,
parse-check 64/64). Also type-checked the whole app source tree
(123 files) against the iOS 27 simulator SDK with the cached Supabase
module (`swiftc -typecheck`, deployment target 26.0): 0 errors.
Verified the check is real by planting a deliberate type error in
`PackDetailView.swift` (caught: "cannot convert value of type 'CGFloat'
to expected argument type 'Edge.Set'", then reverted).

Residual, deliberately left alone:

- The "Add an event" CTA keeps its `.padding(.top, 4)`
  (`RoomDetailView.swift:1177`).
- `PackDetailView`'s `.padding(.top, 4)` is gone (that was finding
  #22, this step).
- The season comparison sheet (`Components/SeasonComparisonViews.swift`)
  still has 2/3/6 gaps of its own: a different card family, and no
  finding lists it.
- The room page's icon-less rows (round history, notes, seasons) still
  start at their container's left edge - carried over from step 5.
- `QuestionBoxViews.swift`'s ask field keeps its radius-8 stroke
  (`cornerRadius: 8`) and the scan sheets keep their radius-8 chip
  counters: radii are step 8's job (#26).

Next iteration is step 8 only: greys and radii (#25, #26) - map every
`primaryText.opacity(x)` in Views to `secondaryText` / `tertiaryText`
/ `labelText` / `bodyMuted`, and every radius to `buttonRadius`,
`cardRadius` or `smallRadius` by context (leaving the 2/2.5 bar radii
and the exempt `SeasonStatCardView`). Then step 9 is the report.
