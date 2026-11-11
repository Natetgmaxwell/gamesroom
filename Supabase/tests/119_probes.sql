-- Probes for 119_glad_you_came.sql on a schema-only replica (115 + 119 applied).
-- Every line of interest prints "PROBE <id> PASS|FAIL|INFO ...".
-- RLS is only real for a non-superuser, so every app-side probe runs under
-- `set role authenticated` (or anon) with the JWT claims of one user.
--
-- Run: psql "$REPLICA_DB_URL" -f Supabase/tests/119_probes.sql 2>&1 | grep PROBE
\set ON_ERROR_STOP 0

create or replace function pg_temp.act(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false),
         set_config('request.jwt.claim.sub', u::text, false);
$$;

-- ---------------------------------------------------------------------------
-- Setup (superuser). h host, a and b seated, o a member with no seat,
-- x not in the room at all.
--   recap : played 4 h ago, settled 1 h ago      (night_phase = recap)
--   old   : played 32 h ago, settled 30 h ago    (past)
--   live  : played 1 h ago, not settled          (live)
-- ---------------------------------------------------------------------------
do $$
declare
  h uuid := '00000000-0000-0000-0000-0000000019a1';
  a uuid := '00000000-0000-0000-0000-0000000019a2';
  b uuid := '00000000-0000-0000-0000-0000000019a3';
  o uuid := '00000000-0000-0000-0000-0000000019a4';
  x uuid := '00000000-0000-0000-0000-0000000019a5';
  r uuid := '00000000-0000-0000-0000-0000000019b1';
  recap uuid := '00000000-0000-0000-0000-0000000019c1';
  old   uuid := '00000000-0000-0000-0000-0000000019c2';
  live  uuid := '00000000-0000-0000-0000-0000000019c3';
  ev uuid;
begin
  insert into auth.users(id) values (h),(a),(b),(o),(x) on conflict do nothing;
  insert into users(id, display_name) values (h,'Host'),(a,'Connor'),(b,'Sam'),(o,'Jo'),(x,'Stranger') on conflict do nothing;
  insert into rooms(id, name, mascot_name, created_by, auto_close_hours, time_zone)
    values (r, 'Glad Probe Room', 'Tally', h, 8, 'Australia/Brisbane') on conflict do nothing;
  insert into room_memberships(room_id, user_id, role, points_balance, membership_status)
    select r, u, case when u = h then 'host' else 'member' end, 500, 'active' from unnest(array[h,a,b,o]) u
    on conflict (room_id, user_id) do update set membership_status = 'active';
  insert into events(id, room_id, name, played_at, settled_at, created_by) values
    (recap, r, 'Last night', now() - interval '4 hours',  now() - interval '1 hour',   h),
    (old,   r, 'Way back',   now() - interval '32 hours', now() - interval '30 hours', h),
    (live,  r, 'Tonight',    now() - interval '1 hour',   null,                        h)
    on conflict do nothing;
  foreach ev in array array[recap, old, live] loop
    insert into event_rsvps(event_id, room_id, member_id, state)
      select ev, r, u, 'claimed' from unnest(array[h,a,b]) u
      on conflict (event_id, member_id) do update set state = 'claimed';
  end loop;
  insert into event_rsvps(event_id, room_id, member_id, state) values (recap, r, o, 'declined')
    on conflict (event_id, member_id) do update set state = 'declined';
  raise notice 'PROBE 119.setup INFO recap phase=%',
    (select night_phase(e.played_at, e.settled_at, 8, now()) from events e where e.id = recap);
end $$;

-- ---------------------------------------------------------------------------
-- A. Connor (seated) tells Sam (seated): allowed. Twice does nothing.
-- ---------------------------------------------------------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000019a2');
set role authenticated;
do $$
declare n int;
begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.a-seated-send PASS seated sender to seated recipient inserted';
exception when others then raise notice 'PROBE 119.a-seated-send FAIL %', sqlerrm;
end $$;
do $$
declare n int;
begin
  -- The client's write: PostgREST ignore-duplicates is ON CONFLICT DO NOTHING.
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a3')
    on conflict (event_id, from_user, to_user) do nothing;
  select count(*) into n from glad_you_came where from_user = '00000000-0000-0000-0000-0000000019a2';
  raise notice 'PROBE 119.b-twice %', case when n = 1 then 'PASS second send did nothing' else 'FAIL rows='||n end;
exception when others then raise notice 'PROBE 119.b-twice FAIL %', sqlerrm;
end $$;

-- Refusals, all as Connor.
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a4');
  raise notice 'PROBE 119.c-unseated-recipient FAIL sent to someone with no seat';
exception when others then raise notice 'PROBE 119.c-unseated-recipient PASS refused (%)', sqlerrm; end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a3', '00000000-0000-0000-0000-0000000019a1');
  raise notice 'PROBE 119.d-impersonate FAIL wrote a row as someone else';
