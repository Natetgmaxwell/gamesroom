# STATE cc-cv
Base: 6ecea66755cfa13519f30e0ca4461428045c7636  Branch: cc/casino-visible
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: CV3 member renders include casino
- [x] CV1 where casino is hidden — facts
- [x] CV2 picker shows the always-on casino row
- [ ] CV3 member renders include casino
- [ ] CV4 tests repointed + report

## CV2 DONE (commit "CV2: picker shows the always-on casino row")

What CV2 changed (all in GamesRoom/Views/AddEventSheet.swift; detail + before/after in
REPORT-task-CV.md §8):

- F1 DELETED: `availablePacks` is now `PackRegistry.shared.allPacks.map { … }` — no
  `.filter { $0.slug != CasinoPack.slug }`. The catalog is the registry again, and the
  "casino first" row order is inherited from `PackRegistry.defaultPacks` (F5), not from
  a sort added here. One source of truth for the order.
- The casino row is a READONLY `HStack` (`alwaysOnPackRow`), not a `Button`: there is
  nothing to tap, so it cannot be unticked. It renders "Casino" (CasinoPack.displayName)
  + the caption "Every night runs on casino chips" in Theme.Typography.caption /
  Palette.secondaryText + a pre-ticked accent checkmark. The picker no longer presents
  an untickable thing as a choice.
- `togglePack` guarded: `guard slug != CasinoPack.slug else { return }` — the always-on
  slug can never enter (or leave) the tick set, even if called from elsewhere.
- F2 (the `initialPackSlugs` seed filter, :91-93) KEPT, as the brief allows: it is the
  dedupe guard, not a display filter. It keeps the tick state free of the always-on slug
  so the rows and the tick state cannot disagree. Reason recorded in the report (§4.1/§8).
- `save()` (:284) UNTOUCHED: still `[CasinoPack.slug] + packSlugs.filter { $0 != … }` —
  files casino first, dedupes. No change to scoring, save semantics or the data model.
- Stale comments rewritten (:68-72 the packSlugs doc, :84-87 the init doc, plus the seed
  filter and `availablePacks`): the old "the casino pack is not offered here" / "Chips are
  never listed here" now say casino is always on and VISIBLE — the label informs, the save
  semantics never depended on the tick.
- `PackOption` was NOT extended with a description: the other rows show no description
  (slug + displayName only), so the brief's conditional "use its description as the row's
  secondary text if the other rows show descriptions" does not fire. The caption is the
  secondary line instead.
- No new/changed user-facing string collided with a sweep assertion: the sweep never
  opens the new-event sheet's pack section and never asserts a pack name or an option
  count (grepped GamesRoomUITests/ for "What are you playing" / "Play anything" — no hits).
- Verification: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (630 cases, 74/74 SwiftUI
  parse-checks); also `--compile` -> FASTGATE: PASS (xcodebuild BUILD SUCCEEDED, no
  type errors in the new ViewBuilder code).

CV3 is next and it is NOT an un-filtering job: no member-facing surface renders the
night's packs at all (CV1 §3), so CV3 ADDS the night's games to the member event card
(the briefing slot — BriefingSlot, a `private struct` inside RoomDetailView.swift:2320)
with casino first, styled like any other pack, no special chrome. The proposed shape is
REPORT-task-CV.md §4.2; the shared pure "casino first" rule is proposed in §4.3 (NextNight.swift
already owns that rule in `NextNightOffer.offer`). F4/S2/S3/S8 are already unfiltered —
leave them alone.
