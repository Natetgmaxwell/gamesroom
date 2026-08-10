-- 049: F-MVP-05 V2-full — team mode + per-round breakdown (W1.6).
--
-- Closes the V2-full follow-up from the 2026-08-10 scope decision
-- (option B shipped as V2-minimal; option C = team mode + per-round
-- breakdown).
--
-- Adds:
--   1. room_memberships.team — nullable text column; the host
--      assigns members to teams for the season. NULL = unassigned.
--   2. set_member_team(p_room_id, p_member_id, p_team) — host-only
--      RPC. Empty string clears the assignment.
--   3. get_event_rounds(p_event_id) — per-round breakdown for one
--      event, reading round_submissions (migration 035) so the
--      leaderboard can render a round-by-round history. Members of
--      the room can read; scope derives from the event (F-IDENT-01).
--   4. get_room_members redefined to include the team column
--      (DROP then CREATE — the RETURNS TABLE column list changed).

-- =================================================================
-- 1. room_memberships.team
-- =================================================================
alter table public.room_memberships
  add column if not exists team text;

comment on column public.room_memberships.team is
  'Host-assigned team label for the season. NULL = unassigned. Drives the F-MVP-05 V2-full team-mode leaderboard grouping.';

-- =================================================================
-- 2. set_member_team RPC
-- =================================================================
create or replace function public.set_member_team(
  p_room_id uuid,
  p_member_id uuid,
  p_team text
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

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can assign teams' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = p_room_id and rm.user_id = p_member_id
  ) then
    raise exception 'Member is not in this room' using errcode = 'P0002';
  end if;

  update public.room_memberships
    set team = nullif(trim(p_team), '')
    where room_id = p_room_id and user_id = p_member_id;
end;
$$;

grant execute on function public.set_member_team(uuid, uuid, text) to authenticated;

comment on function public.set_member_team(uuid, uuid, text) is
  'Host-only. Assigns (or clears, with an empty string) a member''s team label for the season.';

-- =================================================================
-- 3. get_event_rounds RPC
-- =================================================================
create or replace function public.get_event_rounds(p_event_id uuid)
returns table (
  id uuid,
  event_id uuid,
  room_id uuid,
  pack_slug text,
  round_index integer,
  entries jsonb,
  created_by uuid,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select rs.id, rs.event_id, rs.room_id, rs.pack_slug,
         rs.round_index, rs.entries, rs.created_by, rs.created_at
  from public.round_submissions rs
  where rs.event_id = p_event_id
    and exists (
      select 1 from public.events e
      join public.room_memberships rm
        on rm.room_id = e.room_id
      where e.id = p_event_id
        and rm.user_id = public.current_user_id()
    )
  order by rs.round_index asc, rs.created_at asc;
$$;

grant execute on function public.get_event_rounds(uuid) to authenticated;

comment on function public.get_event_rounds(uuid) is
  'Returns the per-round submissions for one event, oldest round first. Room scope derives from the event (F-IDENT-01); members of the event''s room can read.';

-- =================================================================
-- 4. get_room_members + team column
-- =================================================================
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  team text
)
language sql
security definer
stable
set search_path = public
as $$
  select m.user_id, u.display_name, m.role::text,
         m.points_balance, m.season_score, m.team
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;
