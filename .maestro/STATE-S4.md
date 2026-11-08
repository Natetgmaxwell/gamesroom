# STATE S4

STATE: step 3 of 9 done. Next: step 4.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 3 notes (S4.3: one secondary-action style, commit 90bc279)

One secondary style now: a centred grey caption, no chrome, no chevron
(audit #4). Styling only, no logic, string or order changes.

- `Theme.swift` — unchanged. `SecondaryTextAction` (caption, `Palette.secondaryText`,
  centred, `frame(maxWidth: .infinity, minHeight: 44)`, `.plain`) was already in
  place from step 1 and is now the app's only secondary look.
- `RoomDetailView.swift`
  - `TrailingTextAction` now renders `SecondaryTextAction` (was: body font, 0.7,
    trailing-aligned, chevron). Its two call sites ("Release my seat", "Re-decline")
    are untouched, so the claimed card's secondary no longer sits at the card's
    right edge while the unclaimed card centres the same verb.
  - Live card extras "Withdraw more", "Count your CAH cards" and "Score a round"
    are now `SecondaryTextAction`: the accent-outlined boxes are gone, so the three
    stacked extras stop competing with the primary. "Score a round" lost its
    decorative `checkmarkSealFill` seal with the box (the button, its title and
    the `(host)` accessibility label are unchanged).
  - "Make a call": the standalone copy (no Tonight's Star to sit beside) is now
    `SecondaryTextAction` on its own row, so it no longer hangs off the right edge;
    the copy that rides the Tonight's Star label row keeps its row but loses the
    chevron and takes the grey caption. The `make-a-call` identifier stays on both.
  - Member-note "Skip": grey caption via `Palette.secondaryText` (was 0.7), no
    chrome. It stays inline beside the small Send - a full-width secondary would
    sit half a card away from the button it answers.
- `QuestionBoxViews.swift` — reader card "Pass" is now `SecondaryTextAction`: the
  hairline outlined box beside the Done primary is gone.
- `RoomPage.swift` — empty Rooms "Ask a friend for a join code" is now
  `SecondaryTextAction`, keeping the empty state's 320pt cap so both onboarding
  paths share one measure.

Left alone: "Can't make it" (the unclaimed card's secondary) already is caption /
0.55 / centred - the rule's reference implementation. Its literal 0.55 becomes
`Palette.secondaryText` in step 8.

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases, parse-check 64/64).
Also type-checked the whole app source tree against the iOS 26 simulator SDK with
the cached Supabase module (`swiftc -typecheck`): 0 errors, only pre-existing
warnings. Verified the check is real by planting a deliberate type error in
`QuestionBoxViews.swift` (caught, then reverted).
