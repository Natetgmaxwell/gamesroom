-- 071: Break rooms↔room_memberships SELECT-policy recursion (42P17).
--
-- Under `authenticated`, direct SELECT on `events` (and any table
-- whose SELECT policy references `room_memberships`) failed with:
--   ERROR 42P17: infinite recursion detected in policy for relation "room_memberships"
-- Cause: the rooms "member sees room" policy (004/005) checks
-- room_memberships, and the room_memberships "host sees room members"
-- policy (004/005) checks rooms; both tables have RLS, so each side
-- re-enters the other's SELECT policies and recurses.
--
-- Fix: SECURITY DEFINER helper is_room_member() reads room_memberships
-- on the rooms side; the cycle is broken because SECURITY DEFINER
-- bypasses room_memberships RLS. The room_memberships "host sees room
-- members" policy is unchanged — with the rooms side broken, its
-- reference to rooms no longer recurses.
--
-- Apply via (db password rotated 2026-08; if psql auth fails use
-- `supabase db query --linked -f <this file>` from Supabase/ with the
-- access token in ~/.supabase/):
--   supabase db query --linked -f Supabase/migrations/071_break_rls_policy_recursion.sql

-- =================================================================
-- 1. is_room_member() — SECURITY DEFINER helper that bypasses
--    room_memberships RLS, breaking the cycle on the rooms side.
-- =================================================================
create or replace function public.is_room_member(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.room_memberships m
    where m.room_id = p_room_id
      and m.user_id = public.current_user_id()
  );
$$;

grant execute on function public.is_room_member(uuid) to authenticated;
revoke execute on function public.is_room_member(uuid) from anon;

comment on function public.is_room_member(uuid) is
  'Returns true when the caller (from JWT) has a room_memberships row for '
  'p_room_id. SECURITY DEFINER so the rooms "member sees room" policy can '
  'check membership without re-entering room_memberships RLS (fixes 42P17, '
  'migration 071).';

-- =================================================================
-- 2. Rooms policy — drop + recreate via the helper.
-- =================================================================
drop policy if exists "member sees room" on public.rooms;
create policy "member sees room" on public.rooms
  for select using (public.is_room_member(rooms.id));