exception when others then raise notice 'PROBE 119.d-impersonate PASS refused (%)', sqlerrm; end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a2');
  raise notice 'PROBE 119.e-self FAIL told themself';
exception when others then raise notice 'PROBE 119.e-self PASS refused (%)', sqlerrm; end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c2', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.f-window-closed FAIL sent after the 24 h recap window';
exception when others then raise notice 'PROBE 119.f-window-closed PASS refused (%)', sqlerrm; end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c3', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.g-unsettled FAIL sent on a night that is not settled';
exception when others then raise notice 'PROBE 119.g-unsettled PASS refused (%)', sqlerrm; end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user, created_at)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a1', now() - interval '9 days');
  raise notice 'PROBE 119.h-backdate FAIL client set created_at';
exception when others then raise notice 'PROBE 119.h-backdate PASS refused (%)', sqlerrm; end $$;
do $$ declare n int; begin
  update glad_you_came set to_user = '00000000-0000-0000-0000-0000000019a1' where from_user = '00000000-0000-0000-0000-0000000019a2';
  get diagnostics n = row_count;
  raise notice 'PROBE 119.i-update % rows=%', case when n = 0 then 'PASS' else 'FAIL' end, n;
exception when others then raise notice 'PROBE 119.i-update PASS refused (%)', sqlerrm; end $$;
do $$ declare n int; begin
  delete from glad_you_came where from_user = '00000000-0000-0000-0000-0000000019a2';
  get diagnostics n = row_count;
  raise notice 'PROBE 119.j-delete % rows=%', case when n = 0 then 'PASS' else 'FAIL' end, n;
exception when others then raise notice 'PROBE 119.j-delete PASS refused (%)', sqlerrm; end $$;
reset role;

-- The host also tells Sam, so Sam has two senders and one queued push.
select pg_temp.act('00000000-0000-0000-0000-0000000019a1');
set role authenticated;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a1', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.k-host-send PASS host sends like anyone';
exception when others then raise notice 'PROBE 119.k-host-send FAIL %', sqlerrm; end $$;
reset role;

-- ---------------------------------------------------------------------------
-- B. A member with no seat cannot send at all.
-- ---------------------------------------------------------------------------
select pg_temp.act('00000000-0000-0000-0000-0000000019a4');
set role authenticated;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a4', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.l-unseated-sender FAIL a member with no seat sent';
exception when others then raise notice 'PROBE 119.l-unseated-sender PASS refused (%)', sqlerrm; end $$;
reset role;

-- ---------------------------------------------------------------------------
-- C. Who can read what. Rows: Connor->Sam, Host->Sam.
-- ---------------------------------------------------------------------------
-- Sam (recipient) reads both rows addressed to them.
select pg_temp.act('00000000-0000-0000-0000-0000000019a3');
set role authenticated;
do $$ declare n int; begin
  select count(*) into n from glad_you_came;
  raise notice 'PROBE 119.m-recipient-reads % (sees %)', case when n = 2 then 'PASS' else 'FAIL' end, n;
end $$;
reset role;

-- Connor (sender) reads only their own sent row, not the host's.
select pg_temp.act('00000000-0000-0000-0000-0000000019a2');
set role authenticated;
do $$ declare n int; begin
  select count(*) into n from glad_you_came;
  raise notice 'PROBE 119.n-sender-reads-own % (sees %)', case when n = 1 then 'PASS' else 'FAIL' end, n;
  select count(*) into n from glad_you_came where to_user = '00000000-0000-0000-0000-0000000019a3';
  raise notice 'PROBE 119.o-sender-cannot-count-recipient % (sees % for Sam)', case when n = 1 then 'PASS only their own' else 'FAIL' end, n;
end $$;
reset role;

-- Jo (third party in the same room) and the Stranger read nothing, and
-- cannot count anyone's rows by any route the app roles have.
select pg_temp.act('00000000-0000-0000-0000-0000000019a4');
set role authenticated;
do $$ declare n int; begin
  select count(*) into n from glad_you_came where to_user = '00000000-0000-0000-0000-0000000019a3';
  raise notice 'PROBE 119.p-third-party-read % (sees %)', case when n = 0 then 'PASS' else 'FAIL' end, n;
end $$;
do $$ declare n int; begin
  select count(*) into n from glad_push_queue;
  raise notice 'PROBE 119.q-queue-read FAIL read the push queue (% rows)', n;
exception when others then raise notice 'PROBE 119.q-queue-read PASS refused (%)', sqlerrm; end $$;
do $$ declare n int; begin
  select count(*) into n from glad_push_due(now() + interval '2 days');
  raise notice 'PROBE 119.r-due-rpc FAIL called glad_push_due (% rows)', n;
