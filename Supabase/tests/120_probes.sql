-- Probes for 120_night_ends_itself.sql on a schema-only replica (115 + 119 +
-- 120 applied). Every line of interest prints "PROBE <id> PASS|FAIL|INFO ...".
--
-- What is under test: the DERIVE-AT-READ autoclose. The end of a night is
-- played_at + the room's auto_close_hours, and that value is known the
-- moment the night is BOOKED -- so the reads derive the end themselves, and
-- nobody has to write events.settled_at for the night to have ended.
--
-- Brief letter -> probe id:
--   (a) the headline: a never-stamped night 8 h 01 m past its start reads as
--       a recap with no writer at all -> 120.a-headline-* (four notices)
--   (b) a night 7 h 59 m past its start still reads live  -> 120.b-*
--   (c) an upcoming night still reads upcoming             -> 120.c-*
--   (d) a host-settled night keeps its own stamp, and recency keys on the
--       effective settle                                      -> 120.d-*
--   (e) an expired night outside 24 h reads past            -> 120.e-*
--   (f) the member gate (and the hidden-member filter)      -> 120.f-*
--   (g) the cron job: absent without pg_cron, DAILY at 03:17 when present
--       -> 120.u-cron-job-count, 120.v-cron-job-shape
--   (h) cron_close_stale still stamps idempotently          -> 120.i-* .. 120.t-*
--
-- The janitor is HYGIENE now: no probe above waits for it. Probes i..t are
-- the old janitor probes, reused, and they run AFTER the derive probes on
-- purpose -- the janitor stamps every expired night in the replica, so
-- running it first would write the very column probe (a) asserts is NULL.
--
-- Clock: every block RE-ANCHORS its own fixtures against now() before it
-- asserts anything. now() is the transaction timestamp, so the fixture and
-- the assertions inside one block always see the same clock, however long
-- the file took to get there. The margins the brief asks for (8 h 01 m
-- past, 7 h 59 m past) are exact inside a block, not approximate.
--
-- Style: raise notice 'PROBE <id> %', case ... end -- the same style as the
-- 107/115/119 probe files. (A bare SELECT inside a DO block is discarded by
-- plpgsql, so the notice form is the one that carries a multi-step probe.)
--
-- Run: psql "$REPLICA_DB_URL" -f Supabase/tests/120_probes.sql 2>&1 | grep PROBE
\set ON_ERROR_STOP 0

create or replace function pg_temp.act(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false),
         set_config('request.jwt.claim.sub', u::text, false);
$$;

