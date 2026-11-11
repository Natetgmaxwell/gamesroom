# Task B: server-side stale-close (pg_cron) — replaces client lazy janitor writes

## Why
The app finalizes stale events/attestations as a side effect of a member OPENING a screen: RoomService.loadActiveEvent fires `auto_close_stale_events` and CasinoService.getMyOpenAttestations fires `close_stale_attestations`, each throttled to once per 60s by hand-rolled dictionaries. A room nobody opens never finalizes. The fix is a scheduled server job. Client-side cleanup happens in a LATER slice, after the cron is verified live — NOT in this lane.

## HARD RULES
- You are in your own worktree. Work ONLY here. Never touch ~/Projects/games-room (the main checkout), other worktrees, the live Supabase DB, deploys, or Maestro/opencode config or processes you did not start.
- Never merge, never push, never switch branches, never bump versions, never run a simulator.
- NEVER `git add` ghost duplicates (files whose names match `* [0-9]*.*`). Always `git add` explicit paths.
- One step per iteration: read `.maestro/STATE-cc-b.md`, do the next step, run the gate, commit with the given message, rewrite STATE, EXIT.
- Before every commit: `git checkout -- GamesRoom.xcodeproj/project.pbxproj 2>/dev/null; git status --porcelain | grep -E " [0-9]" && echo GHOST-DUP STOP`.
- GATE: `bash .maestro/fastgate.sh` — its last line must read `FASTGATE: PASS`. If it fails, fix YOUR change, never the gate script.
- Read code with `grep -n` plus ~60 lines of context around hits; never read whole files.
- Progress = ticked steps / total. Only declare the run complete when STATE reads `ALL STEPS DONE`.

## Steps
1. FACTS: grep `supabase/migrations` for `auto_close_stale_events` and `close_stale_attestations`. Record each function's exact signature, schema, and semantics (what it stamps, its guards, its return). Also grep `GamesRoom/Services/RoomService.swift` for `lastAutoCloseAt` (about 5 hits) and `GamesRoom/Services/CasinoService.swift` for `lastStaleCloseAt` to record the current client cadence. Write the findings at the top of `REPORT-task-B.md`.
2. MIGRATION: write `supabase/migrations/118_stale_close_cron.sql`:
   - `create or replace function public.cron_close_stale()` — SECURITY DEFINER — wraps the two existing functions for ALL eligible rooms: if a function is per-room, loop `select id from public.rooms`; if it already operates globally, call it once. End with `revoke all on function public.cron_close_stale() from public, anon, authenticated;` (repo rule: every SECURITY DEFINER function ends with that revoke; only the cron scheduler calls this one).
   - Guarded scheduling, so the migration applies cleanly even where pg_cron is off:
     ```sql
     do $$ begin
       if exists (select 1 from pg_extension where extname = 'pg_cron') then
         perform cron.unschedule('gr-stale-close');
         perform cron.schedule('gr-stale-close', '17 * * * *', 'select public.cron_close_stale()');
       else
         raise notice 'pg_cron not installed; gr-stale-close not scheduled';
       end if;
     end $$;
     ```
   - Header comment: what this replaces (the two client-side lazy calls), why the guard exists, and that live apply is Nathan-gated and NOT done in this lane.
3. PROBES: write `supabase/probes/118-stale-close-probes.sql` for the schema-replica harness: (a) the function exists AND `authenticated` cannot execute it (`has_function_privilege('authenticated', 'public.cron_close_stale()', 'EXECUTE')` = false); (b) called as postgres against a seeded stale event (played_at more than 24h past, unsettled) it stamps settled_at; (c) a second call changes nothing (idempotent); (d) no cron job is registered when pg_cron is absent (the harness stubs it). Format every check as `select 'PROBE <id> ' || case when <condition> then 'PASS' else 'FAIL' end;` — if probe files already exist under `supabase/probes/`, copy their exact style.
4. REPORT: finish `REPORT-task-B.md`: the facts from step 1, the wrapper design, why hourly at minute 17, and a "client removal plan" section listing the exact client blocks a LATER slice will delete (file + grep anchor each). Do not touch any Swift file.
5. Final iteration: gate, commit, set STATE to `ALL STEPS DONE`.

Commit messages, in order: `B1: janitor facts`, `B2: migration 118 stale-close cron`, `B3: probes 118`, `B4: report`.

## Allowed files
`supabase/migrations/118_stale_close_cron.sql`, `supabase/probes/118-stale-close-probes.sql`, `REPORT-task-B.md`, `.maestro/STATE-cc-b.md`. Nothing else.

## STOP AND REPORT (do not guess)
- `auto_close_stale_events` takes no room parameter AND is not global.
- Any `cron.schedule` already exists in the migration chain (pick a different job name and report).
- Migration number 118 is already taken on this branch.
- A probe you cannot express without the live DB.
