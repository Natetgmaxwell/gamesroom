# STATE cc-cv
Base: 6ecea66755cfa13519f30e0ca4461428045c7636  Branch: cc/casino-visible
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: CV2 picker shows the always-on casino row
- [x] CV1 where casino is hidden — facts
- [ ] CV2 picker shows the always-on casino row
- [ ] CV3 member renders include casino
- [ ] CV4 tests repointed + report

## CV1 DONE (commit "CV1: where casino is hidden — facts")

What CV1 established (full detail + line anchors in REPORT-task-CV.md):

- The brief's premise is HALF true. The host picker really does filter casino out
  (GamesRoom/Views/AddEventSheet.swift:245 — `availablePacks`), but no member-facing
  surface renders the night's packs AT ALL, so none of them filter casino. The
  member side is SILENT, not filtered.
- Exactly ONE filter hides casino from a human: F1, AddEventSheet.swift:245.
  Removing it is enough for the order: PackRegistry.defaultPacks already lists
  CasinoPack FIRST (PackRegistry.swift:43-47).
- The picker's SEED filter (AddEventSheet.swift:91-93) STAYS and still serves the
  dedupe: it keeps the tick state free of the always-on slug, so the row list and
  the tick state cannot disagree. save() (AddEventSheet.swift:284) stays EXACTLY as
  is — files casino first, dedupes.
- DOUBLE sites (already show casino, left alone, listed in the report):
  RoomSettingsSheet.swift:1198 "Packs" toggles, PackStoreView.swift:28 pack
  store, PackDetailView.swift how-to, NextNight.swift:84 next-night offer
  (casino already first), PackHowTo.swift:73 casino how-to content.
- The member gap: BriefingSlot (RoomDetailView.swift:2320 — the briefing view
  file IS RoomDetailView.swift; BriefingSlot is a private struct there) is the
  hero card every member sees before a night and shows name/date/venue/hosted-by
  + the host's free-text note, and NO pack name. The live card (liveCard:2014)
  and the recap card (recapCard:2099) are the same.
- Stale comments to rewrite in CV2: AddEventSheet.swift:69-71 ("the casino pack
  is not offered here") and :85-86 ("Chips are never listed here").
- Test surfaces: no Foundation test encodes "casino is absent from the picker",
  and the 19-screen sweep never opens the sheet's pack section nor asserts a
  pack name or an option count. Nothing to repoint; main.swift:148-151 and
  TestsNextNight.swift:137 already pin casino first. The new picker shape is
  UI-testable only — noted for the orchestrator's sweep.
- Flagged for the orchestrator: CV3 ADDS the night's games to the member card
  (there is no member-facing pack list to un-filter). If the intent was strictly
  "stop filtering where a filter exists", CV3 is a no-op and the lane reduces to
  CV2 + CV4. Reasoning + the proposed shape are in REPORT-task-CV.md §3/§4.2.
- Verification: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (630 cases,
  74/74 SwiftUI parse-checks). Docs only in this commit.