-- ---------------------------------------------------------------------------
-- Setup (superuser). Creates the rooms, the users and the nights; each probe
-- block below re-anchors the timestamps it reads.
--   h  host of every room
--   a  member of every room
--   o  in no room at all (the non-member the gate must turn away)
--
--   r_head   8 h window | e_head    played 8 h 01 m ago, NEVER stamped
--   r_live   8 h window | e_live    played 7 h 59 m ago, never stamped
--   r_up     8 h window | e_up      played in 2 days
--   r_stamp  8 h window | e_host    played 3 h ago, SETTLED by the host 2 h ago
--   r_order  8 h window | e_host2   played 3 h ago, settled by the host 2 h ago
--                      | e_never   played 8 h 01 m ago, never stamped
--   r_old    8 h window | e_old     played 40 h ago, never stamped
--   r_gate   8 h window | e_gate    played 8 h 01 m ago, never stamped
--   r_hidden 8 h window | e_hidden  played 8 h 01 m ago, hidden from a
--   r_jan    8 h window | e_stale   played 40 h ago, never stamped
--                      | e_jlive   played 1 h ago, never stamped
--                      | e_jsettled played 40 h ago, settled 30 h ago
--   rw      24 h window | e_win     played 12 h ago, never stamped
--   rd    deleted room   | e_del     played 40 h ago, never stamped
--
--   att_old  opened 25 h ago -> the janitor must close it
--   att_new  opened 1 h ago  -> the janitor must leave it open
-- ---------------------------------------------------------------------------
do $$
declare
  h uuid := '00000000-0000-0000-0000-0000000020a1';
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  o uuid := '00000000-0000-0000-0000-0000000020a3';
  r_head uuid := '00000000-0000-0000-0000-0000000020b1';
  r_live uuid := '00000000-0000-0000-0000-0000000020b2';
  r_up uuid := '00000000-0000-0000-0000-0000000020b3';
  r_stamp uuid := '00000000-0000-0000-0000-0000000020b4';
  r_order uuid := '00000000-0000-0000-0000-0000000020b5';
  r_old uuid := '00000000-0000-0000-0000-0000000020b6';
  r_gate uuid := '00000000-0000-0000-0000-0000000020b7';
  r_hidden uuid := '00000000-0000-0000-0000-0000000020b8';
  r_jan uuid := '00000000-0000-0000-0000-0000000020b9';
  rw uuid := '00000000-0000-0000-0000-0000000020ba';
  rd uuid := '00000000-0000-0000-0000-0000000020bb';
  e_head uuid := '00000000-0000-0000-0000-0000000020c1';
  e_live uuid := '00000000-0000-0000-0000-0000000020c2';
  e_up uuid := '00000000-0000-0000-0000-0000000020c3';
  e_host uuid := '00000000-0000-0000-0000-0000000020c4';
  e_host2 uuid := '00000000-0000-0000-0000-0000000020c5';
  e_never uuid := '00000000-0000-0000-0000-0000000020c6';
  e_old uuid := '00000000-0000-0000-0000-0000000020c7';
  e_gate uuid := '00000000-0000-0000-0000-0000000020c8';
  e_hidden uuid := '00000000-0000-0000-0000-0000000020c9';
  e_stale uuid := '00000000-0000-0000-0000-0000000020ca';
  e_jlive uuid := '00000000-0000-0000-0000-0000000020cb';
  e_jsettled uuid := '00000000-0000-0000-0000-0000000020cc';
  e_win uuid := '00000000-0000-0000-0000-0000000020cd';
  e_del uuid := '00000000-0000-0000-0000-0000000020ce';
  att_old uuid := '00000000-0000-0000-0000-0000000020d1';
  att_new uuid := '00000000-0000-0000-0000-0000000020d2';
