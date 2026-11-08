# STATE S4

STATE: step 5 of 9 done. Next: step 6.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 5 notes (S4.5: list text shares one leading edge, commit 3ece3d8)

Shared left edges (#5, #14, #23, #29). Styling only: no logic, string,
condition, view-order or file-structure changes. The rule now applied
everywhere on the room page and the settings screens: an icon/rank column
of `Theme.Layout.rowIconWidth` (28) followed by a `Theme.Layout.cardInset`
(16) gap, so every name in an icon-bearing row starts at x=44 from its
card's inner edge.

- `Components/LeaderboardRow.swift` (#5) — the standings row's HStack gap
  was a literal 12 and the rank column a literal 24 wide, putting the
  name at x=36. Now `HStack(spacing: Theme.Layout.cardInset)` and
  `.frame(width: Theme.Layout.rowIconWidth, alignment: .leading)` on the
  rank badge: the name starts at 44, matching Packs and Members.
- `RoomDetailView.swift`
  - `packRow` (:3639) — `HStack(spacing: Theme.Layout.gutter)` (32) plus
    a 32pt icon put the pack name at x=64, twice the standings name.
    Now `cardInset` + `rowIconWidth`: x=44.
  - `memberRow` (:4181) — same change; the monogram avatar was a 32x32
    circle and is now `rowIconWidth` square (28), so the roster names
    land on the same 44 as the standings.
  - `AwardRow` (:3266) (#29) — the award icon had no fixed width, so
    "Felty" (flame) and "Borat" (cluster) started at different x. The
    icon now sits in a `rowIconWidth` column and the row's HStack gap is
    `cardInset`, so both names start at 44.
  - Awards card divider (:3170) (#29) — the hairline between award rows
    now starts under the row text
    (`.padding(.leading, rowIconWidth + cardInset)`), so the rule and
    the names share a left edge instead of the rule starting at the
    card's inner edge.
- `Components/DrowningBadge.swift` (#23, #29) — the drowning row is a
  sibling of `AwardRow` inside the same awards list, so it had to move
  with it or the list would have two left edges: the icon gets the
  `rowIconWidth` column, the HStack gap becomes `cardInset`, and the
  opt-in toggle and viewer footnote indent from the magic 28 to
  `rowIconWidth + cardInset` (44) so they still sit under the row text.
- `RoomSettingsSheet.swift` (#23) — both settings rows (the "My
  calendar" trigger at :349 and `settingsRow(icon:title:detail:)` at
  :607) drop `Theme.Layout.gutter` for `Theme.Layout.cardInset`, and
  their icon frames become `rowIconWidth` instead of a literal 28. The
  trailing "···" menu (:1372) narrows from a literal 32 to
  `rowIconWidth`; because the glyph is trailing-aligned inside that
  frame it does not move, only the invisible leading strip of the frame
  is 4pt narrower.
- `PackStoreView.swift` (#23) — the store row had the same 32pt icon and
  `gutter` gap as the room page's pack shelf; it now uses
  `rowIconWidth` + `cardInset`, so the store and the shelf agree.
- `RoomPage.swift` (#14) — the Rooms list row and the iPad sidebar row
  now always reserve the live-dot column: the `if active { Circle() }`
  became one circle whose fill is the accent when the room is live and
  `Color.clear` when it is not, so a room name no longer jumps right
  when the room goes live. The row gap is `Theme.Layout.cardLineGap * 2`
  (8) instead of `gutter` (32), so the dot sits 8pt from the name
  instead of floating. The dot keeps its "Active session" accessibility
  label when the room is live and is `accessibilityHidden` when it is
  not, so VoiceOver does not announce a live session for an idle room.

Residual, deliberately left alone (outside this step's list): the room
page's rows that have no icon column — round history, notes and the
season comparison rows — still start at their container's left edge
(x=0 relative to the card), so the page still shows two leading edges
(0 for those, 44 for icon-bearing rows). The audit's #5 fix only asks
for the icon gap to change; indenting the icon-less rows would be a
larger visual move than the brief sanctions. Noted here for the S4
report.

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases,
parse-check 64/64). Also type-checked the whole app source tree against
the iOS 27 simulator SDK with the cached Supabase module
(`swiftc -typecheck`, deployment target 26.0): 0 errors. Verified the
check is real by planting a deliberate type error in
`LeaderboardRow.swift` (caught: "cannot convert value of type 'String' to
specified type 'Int'", then reverted).

Next iteration is step 6 only: rhythm (#6, #8-#13, #15-#18) —
AwardsCard VStack to `cardGroupGap` with inner `cardLineGap`, delete
the four `.padding(.top, 4)` bumps; the five headers onto `SectionTitle`;
claimed-card caption+button grouped with `cardLineGap`; member-note
prompt and declined state onto `cardGroupGap` with the field inset
`Theme.Layout.fieldInset` and Send as a `PrimaryButtonStyle`;
SystemBanner rows onto `roomRowInset` with `cardLineGap`/`cardInset`;
inner 2/3/6 gaps to `cardLineGap`; LeaderboardRow sparkline pad to
`cardLineGap`; Rooms page onto `roomSectionGap`/`roomHeaderGap`/
`roomRowInset` with `SectionTitle` instead of `sectionHeader`.
