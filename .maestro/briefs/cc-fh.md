# Task F+H: pin the store contract (InMemory vs Live) and the server boundary

## Why
InMemoryRoomStore.swift (about 2060 lines) hand-mirrors live RPC behaviour and drifts: a RoomService comment admits "InMemoryRoomStore mirrors the briefing on upsert but LiveRoomStore does not". RoomStore.swift also re-filters drowning award rows client-side even though RLS enforces it server-side ("defensively filter", 1 hit), and fetchCurrentSeason relies on a server-side ended-over-active preference documented as "a defensive fallback". This lane PINS current behaviour with tests and SQL probes and writes the divergence report. It changes NO store behaviour and deletes NO filter.

## HARD RULES
- You are in your own worktree. Work ONLY here. Never touch ~/Projects/games-room (the main checkout), other worktrees, the live Supabase DB, deploys, or Maestro/opencode config or processes you did not start.
- Never merge, never push, never switch branches, never bump versions, never run a simulator.
- NEVER `git add` ghost duplicates (files whose names match `* [0-9]*.*`). Always `git add` explicit paths.
- One step per iteration: read `.maestro/STATE-cc-fh.md`, do the next step, run the gate, commit with the given message, rewrite STATE, EXIT.
- Before every commit: `git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null; git status --porcelain | grep -E " [0-9]" && echo GHOST-DUP STOP`.
- GATE: `bash .maestro/fastgate.sh` — its last line must read `FASTGATE: PASS`. If it fails, fix YOUR change, never the gate script.
- Read code with `grep -n` plus ~60 lines of context around hits; never read whole files.
- New test files must be added to BOTH explicit lists: the SRC list in `build-and-run-tests.sh` AND the runner calls in `main.swift` at repo root.
- Progress = ticked steps / total. Only declare the run complete when STATE reads `ALL STEPS DONE`.

## Steps
1. INVENTORY: list every function both `GamesRoom/Services/InMemoryRoomStore.swift` and `GamesRoom/Services/RoomStore.swift` implement (grep `func ` in both; match by name). For each known suspect, read BOTH sides and record exact behaviour with file:line on each side: (a) RSVP upsert → briefing mirror (grep RoomService.swift for `InMemoryRoomStore mirrors`); (b) the auto_close mirror (grep InMemoryRoomStore for `auto_close`); (c) the drowning-rows filter (grep RoomStore for `defensively filter`); (d) the ended-over-active season preference (grep RoomStoreProtocol for `defensive fallback`). Start the divergence table in `REPORT-task-FH.md`.
2. CONTRACT SUITE: ONE new Foundation test file pinning InMemoryRoomStore's CURRENT behaviour for (a) through (d) plus any other divergence you found: seed, act, assert. These tests encode what the fake does TODAY; if a test's outcome contradicts its own doc comment, that is a finding for the report — never weaken the test. Register the file in `main.swift` and `build-and-run-tests.sh`.
3. RLS PROBES: write `supabase/probes/contract-rls-probes.sql` for the schema-replica harness, impersonating users with `select set_config('request.jwt.claims', json_build_object('sub','<uuid>','role','authenticated')::text, true)`: (a) `get_season_awards` returns `.drowning` rows ONLY to their recipient — a non-recipient sees none; (b) current-season resolution with BOTH an 'active' and an 'ended' season present returns the 'ended' one; (c) `auto_close_stale_events` is idempotent. Format every check as `select 'PROBE <id> ' || case when <condition> then 'PASS' else 'FAIL' end;`.
4. REPORT final: the divergence table (function | in-memory behaviour | live behaviour | file:line both sides | which side looks right | suggested fix), plus one paragraph recommending keep-vs-delete for the client drowning filter once the probes pass.
5. Final iteration: gate, commit, STATE reads `ALL STEPS DONE`.

Commit messages, in order: `F1: store divergence inventory`, `F2: in-memory contract suite`, `F3: rls probes`, `F4: report`.

## Allowed files
ONE new Foundation test file in the existing test location, `main.swift` (runner list lines only), `build-and-run-tests.sh` (SRC list lines only), `supabase/probes/contract-rls-probes.sql`, `REPORT-task-FH.md`, `.maestro/STATE-cc-fh.md`.

## STOP AND REPORT (do not guess)
- The Foundation runner cannot construct InMemoryRoomStore (it should already be in the SRC list; if not, report).
- A divergence you cannot classify without querying the live DB.
- `get_season_awards` does not exist on this branch or has a different name.
