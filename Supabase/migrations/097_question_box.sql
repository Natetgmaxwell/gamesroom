-- 097: V0.106 Question Box + Currently Into + reader-only push.
--
-- Spec: docs/V0.106_QUESTION_BOX_SPEC.md (rev 433fc7c).
--
-- What this migration adds
--   1. rooms: question_box_enabled (on), question_show_author (off),
--      question_house_deck (on), question_cadence_minutes (20; 0 = off),
--      question_speaking_light (on).
--   2. events: question_reader_index (rotation cursor, survives restarts),
--      question_last_turn_at.
--   3. room_memberships.preferences_conversation_prompt_updated_at
--      ("Currently Into" freshness). Set by trigger on every write.
--   4. room_questions — member / host / house questions, room-local.
--      Every room gets its own copy of the 40-question house deck.
--   5. question_turns — one row per "you're asking" turn.
--   6. device_tokens — APNs registration (mirrors Felt Faction 0002).
--   7. RPCs (all SECURITY DEFINER, explicit membership/host checks):
--        get_question_box_settings / set_question_box_settings
--        get_room_questions (host; includes author) / upsert_room_question /
--        delete_room_question / restore_room_question
--        submit_member_question / get_my_member_question
--        get_my_currently_into / set_currently_into / get_event_currently_into
--        question_box_tick (lazy driver) / question_box_cron_tick (pg_cron)
--        get_question_box_state (reader + host only) / respond_question_turn
--        register_device_token
--   8. AFTER INSERT trigger on question_turns → pg_net → question-turn-push
--      edge function, gated on the vault secret 'question_turn_push_secret'.
--      No secret → no-op (the sender ships disabled).
--
-- Delivery rules (spec §1.4 rev 433fc7c)
--   * Opener: the host asks the first question once played_at <= now.
--   * Then one turn every N minutes (rooms.question_cadence_minutes,
--     10/20/30; 0 = off) measured from the previous turn. No event-driven
--     triggers (score saves, withdrawals, cash-outs do NOT fire turns).
--   * Turns stop once events.settled_at is set.
--   * Rotation: members with a 'casino_withdrawal' transaction on this
--     event, ordered by their first withdrawal. Packs with no bank fall back
--     to claimed RSVPs in claim order (responded_at).
--   * Cadence "off" (0) still lets the host ask the opener; it only disables
--     the timed turns.
--
-- Privacy
--   * room_questions has NO member select policy. Members only ever see
--     question text through get_question_box_state, and only when they are
--     the reader. author_id is exposed to the host via get_room_questions;
--     the drawn card carries "asked by" only when question_show_author.
--   * question_turns select policy: the reader or a host of the room. That
--     same policy scopes realtime delivery.
--
-- Account deletion (096 interplay) — DECISION: delete.
--   room_questions.author_id → public.users ON DELETE CASCADE: a deleted
--   member's authored questions are removed, never left as anonymous
--   orphans (spec acceptance 8). question_turns.reader_id and
--   device_tokens.user_id cascade too. question_turns.question_id is SET
--   NULL (the turn keeps its text snapshot for the host's history until the
--   event itself is deleted). delete_my_account() needs no change: it
--   deletes public.users and these FKs do the rest.
--
-- Idempotent: every create uses IF NOT EXISTS / OR REPLACE / DROP IF EXISTS.
-- NOT applied to live. Apply (after Nathan's approval) via:
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/097_question_box.sql
-- Then, to enable push: create vault secret 'question_turn_push_secret',
-- set the same value as QUESTION_TURN_PUSH_SECRET on the edge function, set
-- APNS_* secrets, set QUESTION_TURN_PUSH_ENABLED=true, deploy with
-- --no-verify-jwt.

-- =================================================================
-- 1. Room settings
-- =================================================================
alter table public.rooms
  add column if not exists question_box_enabled boolean not null default true,
  add column if not exists question_show_author boolean not null default false,
  add column if not exists question_house_deck boolean not null default true,
  add column if not exists question_cadence_minutes integer not null default 20,
  add column if not exists question_speaking_light boolean not null default true;

do $$ begin
  alter table public.rooms
    add constraint rooms_question_cadence_minutes_check
    check (question_cadence_minutes in (0, 10, 20, 30));
exception when duplicate_object then null; end $$;

-- =================================================================
-- 2. Per-event rotation state
-- =================================================================
alter table public.events
  add column if not exists question_reader_index integer not null default 0,
  add column if not exists question_last_turn_at timestamptz;

-- =================================================================
-- 3. Currently Into freshness
-- =================================================================
alter table public.room_memberships
  add column if not exists preferences_conversation_prompt_updated_at timestamptz;

create or replace function public.touch_conversation_prompt_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.preferences_conversation_prompt_updated_at := now();
  return new;
end;
$$;

drop trigger if exists room_memberships_conversation_prompt_touch on public.room_memberships;
create trigger room_memberships_conversation_prompt_touch
  before update of preferences_conversation_prompt on public.room_memberships
  for each row execute function public.touch_conversation_prompt_updated_at();

-- =================================================================
-- 4. room_questions
-- =================================================================
create table if not exists public.room_questions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  event_id uuid references public.events(id) on delete cascade,
  author_id uuid references public.users(id) on delete cascade,
  source text not null check (source in ('member', 'host', 'house')),
  text text not null check (char_length(btrim(text)) between 1 and 140),
  tag text check (tag is null or tag in ('deep', 'unhinged')),
  drawn_at timestamptz,
  created_at timestamptz not null default now(),
  check (source <> 'member' or (author_id is not null and event_id is not null))
);

