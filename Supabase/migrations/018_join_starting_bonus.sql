-- 018: Per-room join starting bonus.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/018_join_starting_bonus.sql

-- 1. New column. Default 200 keeps existing rooms on the prior behavior
--    (redeem_join_code previously hardcoded 200). Check >= 0 keeps the
--    slider's range honest at the SQL layer.
alter table public.rooms
  add column if not exists join_starting_bonus integer
  not null default 200
  check (join_starting_bonus >= 0);

-- 2. redeem_join_code: read the bonus from the room instead of the
--    hardcoded 200. The idempotency branch is unchanged — re-redeeming
--    for an existing member returns the room without mutating their
--    points_balance.
create or replace function public.redeem_join_code(code text)
returns table(room_id uuid, room_name text)
language plpgsql
security definer
as $$
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
  v_bonus integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Find an unredeemed code.
  select jc.room_id into v_room_id
  from public.join_codes jc
  where jc.code = upper(redeem_join_code.code)
    and jc.redeemed_at is null
  for update;

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Idempotency: if already a member, return the room but don't double-insert.
  if exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = v_user_id
  ) then
    select r.name into v_room_name from public.rooms r where r.id = v_room_id;
    return query select v_room_id, v_room_name;
    return;
  end if;

  -- Look up the per-room join starting bonus.
  select r.join_starting_bonus into v_bonus
  from public.rooms r
  where r.id = v_room_id;

  -- Insert membership with the per-room bonus.
  insert into public.room_memberships (room_id, user_id, role, points_balance)
  values (v_room_id, v_user_id, 'member', v_bonus);

  -- Mark code redeemed.
  update public.join_codes jc
  set redeemed_at = now(), redeemed_by = v_user_id
  where jc.code = upper(redeem_join_code.code);

  -- Return the room.
  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name;
end;
$$;

-- 3. update_room: round-trip the new column. Existing parameters stay
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
  p_join_starting_bonus integer default 200
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
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$$;

grant execute on function public.update_room(
  uuid, text, text, public.mascot_personality, int, int, text, integer
) to authenticated;

-- 4. get_my_rooms: include the new column so the iOS Room decode
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
    m.role::text as user_role
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;