begin
  -- Start from a clean slate so the file can be run twice in a row.
  delete from public.settlement_attestations where id in (att_old, att_new);
  delete from public.events where id in
    (e_head, e_live, e_up, e_host, e_host2, e_never, e_old, e_gate, e_hidden,
     e_stale, e_jlive, e_jsettled, e_win, e_del);

  insert into auth.users(id) values (h),(a),(o) on conflict do nothing;
  insert into users(id, display_name) values (h,'Host'),(a,'Alex'),(o,'Stranger') on conflict do nothing;
  insert into rooms(id, name, mascot_name, created_by, auto_close_hours, time_zone)
    values (r_head,  'Derive Room',     'Tally', h, 8,  'Australia/Brisbane'),
           (r_live,  'Live Room',       'Tally', h, 8,  'Australia/Brisbane'),
           (r_up,    'Upcoming Room',   'Tally', h, 8,  'Australia/Brisbane'),
           (r_stamp, 'Stamped Room',    'Tally', h, 8,  'Australia/Brisbane'),
           (r_order, 'Order Room',      'Tally', h, 8,  'Australia/Brisbane'),
           (r_old,   'Old Room',        'Tally', h, 8,  'Australia/Brisbane'),
           (r_gate,  'Gate Room',       'Tally', h, 8,  'Australia/Brisbane'),
           (r_hidden,'Hidden Room',     'Tally', h, 8,  'Australia/Brisbane'),
           (r_jan,   'Janitor Room',    'Tally', h, 8,  'Australia/Brisbane'),
           (rw,      'Wide Window Room','Tally', h, 24, 'Australia/Brisbane'),
           (rd,      'Deleted Room',    'Tally', h, 8,  'Australia/Brisbane')
    on conflict (id) do nothing;
  update public.rooms set deleted_at = now() where id = rd;
  insert into room_memberships(room_id, user_id, role, points_balance, membership_status)
    select rr, u, case when u = h then 'host' else 'member' end, 500, 'active'
      from unnest(array[r_head,r_live,r_up,r_stamp,r_order,r_old,r_gate,r_hidden,r_jan,rw,rd]) rr
      cross join unnest(array[h,a]) u
    on conflict (room_id, user_id) do update set membership_status = 'active';
  insert into events(id, room_id, name, played_at, settled_at, created_by) values
    (e_head,    r_head,   'Never stamped',  now() - interval '8 hours 1 minute', null,                        h),
    (e_live,    r_live,   'Still live',     now() - interval '7 hours 59 minutes', null,                       h),
    (e_up,      r_up,     'Next week',      now() + interval '2 days',           null,                        h),
    (e_host,    r_stamp,  'Host settled',   now() - interval '3 hours',           now() - interval '2 hours',  h),
    (e_host2,   r_order,  'Host settled',   now() - interval '3 hours',           now() - interval '2 hours',  h),
    (e_never,   r_order,  'Never stamped',  now() - interval '8 hours 1 minute', null,                        h),
    (e_old,     r_old,    'Long ago',       now() - interval '40 hours',         null,                        h),
    (e_gate,    r_gate,   'Never stamped',  now() - interval '8 hours 1 minute', null,                        h),
    (e_hidden,  r_hidden, 'Hidden night',   now() - interval '8 hours 1 minute', null,                        h),
    (e_stale,   r_jan,    'Stranded night', now() - interval '40 hours',         null,                        h),
    (e_jlive,   r_jan,    'Tonight',        now() - interval '1 hour',           null,                        h),
    (e_jsettled,r_jan,    'Settled night',  now() - interval '40 hours',         now() - interval '30 hours', h),
    (e_win,     rw,       'Still live',     now() - interval '12 hours',         null,                        h),
    (e_del,     rd,       'Deleted night',  now() - interval '40 hours',         null,                        h)
    on conflict (id) do nothing;
  update public.events set hidden_from_user_ids = array[a] where id = e_hidden;
  insert into settlement_attestations(id, session_id, room_id, member_id, vision_amount_points, opened_at)
    values (att_old, '00000000-0000-0000-0000-0000000020e1', r_jan, a, 100, now() - interval '25 hours'),
           (att_new, '00000000-0000-0000-0000-0000000020e2', r_jan, a, 100, now() - interval '1 hour')
    on conflict (id) do nothing;
  raise notice 'PROBE 120.setup INFO seeded 11 rooms, 14 events, 2 attestations';
end $$;

-- ===========================================================================
-- (a) HEADLINE -- the night ends itself, with no writer.
--
-- e_head was played 8 h 01 m ago and nobody ever settled it. Its true end
-- is played_at + the room's 8 h window, so it ended a minute ago: it must
-- read as a recap NOW, whether or not any writer has run -- and the physical
-- column must still be NULL, because no writer did.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_head uuid := '00000000-0000-0000-0000-0000000020b1';
  e_head uuid := '00000000-0000-0000-0000-0000000020c1';
  v_played timestamptz;
  v_stamp timestamptz;
  v_phase text;
  n int;
  ev record;
