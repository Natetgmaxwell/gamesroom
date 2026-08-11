-- 052: W-04 — room deletion expires join codes (US-04).
--
-- Closes the V0.9 slice: the host can delete a room. Two
-- decisions shape this migration:
--
--   1. SOFT DELETE, not hard delete. The ledger
--      (transactions, seat_deposits, season_awards,
--      chapter_lines, drowning rows) survives for disputes.
--      `rooms.deleted_at` is the canonical "this room is dead"
--      marker — non-null after a successful delete.
--   2. JOIN CODES DIE ON DELETE. The existing redeem flow
--      (migration 004) treats a missing row as "code not found
--      or already redeemed" — by removing the join_codes rows
--      for the room, redemption attempts against a deleted
--      room fail with the same P0002 error as a typo'd code.
--      No change to redeem_join_code is needed.
--
-- Surfacing the new state:
--   * `get_my_rooms` (redefined below) skips rooms where
--     `deleted_at IS NOT NULL`, so the deleted room disappears
--     from the host's rooms list immediately.
--   * RLS on `public.rooms` (already in place) does not need
--     to change — the existing "member sees room" / "host sees
--     own rooms" policies still match; the only difference is
--     that the deleted room no longer appears in the SQL view
--     because get_my_rooms filters it.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/052_room_delete.sql

-- =================================================================
-- 1. Additive column: rooms.deleted_at. NULL = live room.
-- =================================================================
alter table public.rooms add column deleted_at timestamptz;

-- =================================================================
-- 2. delete_room RPC — host-only, soft delete, code expiry.
-- =================================================================
create or replace function public.delete_room(p_room_id uuid)
returns boolean
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
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller and deleted_at is null
  ) then
    raise exception 'Only the host can delete a room' using errcode = '42501';
  end if;

  -- Soft delete: the ledger (transactions, seat_deposits, awards) survives
  -- for disputes. Do NOT hard-delete.
  update public.rooms set deleted_at = now() where id = p_room_id;

  -- Expire every open join code for the room.
  delete from public.join_codes where room_id = p_room_id;

  return true;
end;
$$;

grant execute on function public.delete_room(uuid) to authenticated;

comment on function public.delete_room(uuid) is
  'Host-only. Soft-deletes the room (rooms.deleted_at) so the ledger survives for disputes, and expires all open join codes. RLS + get_my_rooms filter deleted rooms.';

-- =================================================================
-- 3. get_my_rooms — redefined to filter deleted rooms out.
-- Mirrors migration 045's shape verbatim, with the deleted-room
-- filter added to the WHERE clause.
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
  member_drowning_opt_in boolean
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
    r.seat_deposit_amount,
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;