create index if not exists room_questions_room_idx on public.room_questions(room_id);
create index if not exists room_questions_pool_idx on public.room_questions(room_id, drawn_at);
create unique index if not exists room_questions_one_per_member_event
  on public.room_questions(event_id, author_id) where source = 'member';

alter table public.room_questions enable row level security;

drop policy if exists "hosts read room questions" on public.room_questions;
create policy "hosts read room questions" on public.room_questions
  for select using (public.is_room_host(room_id, public.current_user_id()));

drop policy if exists "members insert own member questions" on public.room_questions;
create policy "members insert own member questions" on public.room_questions
  for insert with check (
    source = 'member'
    and author_id = public.current_user_id()
    and exists (
      select 1 from public.room_memberships m
      where m.room_id = room_questions.room_id
        and m.user_id = public.current_user_id()
        and m.membership_status = 'active'
    )
  );

drop policy if exists "hosts update room questions" on public.room_questions;
create policy "hosts update room questions" on public.room_questions
  for update using (public.is_room_host(room_id, public.current_user_id()));

drop policy if exists "hosts delete room questions" on public.room_questions;
create policy "hosts delete room questions" on public.room_questions
  for delete using (public.is_room_host(room_id, public.current_user_id()));

-- House deck: docs/V0.106_house_deck.json (40, 20 deep / 20 unhinged).
-- Mirrored in GamesRoom/Models/QuestionBoxHouseDeck.swift; the Foundation
-- test harness asserts the Swift copy matches the JSON.
create or replace function public.question_box_house_deck()
returns table (text text, tag text)
language sql
immutable
set search_path = ''
as $$
  select d.text, d.tag from (values
    (1, 'Which decade would you live in if you had to, and what would you miss most about now?', 'deep'),
    (2, 'If you were a Transformer, what vehicle would you turn into?', 'unhinged'),
    (3, 'Is it kinder to tell a mate the hard truth or let them find out?', 'deep'),
    (4, 'Which person at this table would last longest in a zombie apocalypse, and who goes first?', 'unhinged'),
    (5, 'What''s one job everyone thinks is respectable that you think is mostly a scam?', 'deep'),
    (6, 'What''s the most ridiculous thing you''d do for a million dollars, as long as nobody filmed it?', 'unhinged'),
    (7, 'Would you rather know the date you die or the way you die?', 'deep'),
    (8, 'Rank everyone at the table by who''d be the worst to share a caravan with for a month?', 'unhinged'),
    (9, 'What''s one belief you held at 18 that you''re embarrassed by now?', 'deep'),
    (10, 'Which character from a kids'' show is secretly the most unhinged?', 'unhinged'),
    (11, 'Does keeping score in a relationship ever work?', 'deep'),
    (12, 'If your life had a theme song that played whenever you walked in, what is it?', 'unhinged'),
    (13, 'Which of your opinions would lose you a friend if you said it at a dinner party?', 'deep'),
    (14, 'What''s a completely normal thing that you find deeply suspicious?', 'unhinged'),
    (15, 'Is being funny or being good-looking worth more in the long run?', 'deep'),
    (16, 'What''s the worst possible name for a pub, and who owns it?', 'unhinged'),
    (17, 'If you could abolish one law tomorrow, which one goes?', 'deep'),
    (18, 'What''s the most unhinged thing you''ve ever done to avoid a phone call?', 'unhinged'),
    (19, 'Should you stay friends with someone whose politics you can''t stand?', 'deep'),
    (20, 'Which sitcom would your friend group fit into, and who plays who?', 'unhinged'),
    (21, 'What''s something everyone pretends to enjoy but secretly doesn''t?', 'deep'),
    (22, 'What''s the most useless superpower you''d secretly love to have?', 'unhinged'),
    (23, 'Who''s a person you admire that most people have never heard of?', 'deep'),
    (24, 'If you could ban one word from the English language forever, what goes?', 'unhinged'),
    (25, 'What''s the best piece of advice you ignored and later wish you hadn''t?', 'deep'),
    (26, 'What''s the weirdest thing you believed as a kid for far too long?', 'unhinged'),
    (27, 'What''s one thing every 16-year-old should be taught that school skips?', 'deep'),
    (28, 'Which table member would be the best at running a dodgy cult?', 'unhinged'),
    (29, 'Would you take a pill that made you happy forever if it meant you''d never achieve anything again?', 'deep'),
    (30, 'What would your last meal be if it also had to be your most embarrassing order?', 'unhinged'),
    (31, 'Is it better to be respected or liked?', 'deep'),
    (32, 'If animals could talk, which one would turn out to be the biggest jerk?', 'unhinged'),
    (33, 'What''s the most overrated milestone in life?', 'deep'),
    (34, 'What''s a perfectly good food you refuse to eat and can''t defend?', 'unhinged'),
    (35, 'Which job would you do for free, and which would you never take for any pay?', 'deep'),
    (36, 'Which celebrity would you pick as your annoying flatmate for a year?', 'unhinged'),
    (37, 'Which person, alive or dead, would you want to argue with for an hour, and about what?', 'deep'),
    (38, 'What''s the dumbest thing you''d name a dog?', 'unhinged'),
    (39, 'Is ambition a virtue, or just insecurity that dresses better?', 'deep'),
    (40, 'What''s the funniest thing you''ve ever gotten in trouble for?', 'unhinged')
  ) as d(ord, text, tag)
  order by d.ord;