begin
  -- Re-anchor: played 8 h 01 m ago, never stamped.
  update public.events
     set played_at = now() - interval '8 hours 1 minute', settled_at = null
   where id = e_head;
  select played_at, settled_at into v_played, v_stamp from public.events where id = e_head;

  -- 1. No writer ran: the physical column is still NULL.
  raise notice 'PROBE 120.a-headline-no-tick %', case when v_stamp is null
    then 'PASS the physical settled_at is still null -- the night ended without a writer'
    else 'FAIL settled_at was written at '||v_stamp::text end;

  -- 2. night_phase derives 'recap' from the timestamps alone.
  select public.night_phase(v_played, v_stamp, 8, now()) into v_phase;
  raise notice 'PROBE 120.a-headline-phase %', case when v_phase = 'recap'
    then 'PASS night_phase reads recap for a never-stamped night 8h01m past its start'
    else 'FAIL phase '||coalesce(v_phase,'?') end;

  -- 3. And the recap reader hands back the derived end as settled_at.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_head);
  select * into ev from public.get_recent_settled_event(r_head);
  raise notice 'PROBE 120.a-headline-read %', case
    when n = 1 and ev.id = e_head and ev.settled_at = v_played + make_interval(hours => 8)
    then 'PASS get_recent_settled_event returns the night with settled_at = played_at + the 8h window'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null') end;

  -- 4. The room-page reader agrees (its settled leg).
  select count(*) into n from public.get_active_event(r_head);
  select * into ev from public.get_active_event(r_head);
  raise notice 'PROBE 120.a-headline-active %', case
    when n = 1 and ev.id = e_head and ev.settled_at = v_played + make_interval(hours => 8)
    then 'PASS get_active_event returns the same night with the same derived settled_at'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null') end;
end $$;

-- ===========================================================================
-- (b) One minute inside the window is still live. The derive must not
--     close a night early.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_live uuid := '00000000-0000-0000-0000-0000000020b2';
  e_live uuid := '00000000-0000-0000-0000-0000000020c2';
  v_played timestamptz;
  v_phase text;
  n int;
  ev record;
begin
  -- Re-anchor: played 7 h 59 m ago, never stamped.
  update public.events
     set played_at = now() - interval '7 hours 59 minutes', settled_at = null
   where id = e_live;
  select played_at into v_played from public.events where id = e_live;

  select public.night_phase(v_played, null, 8, now()) into v_phase;
  raise notice 'PROBE 120.b-phase-live %', case when v_phase = 'live'
    then 'PASS night_phase reads live 7h59m past the start'
    else 'FAIL phase '||coalesce(v_phase,'?') end;

  -- No effective settle yet, so there is nothing to recap.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_live);
  raise notice 'PROBE 120.b-no-recap-yet %', case when n = 0
    then 'PASS get_recent_settled_event returns nothing for a night inside its window'
    else 'FAIL got '||n||' row(s)' end;

  -- And the room page still shows it as the live night, with no settle time.
  select count(*) into n from public.get_active_event(r_live);
  select * into ev from public.get_active_event(r_live);
  raise notice 'PROBE 120.b-active-live %', case
    when n = 1 and ev.id = e_live and ev.settled_at is null
    then 'PASS get_active_event returns the live night with a null settled_at'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null') end;
end $$;

-- ===========================================================================
-- (c) A future night is still future: the derive is about endings only.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_up uuid := '00000000-0000-0000-0000-0000000020b3';
  e_up uuid := '00000000-0000-0000-0000-0000000020c3';
  v_played timestamptz;
  v_phase text;
  n int;
  ev record;
begin
  -- Re-anchor: played in two days, never stamped.
  update public.events
     set played_at = now() + interval '2 days', settled_at = null
   where id = e_up;
  select played_at into v_played from public.events where id = e_up;

  select public.night_phase(v_played, null, 8, now()) into v_phase;
  raise notice 'PROBE 120.c-phase-upcoming %', case when v_phase = 'upcoming'
    then 'PASS night_phase reads upcoming for a night two days out'
    else 'FAIL phase '||coalesce(v_phase,'?') end;

  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_up);
  raise notice 'PROBE 120.c-no-recap %', case when n = 0
    then 'PASS get_recent_settled_event returns nothing for an upcoming night'
    else 'FAIL got '||n||' row(s)' end;

  select count(*) into n from public.get_active_event(r_up);
  select * into ev from public.get_active_event(r_up);
  raise notice 'PROBE 120.c-active-upcoming %', case
    when n = 1 and ev.id = e_up and ev.settled_at is null
    then 'PASS get_active_event returns the upcoming night with a null settled_at'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null') end;
