-- 066: V0.54 quiet-by-default notifications.
--
-- Pins the build decisions from
--   docs/loop-artifacts/V0.54_QUIET_BY_DEFAULT_SPEC.md
-- (derived from `docs/vision/QUIET_BY_DEFAULT_AUDIT.md`, commit
-- 9de5040). Two opt-in columns + two dedicated RPCs + three read
-- RPCs redefined to surface the new columns for the iOS cadence /
-- mute gates in `NotificationDispatcher`.
--
--   1. `room_memberships.notifications_enabled` (default false)
--      Per-room opt-in, the current user's own preference for
--      receiving logistics pushes for this room's events. The
--      on-create / T-48h / morning-of fan-out only reaches
--      members who have set this to true (mirror of the
--      V0.9 `member_drowning_opt_in` pattern, migration 044/045).
--
--   2. `event_rsvps.notifications_muted` (default false)
--      Per-event, per-member. One-tap mute from the briefing
--      slot. Does NOT touch the room's `notifications_enabled`.
--      The row is upserted on the caller's behalf by the
--      `set_event_notifications_muted` RPC.
--
-- Read surface:
--
--   * `get_my_rooms` is redefined to include
--     `notifications_enabled boolean` (mirrors the migration-052
--     shape with the new column). Room-level opt-in drives the
--     BriefingSlot toggle in `RoomDetailView`.
--   * `get_room_members` is redefined to include
--     `notifications_enabled boolean` from each member's row, so
--     the cadence fan-out can filter the roster by their opt-in.
--   * `get_event_rsvps` is redefined to include
--     `notifications_muted boolean` from each member's event
--     row, so the muted ids can be derived from the existing
--     `eventRSVPsByEvent` cache without a second round trip.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/066_quiet_by_default_notifications.sql

-- =================================================================
-- 1. room_memberships.notifications_enabled
-- =================================================================
alter table public.room_memberships
  add column if not exists notifications_enabled boolean not null default false;

comment on column public.room_memberships.notifications_enabled is
  'When true, this member opted in to receiving pre-play logistics '
  'pushes (on-create, T-48h, morning-of) for this room. Default false '
  '(quiet-by-default; the iOS cadence gates fan-out on this column). '
  'Per-room: a member may opt in here and not in another room.';

-- =================================================================
-- 2. event_rsvps.notifications_muted
-- =================================================================
alter table public.event_rsvps
  add column if not exists notifications_muted boolean not null default false;

comment on column public.event_rsvps.notifications_muted is
  'When true, the dispatcher skips this member for every push on '
  'this event (on-create, T-48h, morning-of). Does NOT touch '
  'room_memberships.notifications_enabled — a one-tap per-event '
  'mute that does not switch the room preference.';

-- =================================================================
-- 3. set_notifications_enabled RPC
-- Mirrors the V0.9 `set_drowning_opt_in` shape verbatim
-- (migration 045): security-definer, updates only the caller's own
-- membership row. RLS already lets the member update their own row
-- (per migration 004) but the dedicated RPC keeps the column-write
-- contract explicit.
-- =================================================================
create or replace function public.set_notifications_enabled(
  p_room_id uuid,
  p_enabled boolean
)
returns void
language sql
security definer
stable
set search_path = public
as $$
  update public.room_memberships
    set notifications_enabled = p_enabled
    where room_id = p_room_id
      and user_id = public.current_user_id();
$$;

grant execute on function public.set_notifications_enabled(uuid, boolean) to authenticated;

comment on function public.set_notifications_enabled(uuid, boolean) is
  'Caller flips their own room_memberships.notifications_enabled for the '
  'given room. Used by the BriefingSlot toggle in RoomDetailView. '
  'security-definer; RLS + the current_user_id() scope keep the update '
  'constrained to the caller''s own row.';

-- =================================================================
-- 4. set_event_notifications_muted RPC
-- Upserts the caller's own event_rsvps row for the event with the
-- given muted state. RLS lets a member write their own event_rsvps
-- row; the dedicated RPC keeps the contract explicit and is the
-- read-side author of truth for `event_rsvps.notifications_muted`.
-- Room scope derives from the event server-side (F-IDENT-01).
-- =================================================================
create or replace function public.set_event_notifications_muted(
  p_event_id uuid,
  p_muted boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  insert into public.event_rsvps (event_id, member_id, state, notifications_muted)
  values (p_event_id, v_caller, 'unclaimed', p_muted)
  on conflict (event_id, member_id) do update set
    notifications_muted = excluded.notifications_muted;
end;
$$;

grant execute on function public.set_event_notifications_muted(uuid, boolean) to authenticated;

comment on function public.set_event_notifications_muted(uuid, boolean) is
  'Caller upserts their own event_rsvps row for the event with the given '
  'notifications_muted state. Room scope derives from the event server-side '
  '(F-IDENT-01). security-definer; the per-row RLS on event_rsvps remains '
  'the load-bearing constraint.';

-- =================================================================
-- 5. get_my_rooms — redefined to surface notifications_enabled.
-- Mirrors the migration-052 column list (already carries
-- member_drowning_opt_in) with the new flag appended so the
-- BriefingSlot opt-in toggle can read it straight from the cached
-- Room.
-- =================================================================
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
  notifications_enabled boolean
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
    coalesce(m.notifications_enabled, false) as notifications_enabled
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

-- =================================================================
-- 6. get_room_members — redefined to include notifications_enabled.
-- Mirrors the migration-059 full-column shape with the new flag
-- appended so the iOS cadence can filter the roster by their
-- per-room opt-in.
-- =================================================================
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid,
  room_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  team text,
  joined_at timestamptz,
  last_seen_at timestamptz,
  preferences_social text,
  preferences_conversation_prompt text,
  preferences_default_set boolean,
  notifications_enabled boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select m.user_id, m.room_id, u.display_name, m.role::text,
         m.points_balance, m.season_score, m.team,
         m.joined_at, m.last_seen_at,
         m.preferences_social, m.preferences_conversation_prompt,
         m.preferences_default_set,
         coalesce(m.notifications_enabled, false) as notifications_enabled
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;

-- =================================================================
-- 7. get_event_rsvps — redefined to surface notifications_muted.
-- Mirrors the migration-047 shape verbatim with the new flag
-- appended so the iOS dispatcher can derive the muted member ids
-- from the existing `eventRSVPsByEvent` cache.
-- =================================================================
drop function if exists public.get_event_rsvps(uuid);
create or replace function public.get_event_rsvps(p_event_id uuid)
returns table (
  event_id uuid,
  member_id uuid,
  display_name text,
  state text,
  notifications_muted boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Caller must be a member of the event's room.
  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = auth.uid()
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  return query
    select
      p_event_id::uuid as event_id,
      rm.user_id as member_id,
      u.display_name as display_name,
      coalesce(er.state::text, 'unclaimed') as state,
      coalesce(er.notifications_muted, false) as notifications_muted
    from public.room_memberships rm
    join public.users u on u.id = rm.user_id
    left join public.event_rsvps er
      on er.event_id = p_event_id and er.member_id = rm.user_id
    where rm.room_id = v_room_id
    order by case when rm.role = 'host' then 0 else 1 end, u.display_name;
end;
$$;

grant execute on function public.get_event_rsvps(uuid) to authenticated;
