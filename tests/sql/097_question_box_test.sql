-- Behavioural checks for migration 097 against the shadow DB.
-- Every check raises on failure; the script prints "097 OK" at the end.
\set ON_ERROR_STOP 1

-- Fixture: host H, members A, B, C, outsider X.
insert into auth.users values
  ('00000000-0000-0000-0000-0000000000a0'), ('00000000-0000-0000-0000-0000000000a1'),
  ('00000000-0000-0000-0000-0000000000a2'), ('00000000-0000-0000-0000-0000000000a3'),
  ('00000000-0000-0000-0000-0000000000a9');
insert into public.users (id, display_name) values
  ('00000000-0000-0000-0000-0000000000a0', 'Hana'), ('00000000-0000-0000-0000-0000000000a1', 'Alex'),
  ('00000000-0000-0000-0000-0000000000a2', 'Bea'),  ('00000000-0000-0000-0000-0000000000a3', 'Cal'),
  ('00000000-0000-0000-0000-0000000000a9', 'Xavier');

insert into public.rooms (id, name, created_by) values
  ('10000000-0000-0000-0000-000000000001', 'Room', '00000000-0000-0000-0000-0000000000a0');
insert into public.room_memberships (room_id, user_id, role, joined_at) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a0', 'host', now() - interval '9 days'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a1', 'member', now() - interval '8 days'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a2', 'member', now() - interval '7 days'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-0000000000a3', 'member', now() - interval '6 days');

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claims', json_build_object('sub', p)::text, false);
$$;

do $$
declare
  v_room uuid := '10000000-0000-0000-0000-000000000001';
  h uuid := '00000000-0000-0000-0000-0000000000a0';
  a uuid := '00000000-0000-0000-0000-0000000000a1';
  b uuid := '00000000-0000-0000-0000-0000000000a2';
  c uuid := '00000000-0000-0000-0000-0000000000a3';
  x uuid := '00000000-0000-0000-0000-0000000000a9';
  v_event uuid := '20000000-0000-0000-0000-000000000001';
  v_t0 timestamptz := now() - interval '2 hours';
  v_turn uuid;
  v_n integer;
  v_rec record;
  v_rot uuid[];