end $$;

-- ===========================================================================
-- (d) The host's own stamp wins, and recency keys on the EFFECTIVE settle.
--
-- r_stamp: e_host was settled by the host 2 h ago, so the night ended then
--          -- not at played_at + 8 h. The reader must hand back the host's
--          stamp, not the derived end.
-- r_order: e_host2 (host stamp, now - 2 h) and e_never (never stamped, but
--          its true end is now - 1 m). The later EFFECTIVE settle wins, so
--          e_never is the recap even though e_host2 is the one with a
--          physical stamp. Under the old rule e_never was not a candidate
--          at all and e_host2 won.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_stamp uuid := '00000000-0000-0000-0000-0000000020b4';
  r_order uuid := '00000000-0000-0000-0000-0000000020b5';
  e_host uuid := '00000000-0000-0000-0000-0000000020c4';
  e_host2 uuid := '00000000-0000-0000-0000-0000000020c5';
  e_never uuid := '00000000-0000-0000-0000-0000000020c6';
  v_host_stamp timestamptz;
  v_played timestamptz;
  v_phase text;
  n int;
  ev record;
begin
  -- Re-anchor: the host settled both nights 2 h ago.
  update public.events
     set played_at = now() - interval '3 hours', settled_at = now() - interval '2 hours'
   where id in (e_host, e_host2);
  -- Re-anchor: e_never was played 8 h 01 m ago and nobody settled it.
  update public.events
     set played_at = now() - interval '8 hours 1 minute', settled_at = null
   where id = e_never;

  select settled_at into v_host_stamp from public.events where id = e_host;

  select public.night_phase((select played_at from public.events where id = e_host), v_host_stamp, 8, now())
    into v_phase;
  raise notice 'PROBE 120.d-host-stamp-phase %', case when v_phase = 'recap'
    then 'PASS an early-settled night reads recap'
    else 'FAIL phase '||coalesce(v_phase,'?') end;

  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_stamp);
  select * into ev from public.get_recent_settled_event(r_stamp);
  raise notice 'PROBE 120.d-host-stamp-wins %', case
    when n = 1 and ev.id = e_host and ev.settled_at = v_host_stamp
    then 'PASS the host''s own stamp is returned, not the derived end'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null')
         ||' (host stamp '||coalesce(v_host_stamp::text,'null')||')' end;

  -- The ordering: the derived end (now - 1 m) outranks the host stamp (now - 2 h).
  select played_at into v_played from public.events where id = e_never;
  select count(*) into n from public.get_recent_settled_event(r_order);
  select * into ev from public.get_recent_settled_event(r_order);
  raise notice 'PROBE 120.d-order-by-effective-settle %', case
    when n = 1 and ev.id = e_never and ev.settled_at = v_played + make_interval(hours => 8)
    then 'PASS recency keys on the effective settle: the derived end wins over the older host stamp'
    else 'FAIL rows '||n||' id '||coalesce(ev.id::text,'?')||' settled_at '||coalesce(ev.settled_at::text,'null') end;
end $$;

-- ===========================================================================
-- (e) An expired night outside the 24 h recap window reads 'past' -- even
--     though nobody ever stamped it.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_old uuid := '00000000-0000-0000-0000-0000000020b6';
  e_old uuid := '00000000-0000-0000-0000-0000000020c7';
  v_played timestamptz;
  v_phase text;
  n int;
begin
  -- Re-anchor: played 40 h ago, never stamped.
  update public.events
     set played_at = now() - interval '40 hours', settled_at = null
   where id = e_old;
  select played_at into v_played from public.events where id = e_old;

  select public.night_phase(v_played, null, 8, now()) into v_phase;
  raise notice 'PROBE 120.e-phase-past %', case when v_phase = 'past'
    then 'PASS night_phase reads past for a never-stamped night 40h old'
    else 'FAIL phase '||coalesce(v_phase,'?') end;

  -- ... and it is out of the recap window, so the recap reader returns nothing.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_old);
  raise notice 'PROBE 120.e-no-recap %', case when n = 0
    then 'PASS get_recent_settled_event returns nothing for a night that ended more than 24h ago'
    else 'FAIL got '||n||' row(s)' end;
