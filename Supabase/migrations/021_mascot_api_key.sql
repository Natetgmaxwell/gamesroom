-- 021: Mascot API key fallback (per-room, OpenAI-compatible).
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/021_mascot_api_key.sql

-- 1. New column. Nullable; null means "no key set, fall through to
--    on-device Foundation Models or rest". Plaintext per spec
--    (encryption is v0.10+ work; matches the existing casino_room_config
--    plaintext pattern).
alter table public.rooms
  add column if not exists mascot_api_key text;

-- 2. update_room: round-trip the new column. Existing parameters stay
--    in place; the new one is appended with a default so old callers
--    keep working.
create or replace function public.update_room(
  p_room_id uuid,
  p_name text,
  p_mascot_name text,
  p_mascot_personality public.mascot_personality,
  p_member_invite_quota int,
  p_max_seats int,
  p_mascot_political_ideology text default 'centrist',
  p_join_starting_bonus integer default 200,
  p_mascot_api_key text default null
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

  if p_join_starting_bonus < 0 then
    raise exception 'join_starting_bonus must be >= 0' using errcode = '23514';
  end if;

  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      join_starting_bonus = p_join_starting_bonus,
      mascot_api_key = p_mascot_api_key,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$$;

grant execute on function public.update_room(
  uuid, text, text, public.mascot_personality, int, int, text, integer, text
) to authenticated;

-- 3. get_my_rooms: include the new column so the iOS Room decode
--    succeeds. DROP then CREATE because the RETURNS TABLE column list
--    changed; Postgres refuses CREATE OR REPLACE when the row type
--    differs (error 42P13).
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
  user_role text
)
language sql
security definer
stable
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    r.join_starting_bonus,
    r.mascot_api_key,
    m.role::text as user_role
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;