begin
  -- Seeded house deck on the new room (trigger), defaults on.
  select count(*) into v_n from public.room_questions where room_id = v_room and source = 'house';
  assert v_n = 40, format('house deck seeded: %s', v_n);
  select count(*) into v_n from public.room_questions where room_id = v_room and source = 'house' and tag = 'deep';
  assert v_n = 20, 'deck 20 deep';
  assert (select question_box_enabled and not question_show_author and question_house_deck
                 and question_cadence_minutes = 20 and question_speaking_light
            from public.rooms where id = v_room), 'room defaults';
  assert public.seed_room_house_deck(v_room) = 0, 'seed idempotent';

  insert into public.events (id, room_id, name, played_at) values (v_event, v_room, 'Night', v_t0);
  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at) values
    (v_event, v_room, b, 'claimed', v_t0 - interval '3 days'),
    (v_event, v_room, a, 'claimed', v_t0 - interval '2 days'),
    (v_event, v_room, h, 'claimed', v_t0 - interval '1 days');

  -- Rotation fallback (no bank): claim order B, A, H.
  v_rot := public.question_box_rotation(v_event);
  assert v_rot = array[b, a, h], format('claim-order fallback %s', v_rot);

  -- Withdrawals: C first, then A, then A again. Rotation = withdrawers by first withdrawal.
  insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_at) values
    (v_room, v_event, c, 'casino_withdrawal', -100, v_t0 + interval '1 min'),
    (v_room, v_event, a, 'casino_withdrawal', -100, v_t0 + interval '2 min'),
    (v_room, v_event, a, 'casino_withdrawal', -50,  v_t0 + interval '30 min'),
    (v_room, v_event, b, 'round_score', 1, v_t0 + interval '0 min');
  v_rot := public.question_box_rotation(v_event);
  assert v_rot = array[c, a], format('withdrawal rotation %s', v_rot);

  -- Member question (A) via RPC; one per event; drawn first.
  perform pg_temp.as_user(a);
  perform public.submit_member_question(v_event, '  What would you be famous for in 1850?  ');
  perform public.submit_member_question(v_event, 'What would you be famous for in 1850? (edited)');
  select count(*) into v_n from public.room_questions where event_id = v_event and source = 'member';
  assert v_n = 1, 'one member question per event';
  assert public.get_my_member_question(v_event) = 'What would you be famous for in 1850? (edited)', 'prefill';

  -- Opener: host, at start time.
  v_turn := public.question_box_advance(v_event, v_t0 - interval '1 min');
  assert v_turn is null, 'no turn before start';
  v_turn := public.question_box_advance(v_event, v_t0);
  select * into v_rec from public.question_turns where id = v_turn;
  assert v_rec.reader_id = h and v_rec.kind = 'opener', 'host opener';
  assert v_rec.question_text = 'What would you be famous for in 1850? (edited)', 'member question drawn first';
  assert v_rec.push_status in ('skipped_disabled', 'skipped_no_pg_net'), format('push disabled without secret: %s', v_rec.push_status);

  -- Fixed interval only: nothing at +19m, turn at +20m to first withdrawer (C).
  assert public.question_box_advance(v_event, v_t0 + interval '19 min') is null, 'no turn before interval';
  v_turn := public.question_box_advance(v_event, v_t0 + interval '20 min');
  assert (select reader_id from public.question_turns where id = v_turn) = c, 'interval -> C';
  assert public.question_box_advance(v_event, v_t0 + interval '39 min') is null, 'measured from previous turn';
  v_turn := public.question_box_advance(v_event, v_t0 + interval '40 min');
  assert (select reader_id from public.question_turns where id = v_turn) = a, 'interval -> A';
  v_turn := public.question_box_advance(v_event, v_t0 + interval '60 min');
  assert (select reader_id from public.question_turns where id = v_turn) = c, 'wraps -> C';

  -- Reader-only visibility. C is the reader; A (member) sees nothing; host sees it.
  perform pg_temp.as_user(c);
  select * into v_rec from public.get_question_box_state(v_event);
  assert v_rec.turn_id = v_turn and v_rec.is_reader, 'reader sees card';
  assert v_rec.asked_by is null, 'anonymous by default';
  assert v_rec.answer_first_display_name = 'Alex', format('answer-first %s', v_rec.answer_first_display_name);
  perform pg_temp.as_user(a);
  select count(*) into v_n from public.get_question_box_state(v_event);
  assert v_n = 0, 'other member sees nothing';
  perform pg_temp.as_user(h);
  select * into v_rec from public.get_question_box_state(v_event);
  assert v_rec.turn_id = v_turn and not v_rec.is_reader and v_rec.reader_display_name = 'Cal', 'host fallback';

  -- Pass hands to next (A); same question; does not consume the timer.
  perform pg_temp.as_user(c);
  v_turn := public.respond_question_turn(v_turn, 'pass');
  select * into v_rec from public.question_turns where id = v_turn;
  assert v_rec.reader_id = a and v_rec.kind = 'pass', 'pass -> A';
  perform pg_temp.as_user(a);
  perform public.respond_question_turn(v_turn, 'done');
  select count(*) into v_n from public.get_question_box_state(v_event);
  assert v_n = 0, 'done closes card';

  -- Outsider cannot tick, submit, or read.
  perform pg_temp.as_user(x);
  begin
    perform public.question_box_tick(v_event);
    assert false, 'outsider tick should fail';
  exception when insufficient_privilege then null;
  end;

  -- Show who asked: host turns it on -> asked_by set for a member question.
  perform pg_temp.as_user(h);
  perform public.set_question_box_settings(v_room, true, true, true, 0, true);
  perform pg_temp.as_user(b);
  perform public.submit_member_question(v_event, 'Who here would survive a reality show?');
  update public.question_turns set read_at = now() where event_id = v_event and read_at is null and passed_at is null;
  -- cadence 0 = off: no timed turns.
  assert public.question_box_advance(v_event, v_t0 + interval '5 hours') is null, 'cadence off';
  perform pg_temp.as_user(h);
  perform public.set_question_box_settings(v_room, true, true, true, 10, true);
  v_turn := public.question_box_advance(v_event, v_t0 + interval '5 hours');
  perform pg_temp.as_user((select reader_id from public.question_turns where id = v_turn));
  select * into v_rec from public.get_question_box_state(v_event);
  assert v_rec.asked_by = 'Bea', format('asked_by when show-author on: %s', v_rec.asked_by);

  -- Host list includes author; members cannot select room_questions directly (policy check below).
  perform pg_temp.as_user(h);
  select count(*) into v_n from public.get_room_questions(v_room) where author_id is not null;
  assert v_n = 2, format('host sees authors: %s', v_n);
  perform pg_temp.as_user(a);
  begin
    perform public.get_room_questions(v_room);
    assert false, 'member get_room_questions should fail';
  exception when insufficient_privilege then null;
  end;

  -- Settled -> turns stop.
  update public.events set settled_at = now() where id = v_event;
  assert public.question_box_advance(v_event, v_t0 + interval '9 hours') is null, 'stops at settle';

  -- Currently Into: trigger stamps updated_at; 30-day filter.
  perform pg_temp.as_user(a);
  perform public.set_currently_into(v_room, 'Learning to surf, badly — and also some extra text past sixty chars');
  select * into v_rec from public.get_my_currently_into(v_room);
  assert char_length(v_rec.text) = 60 and v_rec.updated_at > now() - interval '1 minute', 'currently into write';
  perform public.set_currently_into(v_room, 'x');
  update public.room_memberships set preferences_conversation_prompt_updated_at = now() - interval '31 days'
   where user_id = b and room_id = v_room;
  select count(*) into v_n from public.get_event_currently_into(v_event) where member_id = a;
  assert v_n = 1, 'fresh shows';
  select count(*) into v_n from public.get_event_currently_into(v_event) where member_id = b;
  assert v_n = 0, 'stale/empty hidden';

  -- Device tokens.
  perform public.register_device_token(repeat('ab', 32), 'sandbox', '1.0');
  perform public.register_device_token(repeat('ab', 32), 'sandbox', '1.0');
  select count(*) into v_n from public.device_tokens where user_id = a and is_active;
  assert v_n = 1, 'token upsert';
  perform pg_temp.as_user(c);
  perform public.register_device_token(repeat('ab', 32), 'sandbox', '1.0');
  assert not (select is_active from public.device_tokens where user_id = a), 'token moves to new user';

  -- Account deletion (096 path: delete public.users): authored rows go.
  delete from public.users where id = b;
  select count(*) into v_n from public.room_questions where author_id = b;
  assert v_n = 0, 'deleted member questions removed';
  select count(*) into v_n from public.room_questions q where q.source = 'member' and q.author_id is null;
  assert v_n = 0, 'no orphaned member questions';

  raise notice '097 OK';
end $$;

-- Idempotency: re-applying 097 must succeed (run by the wrapper).

-- Table-level RLS, as the authenticated role (superuser bypasses RLS above).
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a1"}', false);
set role authenticated;
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.room_questions;
  assert v_n = 0, format('member must not select room_questions directly: %s', v_n);
  select count(*) into v_n from public.question_turns where reader_id <> '00000000-0000-0000-0000-0000000000a1';
  assert v_n = 0, 'member sees only own turns';
  begin
    insert into public.room_questions (room_id, source, text) values ('10000000-0000-0000-0000-000000000001', 'host', 'sneaky');
    assert false, 'member inserted host question';
  exception when insufficient_privilege then null;
  end;
  raise notice '097 RLS OK';
end $$;
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000000a0"}', false);
set role authenticated;
do $$
declare v_n integer;
begin
  select count(*) into v_n from public.room_questions;
  assert v_n > 0, 'host selects room questions';
  raise notice '097 host RLS OK';
end $$;
reset role;