end $$;

-- ===========================================================================
-- (f) The gates the derive must not open: the membership gate and the
--     hidden-member filter, byte-for-byte as they were.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  o uuid := '00000000-0000-0000-0000-0000000020a3';
  r_gate uuid := '00000000-0000-0000-0000-0000000020b7';
  e_gate uuid := '00000000-0000-0000-0000-0000000020c8';
  n int;
begin
  -- Re-anchor: played 8 h 01 m ago, never stamped.
  update public.events
     set played_at = now() - interval '8 hours 1 minute', settled_at = null
   where id = e_gate;

  -- o is authenticated but in no room: the gate must turn them away.
  perform pg_temp.act(o);
  select count(*) into n from public.get_recent_settled_event(r_gate);
  raise notice 'PROBE 120.f-non-member-gated %', case when n = 0
    then 'PASS a non-member gets nothing from get_recent_settled_event'
    else 'FAIL a non-member got '||n||' row(s)' end;

  -- The control: the same room, the same night, a member.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_gate);
  raise notice 'PROBE 120.f-member-sees %', case when n = 1
    then 'PASS a member gets the recap'
    else 'FAIL a member got '||n||' row(s)' end;
end $$;

do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_hidden uuid := '00000000-0000-0000-0000-0000000020b8';
  e_hidden uuid := '00000000-0000-0000-0000-0000000020c9';
  n int;
begin
  -- Re-anchor: played 8 h 01 m ago, and hidden from a.
  update public.events
     set played_at = now() - interval '8 hours 1 minute', settled_at = null,
         hidden_from_user_ids = array[a]
   where id = e_hidden;

  -- e_hidden is hidden from a, who is a member of r_hidden.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_hidden);
  raise notice 'PROBE 120.f-hidden-filter %', case when n = 0
    then 'PASS the hidden-member filter still hides the night from the member it names'
    else 'FAIL the hidden member got '||n||' row(s)' end;

  -- The control: empty the hidden list and the same night appears.
  update public.events set hidden_from_user_ids = '{}' where id = e_hidden;
  select count(*) into n from public.get_recent_settled_event(r_hidden);
  raise notice 'PROBE 120.f-hidden-filter-control %', case when n = 1
    then 'PASS the same night is visible once the hidden list is empty'
    else 'FAIL got '||n||' row(s)' end;
end $$;

-- ===========================================================================
-- The janitor''s security contract -- the old probes 120.a .. 120.h, reused.
-- ===========================================================================
do $$ declare n int; begin
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.sec1-function-exists %', case when n = 1
    then 'PASS public.cron_close_stale() exists' else 'FAIL found '||n||' definitions' end;
exception when others then raise notice 'PROBE 120.sec1-function-exists FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select p.prosecdef and p.proconfig @> array['search_path=public']
    into ok
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.sec2-security-definer %', case when ok
    then 'PASS security definer with search_path=public'
    else 'FAIL not security definer, or the search_path is not pinned to public' end;
exception when others then raise notice 'PROBE 120.sec2-security-definer FAIL %', sqlerrm; end $$;

do $$ declare txt text; begin
  select obj_description(p.oid, 'pg_proc') into txt
    from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname = 'cron_close_stale';
  raise notice 'PROBE 120.sec3-comment %', case when txt is not null and length(txt) > 0
    then 'PASS the contract is documented on the function'
    else 'FAIL no comment on function' end;
exception when others then raise notice 'PROBE 120.sec3-comment FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('authenticated', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.sec4-authenticated-no-execute %', case when ok = false
    then 'PASS authenticated cannot execute the janitor'
    else 'FAIL authenticated can execute the janitor' end;