exception when others then raise notice 'PROBE 119.r-due-rpc PASS refused (%)', sqlerrm; end $$;
do $$ declare n int; begin
  perform glad_push_cron_tick();
  raise notice 'PROBE 119.s-tick-rpc FAIL called the tick';
exception when others then raise notice 'PROBE 119.s-tick-rpc PASS refused (%)', sqlerrm; end $$;
do $$ declare ok boolean; begin
  -- The gate answers only for the caller's own sends: not an oracle.
  select glad_can_send('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a2', '00000000-0000-0000-0000-0000000019a3') into ok;
  raise notice 'PROBE 119.t-gate-oracle % (answered %)', case when ok = false then 'PASS' else 'FAIL' end, ok;
end $$;
reset role;

analyze public.glad_you_came;
select pg_temp.act('00000000-0000-0000-0000-0000000019a4');
set role authenticated;
do $$ declare n int; begin
  select count(*) into n from pg_stats where schemaname = 'public' and tablename = 'glad_you_came';
  raise notice 'PROBE 119.u-pg-stats % (% stats rows visible)', case when n = 0 then 'PASS' else 'FAIL' end, n;
end $$;
do $$ declare n int; begin
  -- No function in the API returns a count for this table.
  select count(*) into n from pg_proc p join pg_namespace s on s.oid = p.pronamespace
   where s.nspname = 'public' and p.proname like 'glad%'
     and has_function_privilege('authenticated', p.oid, 'execute')
     and p.proname not in ('glad_can_send', 'glad_push_deliver_at');
  raise notice 'PROBE 119.v-no-aggregate-rpc % (% other glad functions callable)', case when n = 0 then 'PASS' else 'FAIL' end, n;
end $$;
reset role;

select pg_temp.act('00000000-0000-0000-0000-0000000019a5');
set role authenticated;
do $$ declare n int; begin
  select count(*) into n from glad_you_came;
  raise notice 'PROBE 119.w-non-member-read % (sees %)', case when n = 0 then 'PASS' else 'FAIL' end, n;
end $$;
do $$ begin
  insert into glad_you_came(event_id, from_user, to_user)
    values ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019a5', '00000000-0000-0000-0000-0000000019a3');
  raise notice 'PROBE 119.x-non-member-send FAIL';
exception when others then raise notice 'PROBE 119.x-non-member-send PASS refused (%)', sqlerrm; end $$;
reset role;

set role anon;
do $$ declare n int; begin
  select count(*) into n from glad_you_came;
  raise notice 'PROBE 119.y-anon FAIL anon read % rows', n;
exception when others then raise notice 'PROBE 119.y-anon PASS refused (%)', sqlerrm; end $$;
reset role;

-- ---------------------------------------------------------------------------
-- D. One push per recipient per night, and the delivery hour.
-- ---------------------------------------------------------------------------
do $$ declare n int; begin
  select count(*) into n from glad_push_queue
   where event_id = '00000000-0000-0000-0000-0000000019c1' and to_user = '00000000-0000-0000-0000-0000000019a3';
  raise notice 'PROBE 119.z1-one-push % (% queue rows for Sam, 2 senders)', case when n = 1 then 'PASS' else 'FAIL' end, n;
end $$;

do $$
declare
  z text := 'Australia/Brisbane';
  got timestamptz;
  t record;
begin
  for t in select * from (values
      ('2026-11-13 13:00', '2026-11-13 14:00', '13:00 -> 14:00'),
      ('2026-11-13 21:30', '2026-11-14 09:00', '21:30 -> 09:00 next day'),
      ('2026-11-13 23:30', '2026-11-14 09:00', '23:30 -> 09:00 next day'),
      ('2026-11-14 00:45', '2026-11-14 09:00', '00:45 -> 09:00'),
      ('2026-11-13 09:00', '2026-11-13 10:00', '09:00 -> 10:00'),
      ('2026-11-13 20:59', '2026-11-13 21:00', '20:59 -> 21:00'),
      ('2026-11-13 21:00', '2026-11-14 09:00', '21:00 -> 09:00 next day')
    ) v(settled, expected, why)
  loop
    got := glad_push_deliver_at((t.settled::timestamp) at time zone z, z);
    raise notice 'PROBE 119.z2-hour % %', case when got = (t.expected::timestamp) at time zone z then 'PASS' else 'FAIL got '||(got at time zone z) end, t.why;
  end loop;
end $$;

-- Cleanup.
delete from events where id in ('00000000-0000-0000-0000-0000000019c1', '00000000-0000-0000-0000-0000000019c2', '00000000-0000-0000-0000-0000000019c3');
delete from rooms where id = '00000000-0000-0000-0000-0000000019b1';
