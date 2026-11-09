-- Probes for the 1.2.4 migrations on a schema-only replica. Every line of interest prints "PROBE <id> PASS|FAIL|INFO ...".
-- 2026-11-09 lane S: the original probes are kept verbatim; one block per change a-h of migration 115 is appended.
\set ON_ERROR_STOP 0
create or replace function pg_temp.act(u uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, false),
         set_config('request.jwt.claim.sub', u::text, false);
$$;

do $$
declare
  h uuid := '00000000-0000-0000-0000-0000000000a1';
  a uuid := '00000000-0000-0000-0000-0000000000a2';
  b uuid := '00000000-0000-0000-0000-0000000000a3';
  c uuid := '00000000-0000-0000-0000-0000000000a4';
  r uuid := '00000000-0000-0000-0000-0000000000b1';
  live uuid := '00000000-0000-0000-0000-0000000000c1';
  fut uuid := '00000000-0000-0000-0000-0000000000c2';
  ev record; n int; bal bigint; st text; ok boolean;
begin
  insert into auth.users(id) values (h),(a),(b),(c) on conflict do nothing;
  insert into users(id, display_name) values (h,'Host'),(a,'Alex'),(b,'Sam'),(c,'Jo') on conflict do nothing;
  insert into rooms(id, name, mascot_name, created_by, max_seats, seat_deposit_amount, seat_deposit_trigger, auto_close_hours)
    values (r, 'Probe Room', 'Tally', h, 3, 100, 'escrow', 8);
  insert into room_memberships(room_id, user_id, role, points_balance, membership_status)
    select r, u, case when u = h then 'host' else 'member' end, 500, 'active' from unnest(array[h,a,b,c]) u
    on conflict (room_id, user_id) do update set role = excluded.role, points_balance = 500, membership_status = 'active';
  insert into events(id, room_id, name, played_at, created_by) values (live, r, 'Tonight', now() - interval '1 hour', h);
  insert into events(id, room_id, name, played_at, created_by) values (fut, r, 'Next week', now() + interval '7 days', h);

  -- 107: active event priority
  perform pg_temp.act(a);
  select * into ev from get_active_event(r);
  raise notice 'PROBE 107.live %', case when ev.id = live then 'PASS live night returned while a future night exists' else 'FAIL got '||coalesce(ev.name,'nothing') end;
  update events set hidden_from_user_ids = array[b] where id = live;
  perform pg_temp.act(b);
  select * into ev from get_active_event(r);
  raise notice 'PROBE 107.hidden %', case when ev.id is distinct from live then 'PASS hidden member does not see it' else 'FAIL hidden member sees it' end;
  update events set hidden_from_user_ids = '{}' where id = live;

  -- 107: settle_event guards
  perform pg_temp.act(a);
  begin perform settle_event(live); raise notice 'PROBE 107.settle-member FAIL member settled';
  exception when others then raise notice 'PROBE 107.settle-member PASS refused (%)', sqlerrm; end;
  perform pg_temp.act(h);
  begin perform settle_event(fut); raise notice 'PROBE 107.settle-future FAIL settled a future night';
  exception when others then raise notice 'PROBE 107.settle-future PASS refused (%)', sqlerrm; end;
  perform settle_event(live);
  select * into ev from get_active_event(r);
  raise notice 'PROBE 107.after-settle INFO returns "%" (settled=%)', ev.name, ev.settled_at is not null;

  -- 113: capacity + deposits on the future night (max 3)
  perform pg_temp.act(a); perform claim_seat_with_deposit(fut);
  select points_balance into bal from room_memberships where room_id = r and user_id = a;
  select status into st from seat_deposits where event_id = fut and user_id = a;
  raise notice 'PROBE 113.claim %', case when bal = 400 and st = 'held' then 'PASS deposit held, balance 400' else 'FAIL bal '||bal||' status '||coalesce(st,'none') end;
  perform release_seat(fut, 'unclaimed');
  select points_balance into bal from room_memberships where room_id = r and user_id = a;
  select status into st from seat_deposits where event_id = fut and user_id = a;
  raise notice 'PROBE 113.release %', case when bal = 500 and st = 'returned' then 'PASS deposit returned' else 'FAIL bal '||bal||' status '||st end;
  perform claim_seat_with_deposit(fut);
  select state::text into st from event_rsvps where event_id = fut and member_id = a;
  select points_balance into bal from room_memberships where room_id = r and user_id = a;
  raise notice 'PROBE 113.reclaim %', case when st = 'claimed' and bal = 400 then 'PASS re-claim claims and re-holds' else 'FAIL rsvp '||coalesce(st,'none')||' bal '||bal end;
  perform pg_temp.act(b); perform claim_seat_with_deposit(fut);
  perform pg_temp.act(h); perform claim_seat_with_deposit(fut);
  perform pg_temp.act(c);
  begin perform claim_seat_with_deposit(fut); raise notice 'PROBE 113.full FAIL 4th claim on 3 seats accepted';
  exception when others then raise notice 'PROBE 113.full %', case when sqlerrm = 'night_full' then 'PASS night_full' else 'FAIL '||sqlerrm end; end;
  perform pg_temp.act(h);
  begin perform upsert_event_rsvp(fut, 'claimed', c); raise notice 'PROBE 113.host-for-member FAIL host claimed a 4th seat for Jo';
  exception when others then raise notice 'PROBE 113.host-for-member %', case when sqlerrm = 'night_full' then 'PASS night_full' else 'FAIL '||sqlerrm end; end;

  -- 114: cancel guards
  perform pg_temp.act(h);
  begin perform cancel_event(live);
    select count(*) into n from events where id = live;
    raise notice 'PROBE 114.cancel-started %', case when n = 0 then 'FAIL deleted a night that already started' else 'PASS kept' end;
  exception when others then raise notice 'PROBE 114.cancel-started PASS refused (%)', sqlerrm; end;
  perform cancel_event(fut);
  select count(*) into n from seat_deposits where event_id = fut;
  select points_balance into bal from room_memberships where room_id = r and user_id = b;
  raise notice 'PROBE 114.cancel-future %', case when bal = 500 then 'PASS deposits returned' else 'FAIL Sam balance '||bal end;
