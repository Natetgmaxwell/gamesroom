-- 102_roster_caller_guard.sql
-- Security fix (2026-10-22, applied live by TARS on Nathan's approval).
--
-- get_room_members is SECURITY DEFINER. Migrations 066 and 093 granted
-- EXECUTE to authenticated but never revoked the default PUBLIC grant,
-- and the body had no caller check, so anyone holding the app's anon key
-- and a room id could read that room's roster, including
-- preferences_social (designed host-visible only).
--
-- Fix: same signature and columns as live (no client change), plus a
-- guard that the caller is an active member of the room, and EXECUTE
-- for authenticated only.

begin;

create or replace function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid, room_id uuid, display_name text, role text,
  points_balance bigint, season_score bigint, team text,
  joined_at timestamptz, last_seen_at timestamptz,
  preferences_social text, preferences_conversation_prompt text,
  preferences_default_set boolean, notifications_enabled boolean
)
language sql
stable
security definer
set search_path = ''
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
    and m.membership_status = 'active'
    and exists (
      select 1 from public.room_memberships c
       where c.room_id = p_room_id
         and c.user_id = public.current_user_id()
         and c.membership_status = 'active'
    )
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

revoke all on function public.get_room_members(uuid) from public, anon;
grant execute on function public.get_room_members(uuid) to authenticated, service_role;

commit;
