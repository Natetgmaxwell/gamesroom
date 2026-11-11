# STATE cc-cc-b
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/janitor-pg-cron  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/janitor-pg-cron
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: B3 write Supabase/tests/120_probes.sql (probes for the schema-replica harness)
- [x] B1 facts: extract signatures + client cadence into REPORT-task-B.md
- [x] B2 write the guarded pg_cron migration (landed as Supabase/migrations/120_stale_close_cron.sql)
- [ ] B3 write Supabase/tests/120_probes.sql
- [ ] B4 finish REPORT-task-B.md incl client removal plan

NOTE (B1): migration number 118 is TAKEN on this branch (Supabase/migrations/118_question_box_depth.sql; 119 also exists). Per Supabase/migrations/README.md rule 3 the next free number is 120. Brief's STOP-AND-REPORT item hit; filename decision needed before B2.
NOTE (B1): public.auto_close_stale_events(uuid) is PER-ROOM and its 115 member gate (current_user_id() null -> 42501) makes it uncallable from cron, so the wrapper must do the events update itself; public.close_stale_attestations() is GLOBAL and guard-free (one call).
NOTE (B2): no conductor ruling on 118-vs-120 arrived before B2, so the README rule decided it. Committed as Supabase/migrations/120_stale_close_cron.sql (commit 2647840, message exactly "B2: migration 118 stale-close cron" per the brief). Renumber recorded in REPORT-task-B.md §5.
NOTE (B2): the brief's probe path `supabase/probes/118-stale-close-probes.sql` does not match this repo — the convention is Supabase/tests/<NNN>_probes.sql (115_probes.sql, 119_probes.sql; 118_probes.sql existed on the question-box branch). B3 writes Supabase/tests/120_probes.sql, following the convention, and records the deviation in REPORT §5.
NOTE (B2): the brief's probe format is `select 'PROBE <id> ' || case when ... then 'PASS' else 'FAIL' end;`, but the two existing probe files (115_probes.sql, 119_probes.sql) use `raise notice 'PROBE <id> PASS|FAIL ...'` inside do-blocks instead, and the brief itself says "copy their exact style". B3 follows the EXISTING repo style (raise notice), which also matches how the harness output is consumed elsewhere in the repo. Probe ids: prefix 120.
NOTE (B2): no local postgres and no running docker daemon, so the SQL was not executed against a live or replica database in this lane. The probes (B3) are what a replica run will exercise.