$$;

create or replace function public.seed_room_house_deck(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer;
begin
  if exists (select 1 from public.room_questions where room_id = p_room_id and source = 'house') then
    return 0;
  end if;
  insert into public.room_questions (room_id, source, text, tag)
    select p_room_id, 'house', d.text, d.tag from public.question_box_house_deck() d;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.seed_room_house_deck(uuid) from public;

create or replace function public.handle_new_room_question_deck()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.seed_room_house_deck(new.id);
  return new;
end;
$$;

drop trigger if exists rooms_seed_question_deck on public.rooms;
create trigger rooms_seed_question_deck
  after insert on public.rooms
  for each row execute function public.handle_new_room_question_deck();

-- Backfill: every existing room gets its own copy.
do $$ begin
  perform public.seed_room_house_deck(r.id) from public.rooms r;
end $$;

-- =================================================================
-- 5. question_turns
-- =================================================================
create table if not exists public.question_turns (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  reader_id uuid not null references public.users(id) on delete cascade,
  question_id uuid references public.room_questions(id) on delete set null,
  question_text text not null,
  kind text not null check (kind in ('opener', 'interval', 'pass')),
  created_at timestamptz not null default now(),
  read_at timestamptz,
  passed_at timestamptz,
  superseded_at timestamptz,
  push_status text not null default 'pending'
);

create index if not exists question_turns_event_idx on public.question_turns(event_id, created_at desc);
create index if not exists question_turns_reader_idx on public.question_turns(reader_id);

alter table public.question_turns enable row level security;

drop policy if exists "reader or host reads question turns" on public.question_turns;
create policy "reader or host reads question turns" on public.question_turns
  for select using (
    reader_id = public.current_user_id()
    or public.is_room_host(room_id, public.current_user_id())
  );

do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin
      alter publication supabase_realtime add table public.question_turns;
    exception when duplicate_object then null;
    end;
  end if;
end $$;

-- =================================================================
-- 6. device_tokens (mirror of Felt Faction 0002)
-- =================================================================
create table if not exists public.device_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.users(id) on delete cascade,
  device_token text not null,
  platform text not null default 'ios',
  environment text not null default 'production' check (environment in ('production', 'sandbox')),
  app_version text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, device_token)
);