exception when others then raise notice 'PROBE 120.sec4-authenticated-no-execute FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('anon', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.sec5-anon-no-execute %', case when ok = false
    then 'PASS anon cannot execute the janitor'
    else 'FAIL anon can execute the janitor' end;
exception when others then raise notice 'PROBE 120.sec5-anon-no-execute FAIL %', sqlerrm; end $$;

do $$ declare ok boolean; begin
  select has_function_privilege('public', 'public.cron_close_stale()', 'EXECUTE') into ok;
  raise notice 'PROBE 120.sec6-public-no-execute %', case when ok = false
    then 'PASS PUBLIC holds no execute grant'
    else 'FAIL PUBLIC can execute the janitor' end;
exception when others then raise notice 'PROBE 120.sec6-public-no-execute FAIL %', sqlerrm; end $$;

-- The privilege bit is not a promise: the call itself has to be refused.
select pg_temp.act('00000000-0000-0000-0000-0000000020a2');
set role authenticated;
do $$ declare v_state text; begin
  perform public.cron_close_stale();
  raise notice 'PROBE 120.sec7-authenticated-call-refused FAIL an app role ran the janitor';
exception when others then
  v_state := sqlstate;
  raise notice 'PROBE 120.sec7-authenticated-call-refused %', case when v_state = '42501'
    then 'PASS refused (42501: '||sqlerrm||')' else 'FAIL '||v_state||' '||sqlerrm end;
end $$;
reset role;

set role anon;
do $$ declare v_state text; begin
  perform public.cron_close_stale();
  raise notice 'PROBE 120.sec8-anon-call-refused FAIL anon ran the janitor';
exception when others then
  v_state := sqlstate;
  raise notice 'PROBE 120.sec8-anon-call-refused %', case when v_state = '42501'
    then 'PASS refused (42501: '||sqlerrm||')' else 'FAIL '||v_state||' '||sqlerrm end;
end $$;
reset role;

-- ===========================================================================
-- (h) The janitor, run the way pg_cron runs it: as postgres, with no JWT.
--     The old probes 120.i .. 120.t, reused. The body stamps the same value
--     the reads now derive, so it agrees with them by construction.
-- ===========================================================================
do $$
declare
  a uuid := '00000000-0000-0000-0000-0000000020a2';
  r_head uuid := '00000000-0000-0000-0000-0000000020b1';
  e_head uuid := '00000000-0000-0000-0000-0000000020c1';
  e_stale uuid := '00000000-0000-0000-0000-0000000020ca';
  e_jlive uuid := '00000000-0000-0000-0000-0000000020cb';
  e_jsettled uuid := '00000000-0000-0000-0000-0000000020cc';
  e_win uuid := '00000000-0000-0000-0000-0000000020cd';
  e_del uuid := '00000000-0000-0000-0000-0000000020ce';
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
  v_derived timestamptz;
  v_before timestamptz;
  v_phase text;
  n int;
  ev record;
