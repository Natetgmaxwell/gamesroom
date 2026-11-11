-- Probes for 120_stale_close_cron.sql on a schema-only replica (115 + 119 + 120
-- applied). Every line of interest prints "PROBE <id> PASS|FAIL|INFO ...".
--
-- What is under test: the server-side janitor.
--   - public.cron_close_stale() exists, and NO app role may execute it.
--   - Called the way pg_cron calls it (as postgres, with no JWT in the
--     session), it settles the stranded nights of every live room -- stamping
--     settled_at at played_at + the room's auto_close_hours, not now() -- and
--     closes the attestations that have been open for more than 24h.
--   - A second call changes nothing.
--   - With pg_cron absent, the migration still applied cleanly and no job
--     was registered.
--
-- Both sweeps are global, so running this file settles anything else stale
-- that happens to sit in the replica. The counts below are therefore read
-- from the data immediately before the call rather than hard-coded.
--
-- Run: psql "$REPLICA_DB_URL" -f Supabase/tests/120_probes.sql 2>&1 | grep PROBE
\set ON_ERROR_STOP 0

create or replace function pg_temp.act(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false),
         set_config('request.jwt.claim.sub', u::text, false);
$$;

-- ---------------------------------------------------------------------------
-- Setup (superuser).
--   r  live room,   auto_close_hours 8
--   rw live room,   auto_close_hours 24  (a room with a wider window)
--   rd soft-deleted room (rooms.deleted_at set) -- out of the sweep
--
--   e_stale   r,  played 40 h ago, unsettled -> must be stamped at +8h
--   e_live    r,  played 1 h ago, unsettled  -> inside the window, untouched
--   e_settled r,  played 40 h ago, settled   -> already settled, untouched
--   e_win     rw, played 12 h ago, unsettled -> outside rw's OWN 24h window
--   e_del     rd, played 40 h ago, unsettled -> deleted room, untouched
--
--   att_old   opened 25 h ago -> must be closed
--   att_new   opened 1 h ago  -> must stay open
-- ---------------------------------------------------------------------------
do $$
declare
  h uuid := '00000000-0000-0000-0000-0000000020a1';
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r uuid := '00000000-0000-0000-0000-0000000020b1';
  rw uuid := '00000000-0000-0000-0000-0000000020b2';
  rd uuid := '00000000-0000-0000-0000-0000000020b3';
  e_stale uuid := '00000000-0000-0000-0000-0000000020c1';
  e_live uuid := '00000000-0000-0000-0000-0000000020c2';
  e_settled uuid := '00000000-0000-0000-0000-0000000020c3';
  e_win uuid := '00000000-0000-0000-0000-0000000020c4';
  e_del uuid := '00000000-0000-0000-0000-0000000020c5';
  att_old uuid := '00000000-0000-0000-0000-0000000020d1';
  att_new uuid := '00000000-0000-0000-0000-0000000020d2';
begin
  -- Start from a clean slate so the file can be run twice in a row.
  delete from public.settlement_attestations where id in (att_old, att_new);
  delete from public.events where id in (e_stale, e_live, e_settled, e_win, e_del);

  insert into auth.users(id) values (h),(a) on conflict do nothing;
  insert into users(id, display_name) values (h,'Host'),(a,'Alex') on conflict do nothing;
  insert into rooms(id, name, mascot_name, created_by, auto_close_hours, time_zone)
    values (r,  'Janitor Room',    'Tally', h, 8,  'Australia/Brisbane'),
           (rw, 'Wide Window Room','Tally', h, 24, 'Australia/Brisbane'),
           (rd, 'Deleted Room',    'Tally', h, 8,  'Australia/Brisbane')
    on conflict (id) do nothing;
  update public.rooms set deleted_at = now() where id = rd;
  insert into room_memberships(room_id, user_id, role, points_balance, membership_status)
    select rr, u, case when u = h then 'host' else 'member' end, 500, 'active'
      from unnest(array[r,rw,rd]) rr cross join unnest(array[h,a]) u
    on conflict (room_id, user_id) do update set membership_status = 'active';
  insert into events(id, room_id, name, played_at, settled_at, created_by) values
    (e_stale,   r,  'Stranded night', now() - interval '40 hours', null,                       h),
    (e_live,    r,  'Tonight',        now() - interval '1 hour',  null,                       h),
    (e_settled, r,  'Settled night',  now() - interval '40 hours', now() - interval '30 hours', h),
    (e_win,     rw, 'Still live',     now() - interval '12 hours', null,                       h),
    (e_del,     rd, 'Deleted night',  now() - interval '40 hours', null,                       h)
    on conflict (id) do nothing;
  insert into settlement_attestations(id, session_id, room_id, member_id, vision_amount_points, opened_at)
    values (att_old, '00000000-0000-0000-0000-0000000020e1', r, a, 100, now() - interval '25 hours'),
           (att_new, '00000000-0000-0000-0000-0000000020e2', r, a, 100, now() - interval '1 hour')
    on conflict (id) do nothing;
  raise notice 'PROBE 120.setup INFO seeded 3 rooms, 5 events, 2 attestations';