create index if not exists device_tokens_active_idx on public.device_tokens(user_id) where is_active;

alter table public.device_tokens enable row level security;

drop policy if exists "users manage own device tokens" on public.device_tokens;
create policy "users manage own device tokens" on public.device_tokens
  for all using (user_id = public.current_user_id())
  with check (user_id = public.current_user_id());

create or replace function public.register_device_token(
  p_device_token text,
  p_environment text default 'production',
  p_app_version text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if p_device_token is null or p_device_token !~ '^[0-9a-f]{64,200}$' then
    raise exception 'invalid device token' using errcode = '22023';
  end if;
  -- A physical device belongs to one signed-in user at a time.
  update public.device_tokens
     set is_active = false, updated_at = now()
   where device_token = p_device_token and user_id <> v_caller;
  insert into public.device_tokens (user_id, device_token, environment, app_version)
  values (v_caller, p_device_token,
          case when p_environment = 'sandbox' then 'sandbox' else 'production' end,
          p_app_version)
  on conflict (user_id, device_token) do update
    set is_active = true,
        environment = excluded.environment,
        app_version = excluded.app_version,
        updated_at = now();
end;
$$;

-- =================================================================
-- 7a. Settings
-- =================================================================
create or replace function public.get_question_box_settings(p_room_id uuid)
returns table (
  question_box_enabled boolean,
  question_show_author boolean,
  question_house_deck boolean,
  question_cadence_minutes integer,
  question_speaking_light boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = p_room_id and m.user_id = public.current_user_id()
      and m.membership_status = 'active'
  ) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select r.question_box_enabled, r.question_show_author, r.question_house_deck,
           r.question_cadence_minutes, r.question_speaking_light
      from public.rooms r where r.id = p_room_id;
end;
$$;

create or replace function public.set_question_box_settings(
  p_room_id uuid,
  p_enabled boolean,
  p_show_author boolean,
  p_house_deck boolean,
  p_cadence_minutes integer,
  p_speaking_light boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_room_host(p_room_id, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if p_cadence_minutes not in (0, 10, 20, 30) then
    raise exception 'invalid cadence' using errcode = '22023';
  end if;
  update public.rooms
     set question_box_enabled = p_enabled,
         question_show_author = p_show_author,
         question_house_deck = p_house_deck,
         question_cadence_minutes = p_cadence_minutes,
         question_speaking_light = p_speaking_light,
         updated_at = now()
   where id = p_room_id;
end;
$$;

-- =================================================================
-- 7b. Host question list + edits (room-local)
-- =================================================================
create or replace function public.get_room_questions(p_room_id uuid)
returns table (
  id uuid, room_id uuid, event_id uuid, source text, text text, tag text,
  drawn_at timestamptz, created_at timestamptz,
  author_id uuid, author_display_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.is_room_host(p_room_id, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select q.id, q.room_id, q.event_id, q.source, q.text, q.tag, q.drawn_at, q.created_at,
           q.author_id, u.display_name
      from public.room_questions q
      left join public.users u on u.id = q.author_id
     where q.room_id = p_room_id
     order by (q.source = 'member') desc, (q.source = 'host') desc, q.created_at;
end;
$$;

create or replace function public.upsert_room_question(
  p_room_id uuid, p_id uuid, p_text text, p_tag text
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
  if p_id is null then
    insert into public.room_questions (room_id, source, text, tag)
    values (p_room_id, 'host', v_text, nullif(p_tag, ''))
    returning id into v_id;
  else
    update public.room_questions
       set text = v_text, tag = nullif(p_tag, '')
     where id = p_id and room_id = p_room_id
    returning id into v_id;
    if v_id is null then
      raise exception 'not_found' using errcode = 'P0002';
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.delete_room_question(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid;
begin
  select room_id into v_room from public.room_questions where id = p_id;
  if v_room is null then return; end if;
  if not public.is_room_host(v_room, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  delete from public.room_questions where id = p_id;
end;
$$;

create or replace function public.restore_room_question(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid;
begin
  select room_id into v_room from public.room_questions where id = p_id;
  if v_room is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not public.is_room_host(v_room, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  update public.room_questions set drawn_at = null where id = p_id;
end;
$$;

-- =================================================================
-- 7c. Member contribution (RSVP card)
-- =================================================================
create or replace function public.submit_member_question(p_event_id uuid, p_text text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room uuid;
  v_text text := btrim(coalesce(p_text, ''));
begin
  select e.room_id into v_room from public.events e where e.id = p_event_id;
  if v_room is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room and m.user_id = v_caller and m.membership_status = 'active'
  ) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  -- Empty submit is the normal path: it clears an undrawn question.
  if v_text = '' then
    delete from public.room_questions
     where event_id = p_event_id and author_id = v_caller and source = 'member'
       and drawn_at is null;
    return;
  end if;
  if char_length(v_text) > 140 then
    v_text := left(v_text, 140);
  end if;
  insert into public.room_questions (room_id, event_id, author_id, source, text)
  values (v_room, p_event_id, v_caller, 'member', v_text)
  on conflict (event_id, author_id) where source = 'member'
  do update set text = excluded.text
   where public.room_questions.drawn_at is null;
end;
$$;

create or replace function public.get_my_member_question(p_event_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select q.text from public.room_questions q
   where q.event_id = p_event_id
     and q.author_id = public.current_user_id()
     and q.source = 'member';
$$;

-- =================================================================
-- 7d. Currently Into
-- =================================================================
create or replace function public.get_my_currently_into(p_room_id uuid)
returns table (text text, updated_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select m.preferences_conversation_prompt, m.preferences_conversation_prompt_updated_at
    from public.room_memberships m
   where m.room_id = p_room_id and m.user_id = public.current_user_id();
$$;

create or replace function public.set_currently_into(p_room_id uuid, p_text text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_text text := nullif(btrim(coalesce(p_text, '')), '');
begin
  if v_text is not null and char_length(v_text) > 60 then
    v_text := left(v_text, 60);
  end if;
  update public.room_memberships
     set preferences_conversation_prompt = v_text
   where room_id = p_room_id and user_id = public.current_user_id()
     and membership_status = 'active';
  if not found then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
end;
$$;

-- Briefing who's-coming list. Fresh (<= 30 days), non-empty values for
-- claimed members only; caller must be an active member of the room.
create or replace function public.get_event_currently_into(p_event_id uuid)
returns table (member_id uuid, text text, updated_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_room uuid;
begin
  select e.room_id into v_room from public.events e where e.id = p_event_id;
  if v_room is null or not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room and m.user_id = public.current_user_id()
      and m.membership_status = 'active'
  ) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return query
    select m.user_id, m.preferences_conversation_prompt, m.preferences_conversation_prompt_updated_at
      from public.room_memberships m
      join public.event_rsvps r on r.event_id = p_event_id and r.member_id = m.user_id
     where m.room_id = v_room
       and m.membership_status = 'active'
       and r.state = 'claimed'
       and nullif(btrim(coalesce(m.preferences_conversation_prompt, '')), '') is not null
       and m.preferences_conversation_prompt_updated_at > now() - interval '30 days';
end;
$$;

-- =================================================================
-- 7e. Rotation + cadence (mirrors QuestionBoxRotation / QuestionBoxCadence)
-- =================================================================
create or replace function public.question_box_host(p_room_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select r.created_by from public.rooms r
      where r.id = p_room_id and public.is_room_host(r.id, r.created_by)),
    (select m.user_id from public.room_memberships m
      where m.room_id = p_room_id and m.role = 'host' and m.membership_status = 'active'
      order by m.joined_at limit 1)
  );
$$;

create or replace function public.question_box_rotation(p_event_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_room uuid;
  v_ids uuid[];
begin
  select e.room_id into v_room from public.events e where e.id = p_event_id;
  -- Withdrawals are the arrival signal, ordered by first withdrawal.
  select array_agg(w.member_id order by w.first_at, w.member_id) into v_ids
    from (
      select t.member_id, min(t.created_at) as first_at
        from public.transactions t
        join public.room_memberships m
          on m.room_id = v_room and m.user_id = t.member_id and m.membership_status = 'active'
       where t.session_id = p_event_id and t.kind = 'casino_withdrawal'
       group by t.member_id
    ) w;
  if v_ids is not null and cardinality(v_ids) > 0 then
    return v_ids;
  end if;
  -- No bank tonight: claimed members in claim order.
  select array_agg(r.member_id order by coalesce(r.responded_at, r.created_at), r.member_id) into v_ids
    from public.event_rsvps r
    join public.room_memberships m
      on m.room_id = v_room and m.user_id = r.member_id and m.membership_status = 'active'
   where r.event_id = p_event_id and r.state = 'claimed';
  return coalesce(v_ids, '{}'::uuid[]);
end;
$$;

-- Draws the next undrawn question: tonight's member questions first
-- (oldest first), then host questions, then the house deck (if on).
create or replace function public.question_box_draw(p_room_id uuid, p_event_id uuid)
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

-- The single writer of turns. Idempotent and safe to call from any
-- member's device or the cron: it only writes when a turn is due.
-- Returns the new turn id, or null when nothing was due.
create or replace function public.question_box_advance(p_event_id uuid, p_now timestamptz default now())
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_e record;
  v_rot uuid[];
  v_reader uuid;
  v_kind text;
  v_q public.room_questions;
  v_turn uuid;
  v_has_turns boolean;
begin
  select e.id, e.room_id, e.played_at, e.settled_at, e.question_reader_index,
         e.question_last_turn_at, r.question_box_enabled, r.question_cadence_minutes,
         r.deleted_at
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
  select exists (select 1 from public.question_turns t where t.event_id = p_event_id) into v_has_turns;
  if not v_has_turns then
    v_kind := 'opener';
    v_reader := public.question_box_host(v_e.room_id);
  else
    if v_e.question_cadence_minutes = 0 or v_e.question_last_turn_at is null
       or p_now < v_e.question_last_turn_at + make_interval(mins => v_e.question_cadence_minutes) then
      return null;
    end if;
    v_rot := public.question_box_rotation(p_event_id);
    if cardinality(v_rot) = 0 then
      return null;
    end if;
    v_kind := 'interval';
    v_reader := v_rot[(v_e.question_reader_index % cardinality(v_rot)) + 1];
  end if;
  if v_reader is null then
    return null;
  end if;
  v_q := public.question_box_draw(v_e.room_id, p_event_id);
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
         question_reader_index = question_reader_index + case when v_kind = 'interval' then 1 else 0 end
   where id = p_event_id;
  return v_turn;
end;
$$;

revoke all on function public.question_box_advance(uuid, timestamptz) from public;

-- Client-callable lazy driver (the repo has no guaranteed pg_cron; see 080).
create or replace function public.question_box_tick(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room uuid;
begin
  select e.room_id into v_room from public.events e where e.id = p_event_id;
  if v_room is null or not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room and m.user_id = public.current_user_id()
      and m.membership_status = 'active'
  ) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  return public.question_box_advance(p_event_id, now());
end;
$$;

create or replace function public.question_box_cron_tick()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event uuid;
  v_n integer := 0;
begin
  for v_event in
    select e.id from public.events e join public.rooms r on r.id = e.room_id
     where e.played_at <= now() and e.played_at > now() - interval '24 hours'
       and e.settled_at is null and r.question_box_enabled and r.deleted_at is null
  loop
    if public.question_box_advance(v_event, now()) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.question_box_cron_tick() from public;

do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'question-box-tick';
    perform cron.schedule('question-box-tick', '* * * * *', 'select public.question_box_cron_tick();');
  else
    raise notice '097: pg_cron not installed; turns are driven lazily by question_box_tick from the app.';
  end if;
end $$;

-- =================================================================
-- 7f. Reader card + host fallback
-- =================================================================
-- Returns the open (not done, not passed) turn for the event. Only the
-- reader and hosts get a row; every other member gets nothing (spec
-- acceptance 4). asked_by is non-null only when question_show_author is on
-- (acceptance 5) — the host reads authorship via get_room_questions.
create or replace function public.get_question_box_state(p_event_id uuid)
returns table (
  turn_id uuid, event_id uuid, reader_id uuid, reader_display_name text,
  question_text text, asked_by text, kind text, created_at timestamptz,
  is_reader boolean, speaking_light boolean, answer_first_display_name text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_t public.question_turns;
  v_show_author boolean;
  v_light boolean;
  v_rot uuid[];
  v_pos integer;
  v_left uuid;
begin
  select * into v_t from public.question_turns t
   where t.event_id = p_event_id and t.read_at is null and t.passed_at is null
     and t.superseded_at is null
   order by t.created_at desc limit 1;
  if v_t.id is null then return; end if;
  if v_t.reader_id <> v_caller and not public.is_room_host(v_t.room_id, v_caller) then
    return;
  end if;
  select r.question_show_author, r.question_speaking_light into v_show_author, v_light
    from public.rooms r where r.id = v_t.room_id;
  -- "Pick who answers first": the next person in rotation order stands in
  -- for "the person on your left".
  v_rot := public.question_box_rotation(p_event_id);
  v_pos := array_position(v_rot, v_t.reader_id);
  if cardinality(v_rot) > 1 then
    v_left := v_rot[(coalesce(v_pos, 0) % cardinality(v_rot)) + 1];
  end if;
  return query
    select v_t.id, v_t.event_id, v_t.reader_id, ru.display_name, v_t.question_text,
           case when v_show_author then au.display_name else null end,
           v_t.kind, v_t.created_at, v_t.reader_id = v_caller, v_light,
           lu.display_name
      from public.users ru
      left join public.room_questions q on q.id = v_t.question_id
      left join public.users au on au.id = q.author_id
      left join public.users lu on lu.id = v_left and v_left <> v_t.reader_id
     where ru.id = v_t.reader_id;
end;
$$;

-- p_action: 'done' | 'pass'. Pass hands the same question to the next
-- person in rotation without consuming the timer.
create or replace function public.respond_question_turn(p_turn_id uuid, p_action text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_t public.question_turns;
  v_rot uuid[];
  v_pos integer;
  v_next uuid;
  v_new uuid;
begin
  select * into v_t from public.question_turns where id = p_turn_id for update;
  if v_t.id is null then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if v_t.reader_id <> v_caller and not public.is_room_host(v_t.room_id, v_caller) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;
  if v_t.read_at is not null or v_t.passed_at is not null or v_t.superseded_at is not null then
    return null;
  end if;
  if p_action = 'done' then
    update public.question_turns set read_at = now() where id = p_turn_id;
    return null;
  elsif p_action = 'pass' then
    update public.question_turns set passed_at = now() where id = p_turn_id;
    v_rot := public.question_box_rotation(v_t.event_id);
    if cardinality(v_rot) = 0 then return null; end if;
    v_pos := array_position(v_rot, v_t.reader_id);
    v_next := v_rot[(coalesce(v_pos, 0) % cardinality(v_rot)) + 1];
    if v_next is null or v_next = v_t.reader_id then return null; end if;
    insert into public.question_turns (event_id, room_id, reader_id, question_id, question_text, kind)
    values (v_t.event_id, v_t.room_id, v_next, v_t.question_id, v_t.question_text, 'pass')
    returning id into v_new;
    return v_new;
  else
    raise exception 'invalid action' using errcode = '22023';
  end if;
end;
$$;

-- =================================================================
-- 8. Reader-only push via pg_net → question-turn-push
-- =================================================================
create or replace function public.question_turn_push_secret()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
    into v_secret using 'question_turn_push_secret';
  return v_secret;
end;
$$;

revoke all on function public.question_turn_push_secret() from public;

create or replace function public.invoke_question_turn_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url text := 'https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/question-turn-push';
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    update public.question_turns set push_status = 'skipped_no_pg_net' where id = new.id;
    return new;
  end if;
  v_secret := public.question_turn_push_secret();
  if v_secret is null or v_secret = '' then
    update public.question_turns set push_status = 'skipped_disabled' where id = new.id;
    return new;
  end if;
  -- Payload carries the turn id only; the function re-reads the turn and
  -- resolves exactly one recipient (reader_id).
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
    using v_url,
          jsonb_build_object('Content-Type', 'application/json', 'X-Question-Push-Secret', v_secret),
          jsonb_build_object('turn_id', new.id);
  return new;
end;
$$;

drop trigger if exists question_turns_push on public.question_turns;
create trigger question_turns_push
  after insert on public.question_turns
  for each row execute function public.invoke_question_turn_push();

-- =================================================================
-- Grants
-- =================================================================
do $$
declare
  f text;
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    foreach f in array array[
      'public.register_device_token(text, text, text)',
      'public.get_question_box_settings(uuid)',
      'public.set_question_box_settings(uuid, boolean, boolean, boolean, integer, boolean)',
      'public.get_room_questions(uuid)',
      'public.upsert_room_question(uuid, uuid, text, text)',
      'public.delete_room_question(uuid)',
      'public.restore_room_question(uuid)',
      'public.submit_member_question(uuid, text)',
      'public.get_my_member_question(uuid)',
      'public.get_my_currently_into(uuid)',
      'public.set_currently_into(uuid, text)',
      'public.get_event_currently_into(uuid)',
      'public.question_box_tick(uuid)',
      'public.get_question_box_state(uuid)',
      'public.respond_question_turn(uuid, text)'
    ] loop
      execute format('grant execute on function %s to authenticated', f);
    end loop;
  end if;
end $$;
