# STATE S4

STATE: step 4 of 9 done. Next: step 5.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 4 notes (S4.4: one card chrome; ArrivalCard single inset, commit 0eacf31)

One card shape (#1, #2, #20). Styling only: no logic, string, condition or
view-order changes. Every card on the room page is now a `sectionCard`:
radius `cardRadius` (12), 0.5pt hairline, surface or hero fill.

- `RoomDetailView.swift`
  - `BriefingSlot` (:2053) — its own chrome (`.padding(cardInset)` plus a
    radius-14 / 1pt-stroke `RoundedRectangle` fill) is gone, replaced by
    `.sectionCard(isHero ? .hero : .standard)`. Same fill logic (hero =
    accent 10% wash, standard = surface); only the radius (14 -> 12), the
    stroke (1 -> 0.5) and the clip change, so the most prominent card on
    the page no longer has the heaviest outline.
  - `WitnessSlot` (:2631) — the identical change on the live card. Both
    slots previously drew chrome that did not match `sectionCard`, so the
    room page had two card shapes on one screen.
- `ArrivalCard.swift` (#1, the double-inset bug that survived fb2cd19)
  - The row's `.padding(Theme.Layout.cardInset)` (:133) is deleted. The
    caller already wraps the card in `.sectionCard(.standard)`, which
    insets by 16, so the host's arrival text sat 32pt in from the card
    edge while every other card sits at 16.
  - The inner bordered box (`surface` fill + 0.5pt rounded stroke +
    `clipShape`) is dropped: the rows now sit on the card's own surface
    with a `Divider()` between them, like `StandingsSection` does.
  - Header is now `SectionTitle(text: "Arrivals")` — the title-size
    icon+text heading is gone, so the card reads with the same hierarchy
    as every other section header. The grey explainer ("Held deposits
    waiting on a check-in. You decide what comes back.") is no longer
    printed on the card: it is the header's `accessibilityHint`, so
    VoiceOver hosts still get the line.
  - Spacing on tokens: card body `cardInset` -> `cardGroupGap`, candidate
    row `8` -> `cardGroupGap` (text block to its action row), button row
    `8` -> `cardLineGap` (peer buttons), exactly as finding #1's Fix says.
  - The Forfeit / Skip: texted / Skip: away buttons are untouched: their
    copy, order and per-candidate actions are the card's logic, not
    styling. `Theme.Icon.handRaisedFill` is now unused by the app but is
    left in Theme.swift (a token, not a literal).
- `QuestionBoxViews.swift` (#20) — `HostQuestionFallback` is a
  `.sectionCard(.standard)` now, not a hand-rolled 1pt-stroke box; the
  two `spacing: 6` become `cardLineGap`. The `host-question-fallback`
  identifier and the inner identifiers are unchanged, so
  `GamesRoomUITests/QuestionBoxAcceptanceTests.swift` still finds the
  button.

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases,
parse-check 64/64). Also type-checked the whole app source tree against
the iOS 27 simulator SDK with the cached Supabase module
(`swiftc -typecheck`): 0 errors, only pre-existing warnings. Verified the
check is real by planting a deliberate type error in `ArrivalCard.swift`
(caught: "missing argument label 'text:'", then reverted).

Next iteration is step 5 only: shared left edges (#5, #14, #23, #29) —
icon/rank columns `frame(width: Theme.Layout.rowIconWidth)` with
`HStack(spacing: Theme.Layout.cardInset)` in standings, pack shelf,
members, award rows, settings rows; the Rooms list always reserves the
live-dot column. `Theme.Layout.rowIconWidth` (28) already exists from
step 1.
