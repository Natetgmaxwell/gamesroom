-- 118: one deeper Question Box question per night, and the floor goes to
-- the newer people first.
--
-- Task 2 of the 1.2.5 room-dynamics work (brain page
-- originals/2026-11-10-games-room-room-dynamics-psychology).
--
-- Why
--   People expect a deeper question to be more awkward than it turns out
--   to be, and underestimate how close they feel afterwards (Kardas, Kumar
--   & Epley 2022). Closeness grows in steps (Aron et al. 1997). And the
--   newest person at the table gains most from being handed the floor once.
--
-- What this migration changes
--   1. room_questions.depth ('light' | 'deep', default 'light'). Every
--      existing row is light, including the 097 house rows tagged 'deep'
--      (those are debate questions, not this). The old tag is untouched.
--   2. public.question_box_deep_deck() - 20 deeper house questions, and a
--      copy in every room (source 'house', depth 'deep'). New rooms get
--      them from seed_room_house_deck. Mirrored in
--      GamesRoom/Models/QuestionBoxHouseDeck.swift (QuestionBoxDeepDeck);
--      TestsQuestionDepth.swift asserts the two copies match.
--   3. events.question_deep_at - when tonight's deeper question was served.
--      Written only by question_box_advance. This is the "once per night".
--   4. public.question_box_draw(room, event, depth) - the 097 draw order
--      (member, then host, then house), within one depth. The 2-arg draw
--      stays, as the light draw.
--   5. public.question_box_nights_attended(event) - nights each member has
--      been at the table in this room before tonight. "Been at the table"
--      is the 111 arrival signal: a withdrawal on the night, or a checked-in
--      seat deposit that was not forfeited.
--   6. public.question_box_advance - two rules on top of the 111 body:
--      Pacing (twin: QuestionBoxPacing):
--        the opener is light; once per night, when 3 turns have been served
--        (opener + interval; passes do not count) or 60 minutes have passed
--        since played_at, whichever comes first, the next question is deep;
--        then light again. A room with no deep question left stays light.
--      Reader (twin: QuestionBoxReaderPick), among the reachable people in
--      the rotation, never the reader of the last turn:
--        fewest turns read tonight, then fewest nights attended in this room,
--        then rotation order from the cursor. A table of equals keeps the
--        111 order. When the only reachable person read the last turn, no
--        turn is written.
--   7. public.upsert_room_question gains p_depth (default null: a new
--      question is light, an edited one keeps its depth). The add sheet's
--      grey "Deeper" toggle sets it.
--   8. public.get_room_questions returns depth (the host editor needs it
--      to show the toggle's state).
--
-- Nothing here says "deep" to anyone: the reader card is unchanged, the
-- question just arrives.
--
-- Started from: question_box_advance = 111 (the live body plus 111; 115
-- does not touch it). question_box_draw, upsert_room_question,
-- get_room_questions and seed_room_house_deck = 097 (no later migration
-- redefines them; 104 only revokes grants, preserved here).
--
-- NOT applied to live. TARS applies it after review:
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/118_question_box_depth.sql
-- Idempotent: add-column-if-not-exists, create-or-replace, drop-if-exists.
-- Rollback: restore the 111 question_box_advance, the 097 draw / upsert /
-- get_room_questions / seed_room_house_deck bodies, drop the 3-arg draw,
-- question_box_nights_attended and question_box_deep_deck, delete the
-- house rows with depth = 'deep', drop the two columns.
begin;

-- =================================================================
-- 1. Depth on questions, and the once-per-night marker
-- =================================================================
alter table public.room_questions
  add column if not exists depth text not null default 'light';

do $$ begin
  alter table public.room_questions
    add constraint room_questions_depth_check check (depth in ('light', 'deep'));
exception when duplicate_object then null; end $$;

create index if not exists room_questions_pool_depth_idx
  on public.room_questions(room_id, depth, drawn_at);

alter table public.events
  add column if not exists question_deep_at timestamptz;

comment on column public.room_questions.depth is
  '118: light (default) or deep. question_box_advance serves one deep question per night, after the table has warmed up. Never shown to members.';
comment on column public.events.question_deep_at is
  '118: when tonight''s deeper Question Box question was served. Written only by question_box_advance; non-null means the rest of the night is light.';

-- =================================================================
-- 2. The deeper house questions
-- =================================================================
-- Personal, not therapy, answerable in about a minute. No trauma,
-- politics, sex or money.
create or replace function public.question_box_deep_deck()
returns table (text text)
language sql
immutable
set search_path = ''
as $$
  select d.text from (values
    (1, 'What''s something you''re quietly proud of this year?'),
    (2, 'Who''s someone who changed your mind about something, and what was it?'),
    (3, 'What''s a small thing that reliably makes your week better?'),
    (4, 'What did you want to be when you were ten, and how close did you get?'),
    (5, 'Who taught you something you still use every week?'),
    (6, 'What''s a skill you''d love to be properly good at in five years?'),
    (7, 'What''s a place that feels like home that isn''t your house?'),
    (8, 'When did you last surprise yourself?'),
    (9, 'What''s a compliment you got years ago that you still remember?'),
    (10, 'What''s a meal that means more to you than it probably should?'),
    (11, 'Which friend would you call first with good news, and why them?'),
    (12, 'What''s a tradition from growing up that you''d keep going?'),
    (13, 'What''s something you''re looking forward to that nobody here knows about yet?'),
    (14, 'What''s the best decision you ever made on a whim?'),
    (15, 'What''s something you do where you completely lose track of time?'),
    (16, 'Who made a bigger difference to you than they probably know?'),
    (17, 'What''s a risk you''re glad you took?'),
    (18, 'What''s a habit you picked up from a parent or grandparent?'),
    (19, 'What would ten-year-old you be most surprised by about your life now?'),
    (20, 'What''s a song that takes you straight back to one particular moment?')
  ) as d(ord, text)
  order by d.ord;
$$;

-- New rooms: the 40 light house questions (097) plus the 20 deeper ones.
-- The light deck still seeds only into a room with no light house rows;
-- the deeper ones seed by text, so a re-run adds nothing twice.
create or replace function public.seed_room_house_deck(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
  v_more  integer := 0;
begin
  if not exists (
    select 1 from public.room_questions
     where room_id = p_room_id and source = 'house' and depth = 'light'
  ) then
    insert into public.room_questions (room_id, source, text, tag)
      select p_room_id, 'house', d.text, d.tag from public.question_box_house_deck() d;
    get diagnostics v_count = row_count;
  end if;
  insert into public.room_questions (room_id, source, text, depth)
    select p_room_id, 'house', d.text, 'deep'
      from public.question_box_deep_deck() d
     where not exists (
       select 1 from public.room_questions q
        where q.room_id = p_room_id and q.source = 'house' and q.text = d.text
     );
  get diagnostics v_more = row_count;
  return v_count + v_more;
end;
$$;

revoke all on function public.seed_room_house_deck(uuid) from public, anon, authenticated;
grant execute on function public.seed_room_house_deck(uuid) to service_role;

-- Backfill: every existing room gets its own copy of the deeper questions.
-- Only the deeper ones: a room whose host cleared house questions does not
-- get the light deck back.
insert into public.room_questions (room_id, source, text, depth)
  select r.id, 'house', d.text, 'deep'
    from public.rooms r
   cross join public.question_box_deep_deck() d
   where not exists (
     select 1 from public.room_questions q
      where q.room_id = r.id and q.source = 'house' and q.text = d.text
   );

-- =================================================================
-- 3. The draw, within one depth
-- =================================================================
-- The 097 order inside a depth: tonight's member questions (oldest first),
-- then host questions, then the house deck if it is on (random within a
-- source). Member questions are always light.
create or replace function public.question_box_draw(p_room_id uuid, p_event_id uuid, p_depth text)
returns public.room_questions
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_q public.room_questions;
  v_house boolean;
begin
  select r.question_house_deck into v_house from public.rooms r where r.id = p_room_id;
  select * into v_q from public.room_questions q
   where q.room_id = p_room_id and q.drawn_at is null
     and q.depth = p_depth
     and (
       (q.source = 'member' and q.event_id = p_event_id)
       or q.source = 'host'
       or (q.source = 'house' and v_house)
     )
   order by case q.source when 'member' then 0 when 'host' then 1 else 2 end,
            case when q.source = 'member' then extract(epoch from q.created_at) else random() end
   limit 1
   for update skip locked;
  if v_q.id is not null then
    update public.room_questions set drawn_at = now() where id = v_q.id;
  end if;
  return v_q;
end;
$$;

-- The 2-arg draw is the light draw, so no caller can pull a deep question
-- outside the pacing rule.
create or replace function public.question_box_draw(p_room_id uuid, p_event_id uuid)
returns public.room_questions
language sql
security definer
set search_path = ''
as $$
  select public.question_box_draw(p_room_id, p_event_id, 'light');
$$;

revoke all on function public.question_box_draw(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.question_box_draw(uuid, uuid, text) to service_role;
revoke all on function public.question_box_draw(uuid, uuid) from public, anon, authenticated;
grant execute on function public.question_box_draw(uuid, uuid) to service_role;

-- =================================================================
-- 4. Nights at the table in this room, before tonight
-- =================================================================
create or replace function public.question_box_nights_attended(p_event_id uuid)
returns table (member_id uuid, nights integer)
language sql
stable
security definer
set search_path = ''
as $$
  with tonight as (
    select e.room_id, e.played_at from public.events e where e.id = p_event_id
  ),
  earlier as (
    select e.id
      from public.events e, tonight
     where e.room_id = tonight.room_id
       and e.id <> p_event_id
       and e.played_at < tonight.played_at
  ),
  attended as (
    select t.member_id as who, t.session_id as night
      from public.transactions t
      join earlier on earlier.id = t.session_id
     where t.kind = 'casino_withdrawal'
    union
    select sd.user_id as who, sd.event_id as night
      from public.seat_deposits sd
      join earlier on earlier.id = sd.event_id
     where sd.returned_at is not null
       and sd.status <> 'forfeited'
  )
  select a.who, count(distinct a.night)::int
    from attended a
   group by a.who;
$$;

revoke all on function public.question_box_nights_attended(uuid) from public, anon, authenticated;
grant execute on function public.question_box_nights_attended(uuid) to service_role;

comment on function public.question_box_nights_attended(uuid) is
  '118: for each member, the nights they were at the table in this room before this event (a withdrawal or a checked-in, unforfeited seat deposit). Used only to hand the floor to newer people first; never shown, never ranked.';

-- =================================================================
-- 5. The advance
-- =================================================================
-- The 111 body. Changed: the reader pick (section "Reader") and the depth
-- of the draw (section "Depth"). Everything else is as 111 wrote it.
create or replace function public.question_box_advance(
  p_event_id uuid,
  p_now      timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e           record;
  v_rot         uuid[];
  v_reader      uuid;
  v_slot        integer;
  v_next_pos    integer;
  v_kind        text;
  v_q           public.room_questions;
  v_turn        uuid;
  v_has_turns   boolean;
  v_arrived     integer;
  v_n           integer;
  v_last_reader uuid;
  v_served      integer;
  v_depth       text;
begin
  select e.id, e.room_id, e.played_at, e.settled_at, e.question_reader_index,
         e.question_last_turn_at, e.question_deep_at,
         r.question_box_enabled, r.question_cadence_minutes,
         r.auto_close_hours, r.deleted_at
    into v_e
    from public.events e join public.rooms r on r.id = e.room_id
   where e.id = p_event_id
   for update of e;
  if v_e.id is null or not v_e.question_box_enabled or v_e.deleted_at is not null then
    return null;
  end if;
  if v_e.settled_at is not null or v_e.played_at > p_now then
    return null;
  end if;
  -- The night is over. The host forgot to settle; the box stops anyway
  -- (audit #15).
  if p_now > v_e.played_at + make_interval(hours => v_e.auto_close_hours) then
    return null;
  end if;

  select exists (select 1 from public.question_turns t where t.event_id = p_event_id) into v_has_turns;

  if not v_has_turns then
    -- The opener waits for the table: three people have to be there, or
    -- half an hour after the start, whichever comes first (audit #14).
    select count(*)::int into v_arrived
      from public.question_box_arrivals(p_event_id);
    if v_arrived < 3 and p_now < v_e.played_at + make_interval(mins => 30) then
      return null;
    end if;
    v_kind := 'opener';
    v_reader := public.question_box_host(v_e.room_id);
  else
    -- The box has gone quiet: nothing has been read or passed for an
    -- hour, so stop asking (audit #15).
    if not exists (
      select 1 from public.question_turns t
       where t.event_id = p_event_id
         and coalesce(t.read_at, t.passed_at) > p_now - make_interval(mins => 60)
    ) then
      return null;
    end if;
    if v_e.question_cadence_minutes = 0 or v_e.question_last_turn_at is null
       or p_now < v_e.question_last_turn_at + make_interval(mins => v_e.question_cadence_minutes) then
      return null;
    end if;
    v_rot := public.question_box_rotation(p_event_id);
    v_n := cardinality(v_rot);
    if v_n = 0 then
      return null;
    end if;
    v_kind := 'interval';

    -- Reader (118; twin QuestionBoxReaderPick). Never the person who read
    -- the last turn. Of the rest who can be reached (an active iOS token,
    -- audit #18): fewest turns tonight, then fewest nights at this room's
    -- table, then rotation order from the cursor. The cursor lands on the
    -- slot after the chosen reader, as in 111.
    select t.reader_id into v_last_reader
      from public.question_turns t
     where t.event_id = p_event_id
     order by t.created_at desc, t.id desc
     limit 1;

    select c.who, c.slot into v_reader, v_slot
      from (
        select x.who, x.slot::int as slot,
               (((x.slot::int - 1 - v_e.question_reader_index) % v_n) + v_n) % v_n as step
          from unnest(v_rot) with ordinality as x(who, slot)
      ) c
      left join (
        select t.reader_id, count(*)::int as reads
          from public.question_turns t
         where t.event_id = p_event_id
         group by t.reader_id
      ) rd on rd.reader_id = c.who
      left join public.question_box_nights_attended(p_event_id) na on na.member_id = c.who
     where c.who is distinct from v_last_reader
       and exists (
         select 1 from public.device_tokens dt
          where dt.user_id = c.who and dt.is_active and dt.platform = 'ios'
       )
     order by coalesce(rd.reads, 0), coalesce(na.nights, 0), c.step
     limit 1;
    if v_reader is null then
      return null;
    end if;
    v_next_pos := v_slot % v_n;
  end if;
  if v_reader is null then
    return null;
  end if;

  -- Depth (118; twin QuestionBoxPacing). The night opens light. Once per
  -- night, when three turns have been served or an hour has passed since
  -- the start, whichever comes first, the next question is a deeper one.
  -- Then light for the rest of the night.
  if v_kind = 'opener' or v_e.question_deep_at is not null then
    v_depth := 'light';
  else
    select count(*)::int into v_served
      from public.question_turns t
     where t.event_id = p_event_id and t.kind in ('opener', 'interval');
    if v_served >= 3 or p_now >= v_e.played_at + make_interval(mins => 60) then
      v_depth := 'deep';
    else
      v_depth := 'light';
    end if;
  end if;

  v_q := public.question_box_draw(v_e.room_id, p_event_id, v_depth);
  if v_q.id is null and v_depth = 'deep' then
    -- No deeper question left in this room: the night stays light.
    v_q := public.question_box_draw(v_e.room_id, p_event_id, 'light');
  end if;
  if v_q.id is null then
    return null;
  end if;
  -- One live card per event: an unanswered earlier turn is superseded.
  update public.question_turns set superseded_at = p_now
   where event_id = p_event_id and read_at is null and passed_at is null and superseded_at is null;
  insert into public.question_turns (event_id, room_id, reader_id, question_id, question_text, kind, created_at)
  values (p_event_id, v_e.room_id, v_reader, v_q.id, v_q.text, v_kind, p_now)
  returning id into v_turn;
  update public.events
     set question_last_turn_at = p_now,
         question_reader_index = case
           when v_kind = 'interval' then v_next_pos
           else v_e.question_reader_index
         end,
         question_deep_at = case
           when v_q.depth = 'deep' then p_now
           else v_e.question_deep_at
         end
   where id = p_event_id;
  return v_turn;
end;
$$;

revoke all on function public.question_box_advance(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.question_box_advance(uuid, timestamptz) to service_role;

comment on function public.question_box_advance(uuid, timestamptz) is
  '118: the single writer of question turns. 111 timing (opener waits for three arrivals or 30 minutes; night ends at played_at + auto_close_hours; quiet after 60 minutes with no read or pass; unreachable readers skipped). 118: one deeper question per night once 3 turns are served or 60 minutes have passed, light otherwise; the reader is never the last reader, and is the person with the fewest turns tonight, then the fewest nights in this room, then rotation order. Service role only.';

-- =================================================================
-- 6. Host add / edit: optional depth
-- =================================================================
drop function if exists public.upsert_room_question(uuid, uuid, text, text);

create or replace function public.upsert_room_question(
  p_room_id uuid, p_id uuid, p_text text, p_tag text, p_depth text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_text text := btrim(coalesce(p_text, ''));
begin
  if not public.is_room_host(p_room_id, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if char_length(v_text) not between 1 and 140 then
    raise exception 'question must be 1-140 characters' using errcode = '23514';
  end if;
  if p_depth is not null and p_depth not in ('light', 'deep') then
    raise exception 'invalid depth' using errcode = '22023';
  end if;
  if p_id is null then
    insert into public.room_questions (room_id, source, text, tag, depth)
    values (p_room_id, 'host', v_text, nullif(p_tag, ''), coalesce(p_depth, 'light'))
    returning id into v_id;
  else
    update public.room_questions
       set text = v_text,
           tag = nullif(p_tag, ''),
           depth = coalesce(p_depth, depth)
     where id = p_id and room_id = p_room_id
    returning id into v_id;
    if v_id is null then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;

revoke all on function public.upsert_room_question(uuid, uuid, text, text, text) from public, anon;
grant execute on function public.upsert_room_question(uuid, uuid, text, text, text) to authenticated;

-- =================================================================
-- 7. Host list: with depth
-- =================================================================
drop function if exists public.get_room_questions(uuid);

create or replace function public.get_room_questions(p_room_id uuid)
returns table (
  id uuid, room_id uuid, event_id uuid, source text, text text, tag text,
  drawn_at timestamptz, created_at timestamptz,
  author_id uuid, author_display_name text, depth text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  if not public.is_room_host(p_room_id, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select q.id, q.room_id, q.event_id, q.source, q.text, q.tag, q.drawn_at, q.created_at,
           q.author_id, u.display_name, q.depth
      from public.room_questions q
      left join public.users u on u.id = q.author_id
     where q.room_id = p_room_id
     order by (q.source = 'member') desc, (q.source = 'host') desc, q.created_at;
end;
$$;

revoke all on function public.get_room_questions(uuid) from public, anon;
grant execute on function public.get_room_questions(uuid) to authenticated;

notify pgrst, 'reload schema';

commit;