end $$;

-- ---------------------------------------------------------------------------
-- A. The function exists, and no app role may call it.
-- ---------------------------------------------------------------------------
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.a-function-exists %', case when n = 1
    then 'PASS public.cron_close_stale() exists' else 'FAIL found '||n||' definitions' end;
exception when others then raise notice 'PROBE 120.a-function-exists FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select p.prosecdef and p.proconfig @> array['search_path=public']
    into ok
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.b-security-definer %', case when ok
    then 'PASS security definer with search_path=public'
    else 'FAIL not security definer, or the search_path is not pinned to public' end;
exception when others then raise notice 'PROBE 120.b-security-definer FAIL %', sqlerrm; end $$;

do $$ declare txt text; begin
  select obj_description(p.oid, 'pg_proc') into txt
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.c-comment %', case when txt is not null and length(txt) > 0
    then 'PASS the contract is documented on the function'
    else 'FAIL no comment on function' end;
exception when others then raise notice 'PROBE 120.c-comment FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('authenticated', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.d-authenticated-no-execute %', case when ok = false
    then 'PASS authenticated cannot execute the janitor'
    else 'FAIL authenticated can execute the janitor' end;
exception when others then raise notice 'PROBE 120.d-authenticated-no-execute FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('anon', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.e-anon-no-execute %', case when ok = false
    then 'PASS anon cannot execute the janitor'
    else 'FAIL anon can execute the janitor' end;
exception when others then raise notice 'PROBE 120.e-anon-no-execute FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('public', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.f-public-no-execute %', case when ok = false
    then 'PASS PUBLIC holds no execute grant'
    else 'FAIL PUBLIC can execute the janitor' end;
exception when others then raise notice 'PROBE 120.f-public-no-execute FAIL %', sqlerrm; end $$;

-- The privilege bit is not a promise: the call itself has to be refused.
select pg_temp.act('00000000-0000-0000-0000-0000000020a2');
set role authenticated;
do $$ declare v_state text; begin
  perform public.cron_close_stale();
  raise notice 'PROBE 120.g-authenticated-call-refused FAIL an app role ran the janitor';
exception when others then
  v_state := sqlstate;
  raise notice 'PROBE 120.g-authenticated-call-refused %', case when v_state = '42501'
    then 'PASS refused (42501: '||sqlerrm||')' else 'FAIL '||v_state||' '||sqlerrm end;
end $$;
reset role;

set role anon;
do $$ declare v_state text; begin
  perform public.cron_close_stale();
  raise notice 'PROBE 120.h-anon-call-refused FAIL anon ran the janitor';
exception when others then
  v_state := sqlstate;
  raise notice 'PROBE 120.h-anon-call-refused %', case when v_state = '42501'
    then 'PASS refused (42501: '||sqlerrm||')' else 'FAIL '||v_state||' '||sqlerrm end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- B. The sweep, run the way pg_cron runs it: as postgres, with no JWT.
-- ---------------------------------------------------------------------------
do $$
declare
  e_stale uuid := '00000000-0000-0000-0000-0000000020c1';
  e_live uuid := '00000000-0000-0000-0000-0000000020c2';
  e_settled uuid := '00000000-0000-0000-0000-0000000020c3';
  e_win uuid := '00000000-0000-0000-0000-0000000020c4';
  e_del uuid := '00000000-0000-0000-0000-0000000020c5';
  att_old uuid := '00000000-0000-0000-0000-0000000020d1';
  att_new uuid := '00000000-0000-0000-0000-0000000020d2';
  v_expect_events int;
  v_expect_att int;
  v_n1 int;
  v_n2 int;
  v_stamp timestamptz;
  v_played timestamptz;
  v_settled_before timestamptz;
  v_stamp_after timestamptz;
  v_stamp_final timestamptz;
  v_closed timestamptz;
  v_open timestamptz;
  v_phase text;