end $$;

-- =====================================================================
-- Lane S — migration 115. One block per change a-h.
-- =====================================================================
do $$
declare
  h uuid := '00000000-0000-0000-0000-0000000000a1';
  a uuid := '00000000-0000-0000-0000-0000000000a2';
  b uuid := '00000000-0000-0000-0000-0000000000a3';
  c uuid := '00000000-0000-0000-0000-0000000000a4';
  r2 uuid := '00000000-0000-0000-0000-0000000000e1';  -- future + settled<24h
  r3 uuid := '00000000-0000-0000-0000-0000000000e2';  -- settled<24h only
  r4 uuid := '00000000-0000-0000-0000-0000000000e3';  -- month-old stranded
  r5 uuid := '00000000-0000-0000-0000-0000000000e4';  -- release then kick
  r6 uuid := '00000000-0000-0000-0000-0000000000e5';  -- two future deposits then kick
  r7 uuid := '00000000-0000-0000-0000-0000000000e6';  -- forfeit terminal
  r8 uuid := '00000000-0000-0000-0000-0000000000e7';  -- started night: release + check-in
  r9 uuid := '00000000-0000-0000-0000-0000000000e8';  -- one upcoming night
  e_settled uuid := '00000000-0000-0000-0000-000000000f01';
  e_fut2    uuid := '00000000-0000-0000-0000-000000000f02';
  e_rec3    uuid := '00000000-0000-0000-0000-000000000f03';
  e_stale4  uuid := '00000000-0000-0000-0000-000000000f04';
  e_k5      uuid := '00000000-0000-0000-0000-000000000f05';
  e_k6a     uuid := '00000000-0000-0000-0000-000000000f06';
  e_k6b     uuid := '00000000-0000-0000-0000-000000000f07';
  e_f7      uuid := '00000000-0000-0000-0000-000000000f08';
  e_start8  uuid := '00000000-0000-0000-0000-000000000f09';
  e_fut8    uuid := '00000000-0000-0000-0000-000000000f0a';
  e_start9  uuid := '00000000-0000-0000-0000-000000000f0b';
  e_fut9    uuid := '00000000-0000-0000-0000-000000000f0c';
  e_fut9b   uuid := '00000000-0000-0000-0000-000000000f0d';
  v_now timestamptz := now();
  ev record;
  n int;
  bal bigint;
  st text;
  ts timestamptz;
  ph text;
  ok boolean;
