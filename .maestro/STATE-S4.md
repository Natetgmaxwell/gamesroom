# STATE S4

STATE: step 6 of 9 done. Next: step 7.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 6 notes (S4.6: spacing on the two rhythms, commit 78e143b)

Rhythm (#6, #8-#13, #15-#18). Styling only: no logic, string,
condition or view-order changes, and no file-structure changes beyond
the wrapping the findings ask for (a caption+button group, a
header+list group, the Send/Skip column). Every gap now comes from a
token: inside a card, lines are `cardLineGap` (4) and groups are
`cardGroupGap` (16); on the room page and the Rooms page, sections
are `roomSectionGap` (32), headers sit `roomHeaderGap` (8) above
their first row and rows take `roomRowInset` (12).

- AwardsCard (`RoomDetailView.swift`) (#6) - the card's outer stack
  used `cardInset` as a gap (groups 20 apart) with an inner stack on a
  literal 4, plus four ad-hoc 4pt bumps. Now `cardGroupGap` outside,
  `cardLineGap` inside, and all four `.padding(.top/.vertical, 4)`
  bumps are gone.
- Five headers onto `SectionTitle` (#8) - the empty-standings card
  ("No nights on the books yet" / "Standings"), "Chips to dispense",
  "Tonight's Star" and the Rooms hero's "Continue" eyebrow now use
  the app's `SectionTitle`; `ArrivalCard` already did (S4.4). The
  empty-standings card's grey member line moved to the header's
  `accessibilityHint` (the ArrivalCard pattern), its groups sit
  `cardGroupGap` apart and the header sits `roomHeaderGap` above its
  content. "Chips to dispense" lost its icon and title-size type with
  the header swap, the same way ArrivalCard did in S4.4.
- Claimed card (#9) - "Tap when you walk in..." and the "I'm here"
  button are now one group `cardLineGap` apart instead of a full
  `cardGroupGap` apart.
- Member-note prompt (#10) - the stack is `cardGroupGap`, the field
  takes `Theme.Layout.fieldInset` (12, was 8), Send is the app's one
  `PrimaryButtonStyle` and Skip is the app's one `SecondaryTextAction`
  under it. The pair used to be an inline mini-button beside a
  caption; a full-width primary cannot share a row with a caption, so
  the secondary moved below the primary (the app's one secondary
  shape). The declined state's stack is `cardGroupGap` (was 8).
  `ClaimedCardAskField` (`QuestionBoxViews.swift`) uses `fieldInset`
  too (was 10/8).
- SystemBanner (#11) - rows take `roomRowInset`, the icon sits
  `cardInset` from its text, the row's two lines `cardLineGap` apart,
  and the stack's spacing is 0 so the hairline between two rows
  touches neither of them.
- Inner line gaps (#12) - 2/3/6/8/10 became `cardLineGap` in the seat
  cells, `AwardRow`, `DrowningBadge`, the HostWithdrawals row, round
  history, the pack row, the member row, the reward banner,
  `LeaderboardRow` and `TonightStarSection`. `AwardRow` and
  `DrowningBadge` (siblings in the same awards list) both take
  `roomRowInset` vertically, was a literal 8.
- Sparkline (#13) - the expanded trace takes `cardLineGap` above it
  and nothing below (was `cardInset` on both sides, 64pt of air around
  a 32pt trace).
- Rooms page (#15) - the outer stack is `roomSectionGap`, the header
  and the list are one group `roomHeaderGap` apart, the rows take
  `roomRowInset` (was `cardInset`), and `sectionHeader`'s title is
  now `SectionTitle` (the room count stays, it is that view's own).
  The page's own vertical padding stays `sectionSpacing`, which is
  what the room page uses too.
- Continue hero (#16) - the eyebrow, the room name and the status
  line are one block `cardLineGap` apart; the Resume button starts
  the next group `cardGroupGap` below. The eyebrow is now
  `SectionTitle`.
- Empty Rooms (#17) - the double margin is gone: the state's own
  `edgePadding` padding is deleted (`contentColumn` already pads it),
  the subhead's `gutter` inset is deleted, both buttons are full
  width of the column (the 320 cap is gone) and the stack is
  `cardGroupGap`.
- iPad sidebar (#18) - "App Settings" uses `cardInset` as its icon
  gap (was `gutter`) and `roomRowInset` vertically (was a literal 12).

Literal counts for the five files this step touched (the audit's
method, `grep -cE` per pattern; the febbae3 numbers are from
`docs/audit/2026-11-08/03-spacing.md`, the now numbers are this
branch after S4.1-S4.6):

| File | spacing | padding | sysFont | radius | opacity | frame |
|---|---|---|---|---|---|---|
| RoomDetailView.swift (febbae3 -> now) | 41 -> 20 | 34 -> 16 | 0 -> 0 | 16 -> 3 | 60 -> 52 | 6 -> 4 |
| RoomPage.swift | 7 -> 4 | 5 -> 0 | 0 -> 0 | 5 -> 2 | 13 -> 11 | 5 -> 3 |
| Components/LeaderboardRow.swift | 6 -> 2 | 0 -> 0 | 0 -> 0 | 0 -> 0 | 4 -> 4 | 4 -> 3 |
| Components/DrowningBadge.swift | 5 -> 1 | 3 -> 0 | 0 -> 0 | 0 -> 0 | 6 -> 6 | 0 -> 0 |
| QuestionBoxViews.swift | 10 -> 8 | 5 -> 1 | 1 -> 1 | 5 -> 1 | 8 -> 7 | 0 -> 0 |

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases,
parse-check 64/64). Also type-checked the whole app source tree
against the iOS 27 simulator SDK with the cached Supabase module
(`swiftc -typecheck`, deployment target 26.0): 0 errors. Verified the
check is real by planting a deliberate type error in `RoomPage.swift`
(caught: "cannot convert value of type 'Int' to expected argument type
'String'", then reverted).

Residual, deliberately left alone:

- The "Add an event" CTA keeps its `.padding(.top, 4)`
  (`RoomDetailView.swift:1177`). It is not one of finding #6's four
  bumps (those are all in the awards card) and the CTA is shared with
  the standalone hero card.
- `PackDetailView.swift`'s `.padding(.top, 4)` belongs to finding #22
  (step 7).
- The season comparison sheet (`Components/SeasonComparisonViews.swift`)
  still has 2/3/6 gaps of its own: it is a different card family (the
  season sheet, not the room page) and no finding lists it.
- The room page's icon-less rows (round history, notes, seasons) still
  start at their container's left edge - carried over from step 5.

Next iteration is step 7 only: odd screens (#7, #19, #21, #22, #24,
#30) - live-card pills to plain caption text, the reader card on
`gutter` and `Theme.Typography.display` (`displayLarge` Fraunces 34 if
28 reads small), the scan sheets on `edgePadding` with
`PrimaryButtonStyle` buttons and `Palette.loss` errors,
`PackDetailView`'s duplicate name header, and the prefs sheets on
tokens.
