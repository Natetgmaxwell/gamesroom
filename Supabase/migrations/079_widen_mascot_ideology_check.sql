-- 079: Widen rooms.mascot_political_ideology CHECK to the V0.82 voices.
--
-- Bug class: V0.82 added six new mascot ideologies (communist,
-- conservative, liberal, apolitical, farRight, altRight) to the iOS
-- enum and the 770-cell voice matrix, but the live CHECK constraint
-- on public.rooms still accepts only the original five. Any save of
-- the new values failed with:
--
--   new row for relation "rooms" violates check constraint
--   "rooms_mascot_political_ideology_check"
--
-- The column is plain text (no Postgres enum type); the RPCs the app
-- calls (update_room_settings, migration 058/061/073) pass the value
-- through unvalidated, so this CHECK is the ONLY gate.
--
-- Live-verified 2026-08-17 before drafting (pg_constraint on the
-- linked project):
--   rooms_mascot_political_ideology_check
--     CHECK (mascot_political_ideology = ANY (ARRAY[
--       'order','centrist','trickster','anarchist','apocalypse']))
--
-- The new values are the iOS enum rawValues (camelCase farRight /
-- altRight — NOT the picker labels "Far-right" / "Alt-right").
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/079_widen_mascot_ideology_check.sql
--
-- Post-apply verification:
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--   WHERE conname = 'rooms_mascot_political_ideology_check';
--   -- must list all 11 values

alter table public.rooms
  drop constraint if exists rooms_mascot_political_ideology_check;

alter table public.rooms
  add constraint rooms_mascot_political_ideology_check
  check (mascot_political_ideology in (
    'order', 'centrist', 'trickster', 'anarchist', 'apocalypse',
    'communist', 'conservative', 'liberal', 'apolitical',
    'farRight', 'altRight'
  ));

-- =================================================================
-- 2. Legacy update_room overload sweep.
-- =================================================================
-- Migration 015's update_room(uuid, text, text, mascot_personality,
-- int, int, text) still carries an inline whitelist
-- (p_mascot_political_ideology not in (...), errcode 22023) that
-- rejects the six new values with a 500 before the CHECK ever sees
-- them. The app calls update_room_settings, but a stale narrower
-- whitelist on any reachable overload is a trap for direct-SQL /
-- admin / future callers — widen it to match the constraint.
-- Signature verified live (pg_get_function_arguments) before
-- drafting: the 7-arg overload with p_mascot_political_ideology
-- default 'centrist'.
drop function if exists public.update_room(uuid, text, text, public.mascot_personality, int, int, text);
create function public.update_room(
  p_room_id uuid,
  p_name text,
  p_mascot_name text,
  p_mascot_personality public.mascot_personality,
  p_member_invite_quota int,
  p_max_seats int,
  p_mascot_political_ideology text default 'centrist'
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  -- No inline whitelist: the rooms CHECK constraint is the single
  -- source of allowed values (V0.82 widened to 11).
  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$$;

grant execute on function public.update_room(uuid, text, text, public.mascot_personality, int, int, text) to authenticated;
