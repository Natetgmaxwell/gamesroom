# Task CV: make Casino visible — in the picker and in what members see

## Why
Nathan, 2026-11-13: *"I'm thinking that we should list the casino games in the 'what are you playing' section when creating a new event. so it gives the members an idea into what's going to be played on the night."* Every night already IS a casino night (save() files `casino` first on every event, and the server/older builds read it as the headline slug) — but both the host's picker AND the member-facing renders filter it out, so nobody is told. This lane makes the existing truth visible. It changes NO scoring, NO save semantics, NO data model.

## HARD RULES
- You are in your own worktree, on branch `cc/casino-visible`. Work ONLY here. Never touch ~/Projects/games-room (main checkout), other worktrees, the live DB, deploys, or Maestro/opencode config.
- Never merge, never push, never switch branches, never bump versions, never run a simulator, NO migrations.
- NEVER `git add` ghost duplicates (`* [0-9]*.*`). Always explicit paths.
- One step per iteration: read `.maestro/STATE-cc-cv.md`, do the next step, run the gate, commit with the given message, rewrite STATE, EXIT.
- Before every commit: `git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null; git status --porcelain | grep -E " [0-9]" && echo GHOST-DUP STOP`.
- GATE: `bash .maestro/fastgate.sh` — last line must read `FASTGATE: PASS`.
- Read code with `grep -n` + ~60 lines context; never whole files.
- Progress = steps ticked / total. Only declare complete when STATE reads `ALL STEPS DONE`.

## Design (settled — do not re-litigate)
1. **Picker (AddEventSheet.swift):** Casino appears at the TOP of "What are you playing?" as a pre-ticked row the host cannot untick, with a short caption. Suggested caption: "Every night runs on casino chips". Use `CasinoPack.displayName` ("Casino") and its description as the row's secondary text if the other rows show descriptions. Keep `save()` EXACTLY as is (files casino first, dedupes) and DELETE the `availablePacks` casino filter and the `initialPackSlugs` casino filter ONLY IF the readonly-row approach makes them dead; if the filters still serve the dedupe, keep them and note why. The picker must not present an untickable choice as a choice.
2. **Member-facing renders:** find every place the night's pack names/labels are shown to members (anchors: `PackRegistry` uses in `GamesRoom/Models/NextNight.swift`, the room page event card in `RoomDetailView.swift`, the briefing slot, any "what's playing"/pack-name formatter). Where casino is filtered from display, stop filtering it: casino shows FIRST (it is the headline slug), styled like the other packs, no special chrome. If a render does NOT filter casino, leave it alone and note it.
3. **Comments that state the old rule** ("Chips are never listed", "the casino pack is not offered here", "so the casino pack is not offered") get rewritten to the new rule: casino is always on and now VISIBLE — the label informs, the save semantics never depended on the tick.
4. **Tests:** repoint any Foundation test or ScreenshotSweep assertion that encodes casino being absent from the picker or from member renders (repoint, never delete — the sweep rule). Add one table test pinning the new picker shape (casino present, first, readonly) and one pinning a member-facing pack list that includes casino first, if those surfaces are Foundation-testable; if a surface is only UI-testable, note it for the orchestrator's sweep.

## Steps
1. FACTS: list every site that filters or hides `casino`/`CasinoPack.slug` from display (grep `CasinoPack.slug`, `!= .*casino`, `chips` in GamesRoom/Views + Models + Packs) and every member-facing pack render. Write the list into `REPORT-task-CV.md`.
2. PICKER: implement the readonly pre-ticked Casino row per design 1 + update the stale comments.
3. RENDERS: implement design 2 across the sites found in step 1.
4. TESTS + REPORT: repoint/add per design 4; finish the report with a before/after of what a member now sees.

Commit messages: `CV1: where casino is hidden — facts`, `CV2: picker shows the always-on casino row`, `CV3: member renders include casino`, `CV4: tests repointed + report`.

## Allowed files
`GamesRoom/Views/AddEventSheet.swift`, the render files found in step 1 (expected: `GamesRoom/Views/RoomDetailView.swift`, `GamesRoom/Models/NextNight.swift`, briefing view file — name them in the report), ONE new or extended Foundation test file, `main.swift`/`build-and-run-tests.sh` (list lines only, if a new test file), `REPORT-task-CV.md`, `.maestro/STATE-cc-cv.md`. NO migrations, NO PackRegistry structural changes.

## STOP AND REPORT (do not guess)
- A render site where showing casino would DOUBLE it (already unfiltered) — leave it, list it.
- The picker row cannot be made readonly without restructuring the section — report the options instead of restructuring.
- A sweep test asserts the picker's option COUNT (not just contents) and cannot be repointed by one line.
- `initialPackSlugs` callers depend on the casino filter for correctness (not display) — quote the call site.
