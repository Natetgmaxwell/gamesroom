# STATE S2B

STATE: step 6 of 7 done. Next: step 7 (rollout doc + report), the LAST step: `docs/S2B_SERVER_PUSH.md`, run all gates including `bash .maestro/fastgate.sh --compile`, write `.maestro/S2B_REPORT.md`, commit `S2B.7: rollout doc + report`. Only end the goal when STATE reads ALL STEPS DONE.

Step 6 (S2B.6: active-only events RLS; mascot voice reads what the UI renders)
committed as af3b7f7.
- Supabase/migrations/112_events_rls_active.sql (new). Not applied to live.
- Supabase/functions/mascot-voice/index.ts rewritten to delegate its
  decisions to a new pure state.ts; state_test.ts covers it (25 tests).

The SQL (112), four policies dropped and recreated, nothing else touched
- "members can read events" (select): the 090 shape plus
  `m.membership_status = 'active'`. The hidden-from check is kept
  exactly as it was. A kicked member reads no events.
- "host can insert events" (insert), "host can update events"
  (update), "host can delete events" (delete): all three moved from
  `rooms.created_by` to
  `public.is_room_host(events.room_id, public.current_user_id())`.
- THE BRIEF LEFT OPEN whether INSERT moves too. It moved, and the
  reasoning is written in the migration header: the insert policy keyed
  on the same rooms.created_by and had the same defect (a promoted host
  can create a night through add_event, which already accepts
  is_room_host, but the table policy would refuse them). Two guards
  that disagree is what 095/106 exist to stop. All four policies now
  agree with the RPCs.
- No table/column/grant/index changes. The kicked member was already
  blocked by the back door (093's own policies hide their membership
  row, and the read policy's exists() runs with caller permissions);
  112 makes the events policy say what it means on its own.

mascot-voice (audit 04 F5 / F8)
- state.ts is pure: no env, no fetch, no DB. The decisions and their
  unit tests live there; index.ts only reads rows and calls it.
- Event: if the client passes `event_id`, that event is used, but if
  the caller is on its hidden_from_user_ids the voice says nothing
  about it (treated as no event). Without an event id, the room's NEXT
  UNPLAYED night is used, earliest first (the live
  `get_active_event__inner` rule), plus the hidden-from filter the
  live body lacks. The old footer path picked the latest event by
  `played_at DESC, any state`; that is gone.
  Consequence TARS should know: a room whose NEXT night is not yet
  created gets "Room has no events yet. Welcome the members." even
  when it has settled history. The between-nights and recap lines
  still fire when the client passes the settled event's id, which is
  what the footer does on a settled night. The model can no longer be
  handed a stale event and told to write claim nudges for it.
- Season: `seasonCloseContext` fires the eulogy only when the NEWEST
  season by ordinal is ended (a room between seasons), or the newest
  ended season closed within the last three days. The old
  "any ended season in the top two" kept the eulogy forever after the
  first close (F5b).
- Roster (F8): three filters, all active-only now -
  1. the membership gate itself rejects a non-active caller
     (not_a_member, 403), because a kicked member gets no voice;
  2. the leaderboard / leader / margin / caller rank query filters
     `.eq('membership_status', 'active')` and the facts come from
     state.ts's `leaderFacts`;
  3. the member headcount counts active rows only.
- Extra deno gate for this lane: `deno check` clean and `deno test`
  25 passed / 0 failed on mascot-voice; the other three function
  directories re-ran clean (briefing-push 31, anchor-nudge-push 22,
  question-turn-push 10).

Two deliberate choices, for TARS
  1. The `jsr:@supabase/supabase-js@2` import in mascot-voice/index.ts
     was rewritten to `https://esm.sh/@supabase/supabase-js@2`, the
     import the other three function dirs already use. Without it deno
     check fails on this machine's empty npm cache (recorded last
     iteration as a pre-existing failure). One-line, no behaviour
     change, in an ALLOWED file.
  2. One test in state_test.ts (uncommitted, no previous version
     weakened) expected "about 2 days" for a night 2 days + 30 minutes
     ahead; `Math.ceil` gives 3, as production always has. The test
     fixture was moved to exactly +2 days (2026-11-10T09:00:00Z) and
     renamed; the production arithmetic was not touched.

Gates
- bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases, parse-check
  pass=64).
- deno check on all four function dirs this lane owns: clean. deno
  test: briefing-push 31, anchor-nudge-push 22, question-turn-push 10,
  mascot-voice 25, all 0 failed.
- 112 parsed with pglast (14 statements) and the structural
  check112.py from the Working folder: ALL CHECKS OK (drop/create set
  exact, fragments present, no created_by anywhere in the SQL, begin/
  commit closed). pglast was not installed on this python; it was
  pip-installed into /Users/nathanmaxwell/Projects/games-room/.maestro/
  playbooks/Working/pylib (the lane's temp folder), not the system.
- Migrations written, never applied. No supabase db push/query/link.

Gotchas for step 7 (LAST step: rollout doc + report)
- The doc is docs/S2B_SERVER_PUSH.md (new, ALLOWED). Required
  contents per the brief: apply order 108-112; secrets BY NAME only
  (BRIEFING_PUSH_ENABLED, the shared secret, APNs vars reused);
  deploy commands with --no-verify-jwt; verify via an unauthenticated
  probe expecting 401; and the dedupe plan (once server push is on,
  the client stops scheduling local t168h/t48h/morning_of; TARS wires
  that flag at integration).
- Commit message exactly: `S2B.7: rollout doc + report`. Use
  `bash .maestro/fastgate.sh --compile` for the LAST step's gate.
- Write `.maestro/S2B_REPORT.md` summarising the lane, then tick step
  7 in the brief, set STATE to ALL STEPS DONE, and commit the notes.
- For the secrets section: 109 schedules 'briefing-push-tick' via
  cron.schedule/pg_net with the vault shared secret exactly like 097;
  110 mirrors 105. The edge functions gate on the shared-secret
  header and fail closed with 401; briefing-push additionally does
  nothing unless env BRIEFING_PUSH_ENABLED === "true".
- Git path gotchas are recorded two iterations down; the ones that
  mattered (lowercase supabase paths for 103/105) do not affect new
  files, which add under Supabase/ normally.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