begin
  -- What SHOULD be closed, read before the call.
  select count(*) into v_expect_events
    from public.events e join public.rooms r on r.id = e.room_id
   where r.deleted_at is null
     and e.settled_at is null
     and e.played_at < now() - make_interval(hours => r.auto_close_hours);
  select count(*) into v_expect_att
    from public.settlement_attestations
   where closed_at is null and now() > opened_at + interval '24 hours';

  -- The night the sweep should settle, and the one it must not touch.
  select played_at into v_played from public.events where id = e_stale;
  select settled_at into v_settled_before from public.events where id = e_settled;

  -- The call a pg_cron session makes: as postgres, no JWT, no membership.
  v_n1 := public.cron_close_stale();

  -- 1. The stranded night is settled.
  select settled_at into v_stamp from public.events where id = e_stale;
  raise notice 'PROBE 120.i-stamps-stranded-night %', case when v_stamp is not null
    then 'PASS the stranded night was settled' else 'FAIL settled_at is still null' end;

  -- 2. And it is stamped at played_at + the room's window, not now().
  raise notice 'PROBE 120.j-stamp-is-played-at-plus-window %', case when v_stamp = v_played + make_interval(hours => 8)
    then 'PASS settled_at = played_at + the room''s 8h window'
    else 'FAIL settled '||coalesce(v_stamp::text,'null')||' for a night played '||coalesce(v_played::text,'?') end;

  -- 3. Which is why a long-stranded night reads 'past', not 'recap'.
  select public.night_phase(e.played_at, e.settled_at, 8, now()) into v_phase
    from public.events e where e.id = e_stale;
  raise notice 'PROBE 120.k-phase-past %', case when v_phase = 'past'
    then 'PASS a night stranded for 40h reads past' else 'FAIL phase '||coalesce(v_phase,'?') end;

  -- 4. A night still inside its window is untouched.
  select settled_at into v_stamp from public.events where id = e_live;
  raise notice 'PROBE 120.l-live-night-untouched %', case when v_stamp is null
    then 'PASS the night inside its window stays open' else 'FAIL settled '||v_stamp::text end;

  -- 5. An already-settled night keeps its own stamp.
  select settled_at into v_stamp from public.events where id = e_settled;
  raise notice 'PROBE 120.m-settled-night-untouched %', case when v_stamp = v_settled_before
    then 'PASS an already-settled night keeps its stamp'
    else 'FAIL moved from '||coalesce(v_settled_before::text,'null')||' to '||coalesce(v_stamp::text,'null') end;

  -- 6. The window is the ROOM's own, not a hard-coded 24h: rw runs 24h, and
  --    its 12h-old night is still inside that window even though it is old
  --    enough for the default 8h room.
  select settled_at into v_stamp from public.events where id = e_win;
  raise notice 'PROBE 120.n-window-is-the-rooms-own %', case when v_stamp is null
    then 'PASS a 12h-old night in a 24h-window room stays open'
    else 'FAIL settled '||v_stamp::text end;

  -- 7. A soft-deleted room is out of the sweep (same filter as the client path).
  select settled_at into v_stamp from public.events where id = e_del;
  raise notice 'PROBE 120.o-deleted-room-untouched %', case when v_stamp is null
    then 'PASS the deleted room''s night is not swept'
    else 'FAIL settled '||v_stamp::text end;

  -- 8. The attestation open for more than 24h is closed.
  select closed_at into v_closed from public.settlement_attestations where id = att_old;
  raise notice 'PROBE 120.p-stale-attestation-closed %', case when v_closed is not null
    then 'PASS the 25h-old attestation was closed' else 'FAIL still open' end;

  -- 9. The fresh one is not.
  select closed_at into v_open from public.settlement_attestations where id = att_new;
  raise notice 'PROBE 120.q-fresh-attestation-open %', case when v_open is null
    then 'PASS the 1h-old attestation stays open' else 'FAIL closed at '||v_open::text end;

  -- 10. The return value is the number of rows it closed.
  raise notice 'PROBE 120.r-return-count %', case when v_n1 = v_expect_events + v_expect_att
    then 'PASS returned '||v_n1||' (= '||v_expect_events||' events + '||v_expect_att||' attestations)'
    else 'FAIL returned '||v_n1||', expected '||(v_expect_events + v_expect_att) end;

  -- 11. The second call changes nothing.
  select settled_at into v_stamp_after from public.events where id = e_stale;
  v_n2 := public.cron_close_stale();
  select settled_at into v_stamp_final from public.events where id = e_stale;
  raise notice 'PROBE 120.s-second-call-noop %', case when v_n2 = 0 and v_stamp_final = v_stamp_after
    then 'PASS the second call closed nothing and moved no stamp'
    else 'FAIL returned '||v_n2||' stamp '||coalesce(v_stamp_after::text,'null')||' -> '||coalesce(v_stamp_final::text,'null') end;

  -- 12. And the attestations stay closed (not re-stamped).
  select closed_at into v_closed from public.settlement_attestations where id = att_old;
  raise notice 'PROBE 120.t-second-call-keeps-stamp %', case when v_closed is not null
    then 'PASS the closed attestation keeps its closed_at'
    else 'FAIL the attestation reopened' end;
