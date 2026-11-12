# Task AD: the night ends itself — derive-at-read autoclose (replaces the hourly janitor as correctness path)

## Why
Nathan reviewed the hourly janitor (migration 120 on this branch) and rejected the tick as the correctness path: the night must close at its true end time. The key fact: **the end time of a night is known the moment the night is booked** — `played_at + auto_close_hours`. An expired night's `settled_at` is derivable, so storing it and waiting for a writer is the compensation. This lane restructures UNAPPLIED migration 120 in place: reads derive an effective settle time; the cron demotes to a daily hygiene writer that nothing depends on.

## HARD RULES
- You are in your own worktree, on branch `cc/autoclose-derived` cut from cc/integration. Work ONLY here. Never touch ~/Projects/games-room (main checkout), other worktrees, the live Supabase DB, deploys, or Maestro/opencode config.
- Never merge, never push, never switch branches, never bump versions, never run a simulator.
- NEVER `git add` ghost duplicates (`* [0-9]*.*`). Always explicit paths.
- One step per iteration: read `.maestro/STATE-cc-ad.md`, do the next step, run the gate, commit with the given message, rewrite STATE, EXIT.
- Before every commit: `git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null; git status --porcelain | grep -E " [0-9]" && echo GHOST-DUP STOP`.
- GATE: `bash .maestro/fastgate.sh` — last line must read `FASTGATE: PASS`. Fix your change, never the gate.
- Read code with `grep -n` + ~60 lines context; never whole files.
- New/changed `.swift` files must be registered in BOTH `build-and-run-tests.sh` (SRC list) and `main.swift` (runner calls) if they add tests.
- Progress = steps ticked / total. Only declare complete when STATE reads `ALL STEPS DONE`.

## The design (settled; do not re-litigate)
- Effective settle: `coalesce(settled_at, case when p_now >= played_at + make_interval(hours => coalesce(auto_close_hours, 8)) then played_at + that window end)`.
- `night_phase()`: use effective settle for the recap/past branches. Order stays none > upcoming > live > recap > past. `stranded` STAYS in the enum but becomes unreachable — keep the branch as a safety fallback, note it in the comment.
- `get_recent_settled_event` and the settled leg of `get_active_event` (`get_active_event__inner`): key recency on the effective settle and RETURN the effective value as `settled_at`, so the client renders unchanged. Keep every existing membership gate and the hidden-member filter exactly as they are.
- `cron_close_stale()`: keep the wrapper (it stamps physical `settled_at`), change the schedule from hourly-at-:17 to DAILY at 03:17 (`'17 3 * * *'`). Update its header comment: hygiene only, correctness no longer depends on it, nothing waits on it.
- Swift `NightPhaseResolver`: mirror the same effective-settle logic (find it with `grep -rn NightPhaseResolver GamesRoom/`), so the twins agree; keep the `stranded` case for compatibility. Add table tests with a pinned `now` (the SQL twin is IMMUTABLE with p_now — copy that discipline).

## Steps
1. FACTS: list every read consumer of `settled_at` in `Supabase/migrations/*.sql` (grep it; for each, note file:line and whether phase-recency semantics apply). Read: `night_phase` (115), `get_recent_settled_event`, `get_active_event__inner`, the current 120 (wrapper + schedule), and the Swift `NightPhaseResolver`. Write the facts to the top of `REPORT-task-AD.md`.
2. MIGRATION: `git rm Supabase/migrations/120_stale_close_cron.sql` and write `Supabase/migrations/120_night_ends_itself.sql` implementing the design above (function rewrites + daily schedule + header comment that states WHY: end time known at booking; stamp is hygiene). Keep the SECURITY DEFINER + revoke pattern and the pg_cron guard exactly as the old 120 had them.
3. PROBES: replace `Supabase/tests/120_probes.sql` with a new set in the same style (notice 'PROBE <id> PASS|FAIL'): (a) HEADLINE — a never-stamped night 8h01m past start reads as recap through `get_recent_settled_event` (as a room member) AND `night_phase` returns 'recap', with the returned `settled_at` = played_at + window, with NO janitor call executed; (b) a night 7h59m past start still reads live; (c) an upcoming night still reads upcoming; (d) a host-settled night keeps its real stamp and ordering; (e) `night_phase` returns 'past' for an expired night outside 24h; (f) the member gate on `get_recent_settled_event` still returns nothing to a non-member; (g) cron job absent without pg_cron, and the schedule string is daily when present; (h) `cron_close_stale` still stamps idempotently (reuse the old probe bodies where they still apply). Use `select 'PROBE ... ' || case ... end;` style and `set_config('request.jwt.claims', ...)` impersonation like the existing probe files.
4. SWIFT MIRROR + TESTS: apply the effective-settle logic to `NightPhaseResolver`; add/extend its table tests (pinned clock): stranded-becomes-recap at exactly played_at+window; recap-becomes-past at 24h; upcoming/live unaffected; host stamp respected. Register any new test file in both lists.
5. DOC + REPORT: update the Night phase section of `docs/STATE-MACHINES.md` (stranded now unreachable-by-design; effective settle is the rule; cron is hygiene at 03:17 daily). Finish `REPORT-task-AD.md`: what changed, the consumer list from step 1 with which ones changed and which were left alone and why.

Commit messages: `AD1: settled_at consumer facts`, `AD2: migration 120 rebuilt — night ends itself`, `AD3: probes — no-tick recap`, `AD4: Swift resolver mirror + tests`, `AD5: state-machines doc + report`.

## Allowed files
`Supabase/migrations/120_night_ends_itself.sql` (new; old 120 removed in the same commit), `Supabase/tests/120_probes.sql`, `GamesRoom/Services/NightPhaseResolver.swift` (or wherever the resolver lives — stay minimal), ONE new or extended Foundation test file for the resolver, `main.swift` / `build-and-run-tests.sh` (list lines only), `docs/STATE-MACHINES.md` (Night phase section only), `REPORT-task-AD.md`, `.maestro/STATE-cc-ad.md`.

## STOP AND REPORT (do not guess)
- A `settled_at` consumer whose semantics are NOT phase-recency (e.g. a report that must count only human-settled nights, an ORDER BY that would reorder results) — list it, leave it unchanged, flag it in the REPORT.
- An XCUITest / ScreenshotSweepTests seed asserts the `stranded` rendering (never edit UI tests — report; the orchestrator repoints them).
- `NightPhaseResolver` does not exist as a single type (logic inlined elsewhere) — report the sites instead of scattering the change.
- `get_active_event`'s settled leg cannot take the effective logic without touching a file outside the whitelist.
