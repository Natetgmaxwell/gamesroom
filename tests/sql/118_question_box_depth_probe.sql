-- Probe for migration 118 (one deeper Question Box question per night, the
-- floor to newer members first). Run against the shadow database
-- (tests/sql/097_shadow_prereqs.sql, whose auth.users is a one-column stub,
-- then migrations through 118), as a trusted role (psql as postgres, no
-- request.jwt.claims). NEVER against live: it inserts a
-- fixture, but it is wrapped in begin ... rollback so nothing is kept.
--
--   psql "$SHADOW_DB_URL" -v ON_ERROR_STOP=1 -f tests/sql/118_question_box_depth_probe.sql
--
-- Every check raises on failure; the last line prints "118 PROBE OK".
-- Checks:
--   1. every room has 20 deep house questions (seed + backfill)
--   2. turn rule: deep is turn 4 (3 served before it), before 60 minutes
--   3. 60-minute rule: deep is turn 3 at played_at + 60 with a 30-min cadence
--   4. exactly one deep question per night, never on the opener, never
--      before turn 4 or 60 minutes
--   5. a first-night member reads before a 10-night regular
--   6. no back-to-back reader, opener included
--   7. upsert_room_question: new questions are light; p_depth sets deep;
--      an edit without p_depth keeps the depth
\set ON_ERROR_STOP 1
begin;

insert into auth.users values
  ('00000000-0000-0000-0000-000000000c00'), ('00000000-0000-0000-0000-000000000c01'),
  ('00000000-0000-0000-0000-000000000c02'), ('00000000-0000-0000-0000-000000000c03');
insert into public.users (id, display_name) values
  ('00000000-0000-0000-0000-000000000c00', 'Hana'),   -- host
  ('00000000-0000-0000-0000-000000000c01', 'Reg'),    -- 10-night regular
  ('00000000-0000-0000-0000-000000000c02', 'Nina'),   -- first night
  ('00000000-0000-0000-0000-000000000c03', 'Bo');     -- 3 nights

insert into public.rooms (id, name, created_by) values
  ('11800000-0000-0000-0000-000000000001', 'Turn rule', '00000000-0000-0000-0000-000000000c00'),
  ('11800000-0000-0000-0000-000000000002', 'Hour rule', '00000000-0000-0000-0000-000000000c00');
update public.rooms set question_cadence_minutes = 10, auto_close_hours = 8
 where id = '11800000-0000-0000-0000-000000000001';
update public.rooms set question_cadence_minutes = 30, auto_close_hours = 8
 where id = '11800000-0000-0000-0000-000000000002';

insert into public.room_memberships (room_id, user_id, role, joined_at)
  select r.id, u.id, case when u.id = '00000000-0000-0000-0000-000000000c00'::uuid then 'host' else 'member' end,
         now() - interval '400 days'
    from public.rooms r, public.users u
   where r.id in ('11800000-0000-0000-0000-000000000001', '11800000-0000-0000-0000-000000000002')
     and u.id in ('00000000-0000-0000-0000-000000000c00', '00000000-0000-0000-0000-000000000c01',
                  '00000000-0000-0000-0000-000000000c02', '00000000-0000-0000-0000-000000000c03');

insert into public.device_tokens (user_id, device_token) values
  ('00000000-0000-0000-0000-000000000c00', repeat('a', 64)),
  ('00000000-0000-0000-0000-000000000c01', repeat('b', 64)),
  ('00000000-0000-0000-0000-000000000c02', repeat('c', 64)),
  ('00000000-0000-0000-0000-000000000c03', repeat('d', 64));