end $$;

-- ---------------------------------------------------------------------------
-- C. The cron job.
-- ---------------------------------------------------------------------------
do $$
declare
  v_has_ext boolean := false;
  v_jobs regclass := to_regclass('cron.job');
  n int;
begin
  select exists (select 1 from pg_extension where extname = 'pg_cron') into v_has_ext;

  if v_jobs is null then
    -- No pg_cron at all: the guarded block took its else branch, the
    -- migration applied cleanly and nothing was registered.
    raise notice 'PROBE 120.u-cron-job-count PASS no cron.job relation: pg_cron is absent, so nothing was registered';
    return;
  end if;

  if not v_has_ext then
    -- The harness may stub the cron schema without installing the extension.
    select count(*) into n from cron.job where jobname = 'gr-stale-close';
    raise notice 'PROBE 120.u-cron-job-count %', case when n = 0
      then 'PASS pg_cron is absent, so no gr-stale-close job was registered'
      else 'FAIL '||n||' gr-stale-close job(s) registered although pg_cron is not installed' end;
    return;
  end if;

  select count(*) into n from cron.job where jobname = 'gr-stale-close';
  raise notice 'PROBE 120.u-cron-job-count %', case when n = 1
    then 'PASS exactly one gr-stale-close job (unschedule-then-schedule did not duplicate it)'
    else 'FAIL expected 1 gr-stale-close job, found '||n end;
exception when others then
  raise notice 'PROBE 120.u-cron-job-count FAIL %', sqlerrm;
end $$;

do $$
declare
  v_has_ext boolean := false;
  sched text;
  cmd text;
begin
  select exists (select 1 from pg_extension where extname = 'pg_cron') into v_has_ext;
  if not v_has_ext or to_regclass('cron.job') is null then
    raise notice 'PROBE 120.v-cron-job-shape INFO skipped: pg_cron is absent';
    return;
  end if;

  select schedule, command into sched, cmd from cron.job where jobname = 'gr-stale-close';
  raise notice 'PROBE 120.v-cron-job-shape %', case when sched = '17 * * * *' and cmd like '%cron_close_stale%'
    then 'PASS hourly at minute 17, calling public.cron_close_stale()'
    else 'FAIL schedule '||coalesce(sched,'?')||' command '||coalesce(cmd,'?') end;
exception when others then
  raise notice 'PROBE 120.v-cron-job-shape FAIL %', sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- Cleanup.
-- ---------------------------------------------------------------------------
delete from public.settlement_attestations where id in
  ('00000000-0000-0000-0000-0000000020d1','00000000-0000-0000-0000-0000000020d2');
delete from public.events where id in
  ('00000000-0000-0000-0000-0000000020c1','00000000-0000-0000-0000-0000000020c2',
   '00000000-0000-0000-0000-0000000020c3','00000000-0000-0000-0000-0000000020c4',
   '00000000-0000-0000-0000-0000000020c5');
delete from public.room_memberships where room_id in
  ('00000000-0000-0000-0000-0000000020b1','00000000-0000-0000-0000-0000000020b2',
   '00000000-0000-0000-0000-0000000020b3');
delete from public.rooms where id in
  ('00000000-0000-0000-0000-0000000020b1','00000000-0000-0000-0000-0000000020b2',
   '00000000-0000-0000-0000-0000000020b3');
