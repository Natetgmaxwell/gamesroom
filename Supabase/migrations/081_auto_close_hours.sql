-- 081: Adjustable auto-close window (V0.83).
--
-- V0.82 (migration 080) shipped a hard-coded 24h-after-played_at
-- lazy close. The host wants the window adjustable per room from
-- Room Settings, defaulting to 8 hours after the event started
-- (played_at).
--
-- Changes:
--   1. rooms.auto_close_hours integer NOT NULL DEFAULT 8, bounded
--      1..72 (a night is at least an hour; 72h is a long weekend).
--   2. auto_close_stale_events(p_room_id) redefined to close events
--      whose played_at passed the ROOM's window, not a constant.
--      Same member gate + idempotence as 080.
--   3. update_room_settings gains p_auto_close_hours (13th param)
--      and returns auto_close_hours so the client's cached Room
--      mirrors the persisted value.
--   4. get_my_rooms returns auto_close_hours so the rooms list
--      carries the setting on first load.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/081_auto_close_hours.sql
--
-- Post-apply verification:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='rooms'
--     and column_name='auto_close_hours';
--   select pg_get_function_arguments('public.auto_close_stale_events(uuid)'::regprocedure);

-- 1. Column + bound.
alter table public.rooms
  add column if not exists auto_close_hours integer not null default 8;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'rooms_auto_close_hours_range'
      and conrelid = 'public.rooms'::regclass
  ) then
    alter table public.rooms
      add constraint rooms_auto_close_hours_range
      check (auto_close_hours between 1 and 72);
  end if;
end $$;

-- 2. Auto-close uses the room's window.
create or replace function public.auto_close_stale_events(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_closed integer := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Member gate: the caller must belong to the room.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id and user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Close events whose night passed the room's window and were
  -- never settled. The window rides the room row so the host's
  -- Room Settings choice is the single source of truth.
  update public.events e
  set settled_at = now()
  from public.rooms r
  where e.room_id = p_room_id
    and e.settled_at is null
    and e.played_at < now() - make_interval(hours => r.auto_close_hours)
    and r.id = p_room_id;

  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

grant execute on function public.auto_close_stale_events(uuid) to authenticated;

-- 3. update_room_settings — 13th param + return column. Drop the
-- 12-arg overload first (repo convention, migration 061) so the
-- client's 13-arg call resolves to exactly one function.
drop function if exists public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean
);
create function public.update_room_settings(
    p_room_id uuid,
    p_name text,
    p_mascot_name text,
    p_mascot_personality text,
    p_mascot_political_ideology text,
    p_max_seats integer,
    p_member_invite_quota integer,
    p_join_starting_bonus integer,
    p_social_narration_enabled boolean,
    p_briefing_48h_enabled boolean,
    p_calendar_auto_add_host boolean,
    p_social_preferences_enabled boolean,
    p_auto_close_hours integer
)
returns table (
    id uuid,
    name text,
    mascot_name text,
    mascot_personality public.mascot_personality,
    mascot_political_ideology text,
    created_by uuid,
    created_at timestamptz,
    updated_at timestamptz,
    is_live boolean,
    next_event_description text,
    join_starting_bonus integer,
    user_role text,
    briefing_48h_enabled boolean,
    calendar_auto_add_host boolean,
    social_preferences_enabled boolean,
    social_narration_enabled boolean,
    max_seats integer,
    member_invite_quota integer,
    host_journal text,
    auto_close_hours integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_updated boolean := false;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.rooms as r set
      name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality::mascot_personality,
      mascot_political_ideology = p_mascot_political_ideology,
      max_seats = p_max_seats,
      member_invite_quota = p_member_invite_quota,
      join_starting_bonus = p_join_starting_bonus,
      social_narration_enabled = p_social_narration_enabled,
      briefing_48h_enabled = p_briefing_48h_enabled,
      calendar_auto_add_host = p_calendar_auto_add_host,
      social_preferences_enabled = p_social_preferences_enabled,
      auto_close_hours = p_auto_close_hours,
      updated_at = now()
  where r.id = p_room_id and r.created_by = v_caller
  returning true into v_updated;

  if v_updated is not true then
    raise exception 'Room not found or caller is not the host' using errcode = '42501';
  end if;

  return query
  select
      r.id, r.name, r.mascot_name, r.mascot_personality,
      r.mascot_political_ideology,
      r.created_by, r.created_at, r.updated_at, r.is_live,
      r.next_event_description,
      r.join_starting_bonus,
      m.role::text as user_role,
      r.briefing_48h_enabled,
      r.calendar_auto_add_host,
      r.social_preferences_enabled,
      r.social_narration_enabled,
      r.max_seats,
      r.member_invite_quota,
      r.host_journal,
      r.auto_close_hours
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id and m.user_id = v_caller;
end;
$$;

grant execute on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer
) to authenticated;

-- 4. get_my_rooms — carry the setting on the rooms list.
drop function if exists public.get_my_rooms();
create function public.get_my_rooms()
returns table (
  id uuid,
  name text,
  mascot_name text,
  mascot_personality public.mascot_personality,
  mascot_political_ideology text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  is_live boolean,
  next_event_description text,
  join_starting_bonus integer,
  mascot_api_key text,
  seat_deposit_amount integer,
  user_role text,
  member_drowning_opt_in boolean,
  notifications_enabled boolean,
  overlap_count bigint,
  overlap_names text[],
  auto_close_hours integer
)
language sql
security definer
stable
set search_path = public
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    r.join_starting_bonus,
    r.mascot_api_key,
    r.seat_deposit_amount,
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in,
    coalesce(m.notifications_enabled, false) as notifications_enabled,
    ov.overlap_count,
    ov.overlap_names,
    r.auto_close_hours
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  left join lateral (
    select
      count(distinct other.user_id) as overlap_count,
      array_agg(distinct u.display_name) filter (where u.display_name is not null) as overlap_names
    from public.room_memberships other
    join public.room_memberships shared
      on shared.user_id = other.user_id
     and shared.room_id <> r.id
    join public.users u on u.id = other.user_id
    where other.room_id = r.id
      and other.user_id <> m.user_id
      and exists (
        select 1 from public.room_memberships mine
        where mine.user_id = m.user_id
          and mine.room_id = shared.room_id
      )
  ) ov on true
  where m.user_id = public.current_user_id()
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

notify pgrst, 'reload schema';
