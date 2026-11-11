# STATE cc-cc-b
Base: 7e7bf4b4a4e16c9b1893b3b440b8af3340b53ea6  Branch: cc/janitor-pg-cron  Worktree: /Users/nathanmaxwell/Projects/worktrees/cc/janitor-pg-cron
Rewrite this file after every step: tick the step, set NEXT to the following one. When all are ticked, replace the NEXT line with: ALL STEPS DONE
NEXT: B2 write supabase/migrations/118_stale_close_cron.sql (guarded pg_cron job)
- [x] B1 facts: extract signatures + client cadence into REPORT-task-B.md
- [ ] B2 write supabase/migrations/118_stale_close_cron.sql (guarded pg_cron job)
- [ ] B3 write supabase/probes/118-stale-close-probes.sql
- [ ] B4 finish REPORT-task-B.md incl client removal plan

NOTE (B1): migration number 118 is TAKEN on this branch (Supabase/migrations/118_question_box_depth.sql; 119 also exists). Per Supabase/migrations/README.md rule 3 the next free number is 120. Brief's STOP-AND-REPORT item hit; filename decision needed before B2.
NOTE (B1): public.auto_close_stale_events(uuid) is PER-ROOM and its 115 member gate (current_user_id() null -> 42501) makes it uncallable from cron, so the wrapper must do the events update itself; public.close_stale_attestations() is GLOBAL and guard-free (one call).