do $$
declare
  h uuid := '00000000-0000-0000-0000-000000000c00';
  reg uuid := '00000000-0000-0000-0000-000000000c01';
  nina uuid := '00000000-0000-0000-0000-000000000c02';
  bo uuid := '00000000-0000-0000-0000-000000000c03';
  r1 uuid := '11800000-0000-0000-0000-000000000001';
  r2 uuid := '11800000-0000-0000-0000-000000000002';
  e1 uuid := '11800000-0000-0000-0000-0000000000e1';
  e2 uuid := '11800000-0000-0000-0000-0000000000e2';
  t0 timestamptz := date_trunc('minute', now()) - interval '6 hours';
  v_room uuid;
  v_event uuid;
  v_turn uuid;
  v_n integer;
  v_m integer;
  v_q uuid;
  v_rec record;
  v_readers uuid[];
  i integer;
begin
  -- 1. Seeded decks.
  for v_room in select unnest(array[r1, r2]) loop
    select count(*) into v_n from public.room_questions
     where room_id = v_room and source = 'house' and depth = 'deep';
    assert v_n = 20, format('room %s has %s deep house questions, want 20', v_room, v_n);
    select count(*) into v_n from public.room_questions
     where room_id = v_room and source = 'house' and depth = 'light';
    assert v_n = 40, format('room %s has %s light house questions, want 40', v_room, v_n);
  end loop;
  select count(*) into v_n from public.rooms r
   where (select count(*) from public.room_questions q
           where q.room_id = r.id and q.source = 'house' and q.depth = 'deep') <> 20;
  assert v_n = 0, format('%s rooms do not have exactly 20 deep house questions', v_n);

  -- History: Reg 10 nights and Bo 3 nights in both rooms before tonight. Nina none.
  for v_room in select unnest(array[r1, r2]) loop
    for i in 1..10 loop
      insert into public.events (room_id, name, played_at, settled_at)
      values (v_room, 'Past ' || i, t0 - make_interval(days => 7 * i), t0 - make_interval(days => 7 * i) + interval '4 hours')
      returning id into v_event;
      insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_at)
      values (v_room, v_event, reg, 'casino_withdrawal', -100, t0 - make_interval(days => 7 * i));
      if i <= 3 then
        insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_at)
        values (v_room, v_event, bo, 'casino_withdrawal', -100, t0 - make_interval(days => 7 * i));
      end if;
    end loop;
  end loop;

  -- Tonight in both rooms: Reg, Bo, Nina take chips in that order.
  insert into public.events (id, room_id, name, played_at) values (e1, r1, 'Tonight', t0), (e2, r2, 'Tonight', t0);
  for v_event in select unnest(array[e1, e2]) loop
    insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_at)
    select e.room_id, e.id, m.who, 'casino_withdrawal', -100, t0 + m.off
      from public.events e,
           (values (reg, interval '1 min'), (bo, interval '2 min'), (nina, interval '3 min')) as m(who, off)
     where e.id = v_event;
  end loop;

  select nights into v_n from public.question_box_nights_attended(e1) where member_id = reg;
  assert v_n = 10, format('Reg nights %s, want 10', v_n);
  assert not exists (select 1 from public.question_box_nights_attended(e1) where member_id = nina),
    'Nina has no nights before tonight';

  -- 2. Turn rule: room 1, cadence 10. Opener at +5 (three arrived), then
  --    every 10 minutes. Each turn is read straight away so the box stays awake.
  for i in 0..15 loop
    v_turn := public.question_box_advance(e1, t0 + make_interval(mins => 5 + 10 * i));
    assert v_turn is not null, format('room 1: no turn at +%s min', 5 + 10 * i);
    update public.question_turns set read_at = t0 + make_interval(mins => 6 + 10 * i) where id = v_turn;
  end loop;

  -- 3. Hour rule: room 2, cadence 30. Opener at +5, then +35, +65, ...
  for i in 0..6 loop
    v_turn := public.question_box_advance(e2, t0 + make_interval(mins => 5 + 30 * i));
    assert v_turn is not null, format('room 2: no turn at +%s min', 5 + 30 * i);
    update public.question_turns set read_at = t0 + make_interval(mins => 6 + 30 * i) where id = v_turn;
  end loop;

  for v_rec in
    select e.id, e.played_at, e.question_deep_at,
           array_agg(q.depth order by t.created_at) as depths,
           array_agg(t.reader_id order by t.created_at) as readers,
           array_agg(t.kind order by t.created_at) as kinds,
           array_agg(t.created_at order by t.created_at) as ats
      from public.events e
      join public.question_turns t on t.event_id = e.id
      join public.room_questions q on q.id = t.question_id
     where e.id in (e1, e2)
     group by e.id, e.played_at, e.question_deep_at
  loop
    raise notice '% depths %', v_rec.id, v_rec.depths;
    -- 4. Exactly one deep, not the opener, not before turn 4 or 60 minutes.
    select count(*) into v_n from unnest(v_rec.depths) d where d = 'deep';
    assert v_n = 1, format('event %s served %s deep questions, want 1', v_rec.id, v_n);
    v_m := array_position(v_rec.depths, 'deep');
    assert v_rec.kinds[v_m] <> 'opener', 'the opener is never deep';
    assert v_m >= 4 or v_rec.ats[v_m] >= v_rec.played_at + interval '60 minutes',
      format('event %s: deep at turn %s, %s after the start', v_rec.id, v_m, v_rec.ats[v_m] - v_rec.played_at);
    assert v_rec.question_deep_at = v_rec.ats[v_m], 'question_deep_at marks the deep turn';
    for i in 1..cardinality(v_rec.depths) loop
      if i <> v_m then
        assert v_rec.depths[i] = 'light', format('event %s turn %s is not light', v_rec.id, i);
      end if;
    end loop;
    if v_rec.id = e1 then
      assert v_m = 4, format('turn rule: deep at turn %s, want 4', v_m);
      assert v_rec.ats[v_m] < v_rec.played_at + interval '60 minutes', 'turn rule fired before the hour';
    else
      assert v_m = 3, format('hour rule: deep at turn %s, want 3', v_m);
      assert v_rec.ats[v_m] = v_rec.played_at + interval '65 minutes', 'hour rule: first turn past 60 minutes';
    end if;
    -- 5. The first-night member reads the first interval turn.
    assert v_rec.readers[1] = h, 'host reads the opener';
    assert v_rec.readers[2] = nina,
      format('event %s first interval reader %s, want Nina (first night) over Reg (10 nights)', v_rec.id, v_rec.readers[2]);
    -- 6. No back-to-back reader.
    for i in 2..cardinality(v_rec.readers) loop
      assert v_rec.readers[i] <> v_rec.readers[i - 1],
        format('event %s: %s read turns %s and %s in a row', v_rec.id, v_rec.readers[i], i - 1, i);
    end loop;
  end loop;

  -- Room 1 order: Nina (0 nights), Bo (3), Reg (10), then round two the same way.
  select array_agg(t.reader_id order by t.created_at) into v_readers
    from public.question_turns t where t.event_id = e1 and t.kind = 'interval';
  assert v_readers[1:4] = array[nina, bo, reg, nina],
    format('room 1 interval readers %s, want Nina, Bo, Reg, Nina', v_readers[1:4]);

  -- 7. Host add / edit.
  perform set_config('request.jwt.claims', json_build_object('sub', h, 'role', 'authenticated')::text, true);
  v_q := public.upsert_room_question(r1, null, 'Light by default?', null);
  assert (select depth from public.room_questions where id = v_q) = 'light', 'added question defaults to light';
  v_q := public.upsert_room_question(r1, null, 'Marked deeper?', null, 'deep');
  assert (select depth from public.room_questions where id = v_q) = 'deep', 'p_depth deep sets deep';
  perform public.upsert_room_question(r1, v_q, 'Marked deeper, edited?', null);
  assert (select depth from public.room_questions where id = v_q) = 'deep', 'edit without p_depth keeps depth';
  begin
    perform public.upsert_room_question(r1, null, 'Bad depth?', null, 'level3');
    assert false, 'invalid depth accepted';
  exception when sqlstate '22023' then null;
  end;
  perform set_config('request.jwt.claims', '', true);

  raise notice '118 PROBE OK';
end $$;

rollback;
