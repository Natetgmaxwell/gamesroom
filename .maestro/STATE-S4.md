# STATE S4

STATE: step 2 of 9 done. Next: step 3.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S4.md (tick the checkbox there too).

## Step 2 notes (S4.2: one primary button, commit 2db641a)

PrimaryButtonStyle now drives every primary site (styling only, no logic or string changes):
- `RoomDetailView.swift` — Claim seat, "I'm here. Reclaim", Re-accept, live CTA and its `.done`
  passive state (capsule -> `buttonRadius` rounded rect, `buttonVertical` padding, so the
  claimed -> live flip no longer jumps corner shape), "Add an event" (now full width via the
  style's `frame(maxWidth: .infinity)`).
- `RoomPage.swift` — Rooms "Resume" (NavigationLink keeps its `value:` and tap gesture; the
  style fixes the old `primaryText`-on-accent label colour) and the empty-state CTA (keeps its
  320pt cap, now via `.frame(maxWidth: 320)` on the button).
- `QuestionBoxViews.swift` — reader card "Done" (Pass stays as-is until step 3).
- `ChipScanSheet.swift` / `CAHCardScanSheet.swift` — "Scan chips" / "Scan cards" now use the
  shared geometry (semibold body, `Palette.background` on accent, radius 12, vertical 14).
- `Theme.swift` — `PrimaryButtonStyle` gained an `@Environment(\.isEnabled)` dim (0.4) so the
  disabled scan buttons still read as disabled now that the automatic button style is gone.

Gate: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (302 unit cases, parse-check 64/64).
Also type-checked the app sources with the iOS SDK: no errors in the changed files (only the
pre-existing "no such module 'Supabase'" import error, which needs the built package).
