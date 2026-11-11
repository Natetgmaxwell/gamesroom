-- 120: The janitor runs on a clock, not on a screen.
--
-- Lane: Task B (server-side stale close). Replaces the two lazy
-- client-side finalizers with a scheduled server job.
--
-- What this replaces
--   1. RoomService.loadActiveEvent (GamesRoom/Services/RoomService.swift:482)
--      fired public.auto_close_stale_events(p_room_id) — at most once per
--      60s per room — as a side effect of a member OPENING that room.
--   2. CasinoService.getMyOpenAttestations (GamesRoom/Services/CasinoService.swift:382)
--      fired public.close_stale_attestations() — at most once per 60s for
--      the whole app — as a side effect of a member opening the casino.
--
--   Both were finalizers with a read attached. A room nobody opens never
--   finalizes, so a night nobody returns to stays 'stranded' forever and
--   an attestation nobody looks at stays open past 24h. This lane moves
--   the finalizer onto the server clock. The CLIENT cleanup happens in a
--   LATER slice, after this job is verified live.
--
-- What this migration adds
--   1. public.cron_close_stale() — SECURITY DEFINER, callable by no app
--      role. It settles stranded nights for every live room and closes
--      the attestations that have been open more than 24h.
--   2. cron job 'gr-stale-close', hourly at minute 17.
--
-- Why the wrapper does the events write ITSELF
--   public.auto_close_stale_events(p_room_id) is per-room AND member
--   gated: it reads public.current_user_id() (the JWT 'sub') and raises
--   42501 when there is none, and raises 42501 unless the caller is a
--   member of that room (migration 115:787-807). A pg_cron session runs
--   as postgres with no JWT in request.jwt.claims, so current_user_id()
--   is NULL and the call raises before a single row is touched. The
--   wrapper therefore performs the same UPDATE itself, once per room,
--   stamping the same value: settled_at = played_at + the room's
--   auto_close_hours (the moment the night stopped being live), never
--   now(). Same shape as public.question_box_cron_tick (migration
--   097:820), which also does its own write rather than calling a
--   client-facing RPC.
--
--   public.close_stale_attestations() is global and guard-free, so the
--   wrapper calls it exactly once.
--
-- Which rooms are eligible
--   Only live rooms (rooms.deleted_at is null). A soft-deleted room is
--   out of get_my_rooms, so the lazy client path never reached it
--   either; the scheduled sweep therefore covers the same rows the
--   replacement covers. Same filter as question_box_cron_tick (097:833).
--
-- Why the schedule is guarded
--   pg_cron is not present everywhere — a fresh local postgres has no
--   pg_cron, and the schema-replica harness stubs it out. The schedule
--   block checks pg_extension first and registers the job only when
--   pg_cron is there, so this migration applies cleanly anywhere; with
--   the extension absent the function still exists and can be run by
--   hand. The job is replaced rather than duplicated: the unschedule
--   runs first, by job name, the way migrations 097/109/110 do it.
--
-- Live apply is Nathan-gated and is NOT done in this lane. This file and
--   its probes are written and committed; nothing here has been applied
--   to the live database.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/120_stale_close_cron.sql
--
-- Numbering note: the brief named 118_stale_close_cron.sql. 118 is
--   already taken on this branch (118_question_box_depth.sql, with 119
--   after it) and Supabase/migrations/README.md rule 3 says to take the
--   highest existing number and increment, so this file is 120.

begin;

-- =================================================================
-- 1. The wrapper. Cron-only.
-- =================================================================
create or replace function public.cron_close_stale()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_room record;
  v_n integer := 0;
  v_closed integer := 0;
begin
  -- Events: the body of public.auto_close_stale_events(p_room_id)
  -- (migration 115), minus the member gate it cannot pass from a cron
  -- session, applied to every live room. The stamp is the moment the
  -- night stopped being live, so a long-stranded night reads 'past'
  -- rather than a recap settled a second ago.
  for v_room in
    select r.id, r.auto_close_hours
      from public.rooms r
     where r.deleted_at is null
  loop
    update public.events e
       set settled_at = e.played_at + make_interval(hours => v_room.auto_close_hours)
      where e.room_id = v_room.id
        and e.settled_at is null
        and e.played_at < now() - make_interval(hours => v_room.auto_close_hours);
    get diagnostics v_n = row_count;
    v_closed := v_closed + v_n;
  end loop;

  -- Attestations: global and guard-free — one call, not one per room.
  v_closed := v_closed + public.close_stale_attestations();

  return v_closed;
end;
$$;

revoke all on function public.cron_close_stale() from public, anon, authenticated;

comment on function public.cron_close_stale() is
  'Task B: the server-side janitor. Settles stranded nights for every live room (settled_at = played_at + the room''s auto_close_hours, the same stamp as auto_close_stale_events) and closes attestations open more than 24h (one global close_stale_attestations call). Called by the pg_cron job ''gr-stale-close'' only — no app role may execute it. Idempotent: a second run closes nothing.';

-- =================================================================
-- 2. The cron job (guarded: pg_cron may not be installed).
-- =================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gr-stale-close';
    perform cron.schedule('gr-stale-close', '17 * * * *', 'select public.cron_close_stale();');
  else
    raise notice '120: pg_cron not installed; gr-stale-close not scheduled. The client-side lazy close still finalizes; run public.cron_close_stale() by hand.';
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