begin
  insert into rooms(id, name, mascot_name, created_by, max_seats, seat_deposit_amount, seat_deposit_trigger, auto_close_hours)
    values (r2, 'S r2', 'Tally', h, 6, 100, 'escrow', 8),
           (r3, 'S r3', 'Tally', h, 6, 100, 'escrow', 8),
           (r4, 'S r4', 'Tally', h, 6, 100, 'escrow', 8),
           (r5, 'S r5', 'Tally', h, 6, 100, 'escrow', 8),
           (r6, 'S r6', 'Tally', h, 6, 100, 'escrow', 8),
           (r7, 'S r7', 'Tally', h, 6, 100, 'escrow', 8),
           (r8, 'S r8', 'Tally', h, 6, 100, 'escrow', 8),
           (r9, 'S r9', 'Tally', h, 6, 100, 'escrow', 8)
    on conflict (id) do nothing;
  insert into room_memberships(room_id, user_id, role, points_balance, membership_status)
    select rr, u, case when u = h then 'host' else 'member' end, 500, 'active'
    from unnest(array[r2,r3,r4,r5,r6,r7,r8,r9]) rr
    cross join unnest(array[h,a,b,c]) u
    on conflict (room_id, user_id) do update set role = excluded.role, points_balance = 500, membership_status = 'active';

  -- ---------------------------------------------------------------- a
  raise notice 'PROBE 115.a-phase %', case when
      public.night_phase(null, null, 8, v_now) = 'none'
      and public.night_phase(v_now + interval '1 day', null, 8, v_now) = 'upcoming'
      and public.night_phase(v_now - interval '1 hour', null, 8, v_now) = 'live'
      and public.night_phase(v_now - interval '8 hours', null, 8, v_now) = 'stranded'
      and public.night_phase(v_now - interval '9 hours', null, 8, v_now) = 'stranded'
      and public.night_phase(v_now - interval '2 hours', v_now - interval '1 hour', 8, v_now) = 'recap'
      and public.night_phase(v_now - interval '30 hours', v_now - interval '29 hours', 8, v_now) = 'past'
      and public.night_phase(v_now - interval '1 hour', null, 8) = 'live'
    then 'PASS none/upcoming/live/stranded(8h boundary)/recap/past + default p_now'
    else 'FAIL phase table does not match the rule' end;

  -- ---------------------------------------------------------------- b
  -- future + settled<24h -> exactly one row, and it is the future one.
  insert into events(id, room_id, name, played_at, settled_at, created_by)
    values (e_settled, r2, 'Last night', v_now - interval '30 hours', v_now - interval '1 hour', h);
  insert into events(id, room_id, name, played_at, created_by)
    values (e_fut2, r2, 'Next week', v_now + interval '7 days', h);
  insert into events(id, room_id, name, played_at, settled_at, created_by)
    values (e_rec3, r3, 'Last night', v_now - interval '3 hours', v_now - interval '1 hour', h);

  perform pg_temp.act(a);
  select count(*) into n from public.get_active_event(r2);
  select * into ev from public.get_active_event(r2);
  raise notice 'PROBE 115.b-future-and-settled %', case when n = 1 and ev.id = e_fut2
    then 'PASS exactly 1 row, the future night' else 'FAIL rows '||n||' got '||coalesce(ev.name,'nothing') end;

  select count(*) into n from public.get_active_event(r3);
  select * into ev from public.get_active_event(r3);
  raise notice 'PROBE 115.b-settled-only %', case when n = 1 and ev.id = e_rec3
    then 'PASS exactly 1 row, the settled night' else 'FAIL rows '||n||' got '||coalesce(ev.name,'nothing') end;

  -- ---------------------------------------------------------------- g
  -- an unsettled night a month old closes at played_at + the room's window,
  -- so it reads 'past', never 'recap'.
  insert into events(id, room_id, name, played_at, created_by)
    values (e_stale4, r4, 'Long ago', v_now - interval '30 days', h);
  perform pg_temp.act(a);
  select public.auto_close_stale_events(r4) into n;
  select settled_at into ts from events where id = e_stale4;
  select public.night_phase(e.played_at, e.settled_at, 8, v_now) into ph from events e where e.id = e_stale4;
  raise notice 'PROBE 115.g-autoclose-past %', case when n = 1
      and ts = (select played_at + interval '8 hours' from events where id = e_stale4)
      and ph = 'past'
    then 'PASS closed at played_at+8h, phase past' else 'FAIL closed '||coalesce(n::text,'?')||' settled '||coalesce(ts::text,'null')||' phase '||coalesce(ph,'?') end;

  -- ---------------------------------------------------------------- c
  -- release then kick: one deposit, credited exactly once.
  insert into events(id, room_id, name, played_at, created_by)
    values (e_k5, r5, 'Kick single', v_now + interval '3 days', h);
  perform pg_temp.act(a);
  perform public.claim_seat_with_deposit(e_k5);
  perform public.release_seat(e_k5, 'unclaimed');
  perform pg_temp.act(h);
  perform public.remove_room_member(r5, a);
  select points_balance into bal from room_memberships where room_id = r5 and user_id = a;
  raise notice 'PROBE 115.c-kick-single-credit %', case when bal = 500
    then 'PASS released-then-kicked deposit credited once (500)' else 'FAIL balance '||bal||' (expected 500)' end;

  -- two held future deposits, kicked: the credit is their sum.
  -- Two future nights in one room are impossible under the 115 guard, so the
  -- legacy rows are written with the guard off — that is the data the CTE
  -- exists for.
  alter table public.events disable trigger trg_check_one_upcoming_event;
  insert into events(id, room_id, name, played_at, created_by)
    values (e_k6a, r6, 'Kick A', v_now + interval '4 days', h);
  insert into events(id, room_id, name, played_at, created_by)
    values (e_k6b, r6, 'Kick B', v_now + interval '5 days', h);
  alter table public.events enable trigger trg_check_one_upcoming_event;
  perform pg_temp.act(b);
  perform public.claim_seat_with_deposit(e_k6a);
  perform public.claim_seat_with_deposit(e_k6b);
  select points_balance into bal from room_memberships where room_id = r6 and user_id = b;
  raise notice 'PROBE 115.c-kick-two-held INFO after two claims balance % (expected 300)', bal;
  perform pg_temp.act(h);
  perform public.remove_room_member(r6, b);
  select points_balance into bal from room_memberships where room_id = r6 and user_id = b;
  select count(*) into n from seat_deposits where event_id in (e_k6a, e_k6b) and status = 'returned';
  raise notice 'PROBE 115.c-kick-sum %', case when bal = 500 and n = 2
    then 'PASS 300 held + 100 + 100 = 500, both rows credited, neither twice' else 'FAIL balance '||bal||' returned rows '||n end;

  -- ---------------------------------------------------------------- d
  -- forfeit is terminal for the member; release stays allowed.
  insert into events(id, room_id, name, played_at, created_by)
    values (e_f7, r7, 'Forfeit night', v_now + interval '3 days', h);
  perform pg_temp.act(c);
  perform public.claim_seat_with_deposit(e_f7);
  perform pg_temp.act(h);
  perform public.forfeit_seat_deposit(e_f7, c);
  perform pg_temp.act(c);
  begin
    perform public.claim_seat_with_deposit(e_f7);
    raise notice 'PROBE 115.d-claim-after-forfeit FAIL the member re-took a forfeited seat';
  exception when others then
    raise notice 'PROBE 115.d-claim-after-forfeit %', case when sqlerrm like 'forfeited_seat%' then 'PASS forfeited_seat' else 'FAIL '||sqlerrm end;
  end;
  begin
    perform public.upsert_event_rsvp(e_f7, 'claimed');
    raise notice 'PROBE 115.d-upsert-after-forfeit FAIL upsert re-claimed a forfeited seat';
  exception when others then
    raise notice 'PROBE 115.d-upsert-after-forfeit %', case when sqlerrm like 'forfeited_seat%' then 'PASS forfeited_seat' else 'FAIL '||sqlerrm end;
  end;
  begin
    perform public.release_seat(e_f7, 'unclaimed');
    raise notice 'PROBE 115.d-release-after-forfeit PASS release still allowed';
  exception when others then
    raise notice 'PROBE 115.d-release-after-forfeit FAIL release refused (%)', sqlerrm;
  end;

  -- ---------------------------------------------------------------- e
  -- release on a started night is refused.
  insert into events(id, room_id, name, played_at, created_by)
    values (e_start8, r8, 'Tonight', v_now - interval '1 hour', h);
  perform pg_temp.act(a);
  begin
    perform public.release_seat(e_start8, 'unclaimed');
    raise notice 'PROBE 115.e-release-after-start FAIL released a started night';
  exception when others then
    raise notice 'PROBE 115.e-release-after-start %', case when sqlerrm = 'night_started' then 'PASS night_started' else 'FAIL '||sqlerrm end;
  end;

  -- ---------------------------------------------------------------- f
  -- check-in after the start still works; before the start it is too early.
  perform public.claim_seat_with_deposit(e_start8);
  perform public.check_in_seat(e_start8);
  select status into st from seat_deposits where event_id = e_start8 and user_id = a;
  select points_balance into bal from room_memberships where room_id = r8 and user_id = a;
  raise notice 'PROBE 115.f-checkin-live %', case when st = 'returned' and bal = 500
    then 'PASS check-in on a started night returns the deposit' else 'FAIL status '||coalesce(st,'none')||' balance '||bal end;

  insert into events(id, room_id, name, played_at, created_by)
    values (e_fut8, r8, 'Next week', v_now + interval '2 days', h);
  perform public.claim_seat_with_deposit(e_fut8);
  begin
    perform public.check_in_seat(e_fut8);
    raise notice 'PROBE 115.f-checkin-too-early FAIL checked in before the night started';
  exception when others then
    raise notice 'PROBE 115.f-checkin-too-early %', case when sqlerrm = 'too_early' then 'PASS too_early' else 'FAIL '||sqlerrm end;
  end;

  -- ---------------------------------------------------------------- h
  -- the next night can be added while tonight is running; a second future
  -- night is refused with the friendly code; the frozen index is gone.
  insert into events(id, room_id, name, played_at, created_by)
    values (e_start9, r9, 'Tonight', v_now - interval '1 hour', h);
  begin
    insert into events(id, room_id, name, played_at, created_by)
      values (e_fut9, r9, 'Next week', v_now + interval '7 days', h);
    raise notice 'PROBE 115.h-add-during-night PASS next night added while tonight is live';
  exception when others then
    raise notice 'PROBE 115.h-add-during-night FAIL %', sqlerrm;
  end;
  begin
    insert into events(id, room_id, name, played_at, created_by)
      values (e_fut9b, r9, 'Two weeks', v_now + interval '8 days', h);
    raise notice 'PROBE 115.h-one-upcoming FAIL a second future night was accepted';
  exception when others then
    raise notice 'PROBE 115.h-one-upcoming %', case when sqlerrm like 'one_upcoming_night%' then 'PASS one_upcoming_night' else 'FAIL '||sqlerrm end;
  end;
  select count(*) into n from pg_indexes where schemaname = 'public' and indexname = 'one_upcoming_event_per_room';
  raise notice 'PROBE 115.h-no-frozen-index %', case when n = 0 then 'PASS the now()-frozen index is gone' else 'FAIL index still present' end;
end $$;