begin
  -- Re-anchor every fixture the sweep touches.
  update public.events
     set played_at = now() - interval '8 hours 1 minute', settled_at = null
   where id = e_head;
  update public.events
     set played_at = now() - interval '40 hours', settled_at = null
   where id = e_stale;
  update public.events
     set played_at = now() - interval '1 hour', settled_at = null
   where id = e_jlive;
  update public.events
     set played_at = now() - interval '40 hours', settled_at = now() - interval '30 hours'
   where id = e_jsettled;
  update public.events
     set played_at = now() - interval '12 hours', settled_at = null
   where id = e_win;
  update public.events
     set played_at = now() - interval '40 hours', settled_at = null
   where id = e_del;
  update public.settlement_attestations
     set opened_at = now() - interval '25 hours', closed_at = null
   where id = att_old;
  update public.settlement_attestations
     set opened_at = now() - interval '1 hour', closed_at = null
   where id = att_new;

  -- What the READ says right now, before any writer runs: the derived end.
  perform pg_temp.act(a);
  select count(*) into n from public.get_recent_settled_event(r_head);
  select * into ev from public.get_recent_settled_event(r_head);
  v_derived := ev.settled_at;
  select settled_at into v_before from public.events where id = e_head;

  -- Drop the JWT: the janitor is called the way pg_cron calls it -- as
  -- postgres, with no claims at all. The claims go to '{}' (not '') because
  -- current_user_id() casts the claims to json, and '' is not json.
  select set_config('request.jwt.claims', '{}', false),
         set_config('request.jwt.claim.sub', '', false);

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
  select settled_at into v_settled_before from public.events where id = e_jsettled;

  -- The call a pg_cron session makes: as postgres, no JWT, no membership.
  v_n1 := public.cron_close_stale();

  -- 0. The writer and the reader agree: the janitor stamps exactly the
  --    value the read derived, so the column catches up with what the
  --    reads already said.
  select settled_at into v_stamp from public.events where id = e_head;
  raise notice 'PROBE 120.derive-write-agrees %', case
    when v_before is null and v_stamp = v_derived
    then 'PASS the janitor writes exactly the value the read derived ('||coalesce(v_stamp::text,'null')||')'
    else 'FAIL the column was '||coalesce(v_before::text,'null')||' before and '||coalesce(v_stamp::text,'null')
         ||' after, the read derived '||coalesce(v_derived::text,'null') end;

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
  select settled_at into v_stamp from public.events where id = e_jlive;
  raise notice 'PROBE 120.l-live-night-untouched %', case when v_stamp is null
    then 'PASS the night inside its window stays open' else 'FAIL settled '||v_stamp::text end;

  -- 5. An already-settled night keeps its own stamp.
  select settled_at into v_stamp from public.events where id = e_jsettled;
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

-- ===========================================================================
-- (g) The cron job -- the old probes 120.u and 120.v. The schedule moved
--     from hourly at minute 17 to DAILY at 03:17: the janitor is hygiene
--     now, so nothing waits for it.
-- ===========================================================================
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
  raise notice 'PROBE 120.v-cron-job-shape %', case when sched = '17 3 * * *' and cmd like '%cron_close_stale%'
    then 'PASS daily at 03:17, calling public.cron_close_stale()'
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
   '00000000-0000-0000-0000-0000000020c5','00000000-0000-0000-0000-0000000020c6',
   '00000000-0000-0000-0000-0000000020c7','00000000-0000-0000-0000-0000000020c8',
   '00000000-0000-0000-0000-0000000020c9','00000000-0000-0000-0000-0000000020ca',
   '00000000-0000-0000-0000-0000000020cb','00000000-0000-0000-0000-0000000020cc',
   '00000000-0000-0000-0000-0000000020cd','00000000-0000-0000-0000-0000000020ce');
delete from public.room_memberships where room_id in
  ('00000000-0000-0000-0000-0000000020b1','00000000-0000-0000-0000-0000000020b2',
   '00000000-0000-0000-0000-0000000020b3','00000000-0000-0000-0000-0000000020b4',
   '00000000-0000-0000-0000-0000000020b5','00000000-0000-0000-0000-0000000020b6',
   '00000000-0000-0000-0000-0000000020b7','00000000-0000-0000-0000-0000000020b8',
   '00000000-0000-0000-0000-0000000020b9','00000000-0000-0000-0000-0000000020ba',
   '00000000-0000-0000-0000-0000000020bb');
delete from public.rooms where id in
  ('00000000-0000-0000-0000-0000000020b1','00000000-0000-0000-0000-0000000020b2',
   '00000000-0000-0000-0000-0000000020b3','00000000-0000-0000-0000-0000000020b4',
   '00000000-0000-0000-0000-0000000020b5','00000000-0000-0000-0000-0000000020b6',
   '00000000-0000-0000-0000-0000000020b7','00000000-0000-0000-0000-0000000020b8',
   '00000000-0000-0000-0000-0000000020b9','00000000-0000-0000-0000-0000000020ba',
   '00000000-0000-0000-0000-0000000020bb');
