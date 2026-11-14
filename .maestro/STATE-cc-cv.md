# STATE cc-cv
Base: 6ecea66755cfa13519f30e0ca4461428045c7636  Branch: cc/casino-visible
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: CV4 tests repointed + report
- [x] CV1 where casino is hidden — facts
- [x] CV2 picker shows the always-on casino row
- [x] CV3 member renders include casino
- [ ] CV4 tests repointed + report

## CV3 DONE (commit "CV3: member renders include casino")

What CV3 changed:

- `GamesRoom/Models/NextNight.swift` now has one shared pure ordering rule,
  `NightPackOrder.casinoFirst(_:)`. It returns Casino first and removes any
  duplicate Casino slug while preserving the order of the remaining packs.
- `NextNightOffer.offer` calls that rule after its existing registered-pack
  filter. Its behaviour is unchanged: the one-tap next-night offer still
  contains Casino first and excludes retired packs (F4/S8 left alone).
- `BriefingSlot` in `GamesRoom/Views/RoomDetailView.swift` now reads the
  event's own `packSlugs`, applies the same shared ordering rule, resolves the
  registered pack display names, and renders them as one caption line under the
  venue: `Casino · Monopoly Deal`.
- The games line uses the existing caption typography and secondary text
  colour, with no icon, accent colour, badge, or other Casino-specific chrome.
  It appears on the shared briefing card used by the upcoming, claimed, and
  declined member states.
- No live-card, recap-card, room-settings, pack-store, pack-how-to, or other
  already-unfiltered surface was changed (S2/S3/S4/S6/S7 left alone). The
  only member-facing change is the briefing card's new games line.
- No static user-facing string or accessibility identifier was added or
  changed, so the screenshot sweep has no pack-label or option-count assertion
  to repoint.
- Verification: `bash .maestro/fastgate.sh` -> FASTGATE: PASS (630 cases,
  74/74 SwiftUI parse-checks); `bash .maestro/fastgate.sh --compile` ->
  FASTGATE: PASS (simulator-less iOS build succeeded).

CV4 is next: repoint/add the Foundation table tests required by design 4, pin
the new member-facing Casino-first list, and finish `REPORT-task-CV.md` with the
member before/after view. Add any new test file to both
`build-and-run-tests.sh` and `main.swift`, then run the gate and commit with
the exact message `CV4: tests repointed + report`.
