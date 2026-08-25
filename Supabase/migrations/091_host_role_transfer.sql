-- 091: V0.91 — Host promotion + multi-host support
--
-- Background:
--   Games Room has always been single-host: the creator is the host,
--   the host role is set on room creation (migration 004 trigger), and
--   the only way to change who hosted a room was "delete the room and
--   create a new one" — which destroys the room's history.
--
--   This migration introduces a single RPC, `transfer_host_role`, that
--   promotes a member to host or demotes a host back to member. A room
--   can have N hosts as long as N ≥ 1. The two-case `RoomRole` enum
--   (`.host | .member`) does not change; multi-host is achieved by
--   allowing >1 row with role = 'host' in `room_memberships`.
--
-- Authorisation:
--   The caller must already be a host in the room (their own
--   `room_memberships.role = 'host'` for the target room). Any host
--   can promote any member; any host can demote any host EXCEPT the
--   last host. The function is SECURITY DEFINER so it can update
--   `role` regardless of the per-row RLS write policy on
--   `room_memberships` (which denies direct inserts/updates; the
--   policy is on the table, the function bypasses it via
--   security-definer with a locked search_path).
--
-- Edge cases:
--   - promote when target is already a host → idempotent (no-op).
--   - demote when target is the last host → 'last_host' error.
--   - non-host caller → 'not_authorized' error.
--   - target not in this room → 'not_found' error.
--   - p_action not in ('promote','demote') → 'invalid_action' error.
--
-- Returns the full `room_memberships` roster for the room (one row
-- per member) so the iOS client can rebuild the cache from a single
-- round-trip. `setof room_memberships` matches the schema directly.
--
-- Idempotent: CREATE OR REPLACE; safe to re-apply.

-- =================================================================
-- 1. transfer_host_role(p_room_id, p_target_user_id, p_action)
-- =================================================================
create or replace function public.transfer_host_role(
  p_room_id uuid,
  p_target_user_id uuid,
  p_action text  -- 'promote' | 'demote'
)
returns setof public.room_memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := auth.uid();
  v_target_role text;
  v_host_count int;
begin
  -- 1. Auth check (cheap, first).
  if v_caller is null then
    raise exception 'not_authenticated: caller is not signed in'
      using errcode = '42501';
  end if;

  -- 2. Action whitelist.
  if p_action not in ('promote', 'demote') then
    raise exception 'invalid_action: must be promote or demote'
      using errcode = '22023';
  end if;

  -- 3. Caller must be a host in this room. Uses the table itself
  -- (no dependency on `rooms.created_by` so multi-host inherits
  -- naturally — the second promoted host can also promote/demote).
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller
      and role = 'host'
  ) then
    raise exception 'not_authorized: caller is not a host in this room'
      using errcode = '42501';
  end if;

  -- 4. Target must be a member in this room.
  select role into v_target_role
  from public.room_memberships
  where room_id = p_room_id
    and user_id = p_target_user_id;
  if not found then
    raise exception 'not_found: target is not a member of this room'
      using errcode = 'P0002';
  end if;

  -- 5. Apply the change.
  if p_action = 'promote' then
    -- Idempotent: setting role='host' on a row that's already 'host'
    -- is a no-op at the column level (no updated_at bump from a
    -- same-value write since the trigger fires per-row on UPDATE,
    -- but the BEFORE-UPDATE trigger on room_memberships only stamps
    -- updated_at when the row actually changes; same-value UPDATE
    -- matches 0 rows by default. We force it with the WHERE clause
    -- so the no-op doesn't bump updated_at spuriously.)
    update public.room_memberships
    set role = 'host'
    where room_id = p_room_id
      and user_id = p_target_user_id
      and role <> 'host';
  elsif p_action = 'demote' then
    -- Last-host guard. Count BEFORE the update so the count is
    -- accurate even if the caller is demoting themselves.
    select count(*) into v_host_count
    from public.room_memberships
    where room_id = p_room_id
      and role = 'host';
    if v_host_count <= 1 and v_target_role = 'host' then
      raise exception 'last_host: a room must always have at least one host'
        using errcode = 'P0001';
    end if;
    update public.room_memberships
    set role = 'member'
    where room_id = p_room_id
      and user_id = p_target_user_id
      and role = 'host';
  end if;

  -- 6. Return the full roster so iOS can rebuild from one call.
  return query
    select * from public.room_memberships
    where room_id = p_room_id;
end;
$$;

revoke all on function public.transfer_host_role(uuid, uuid, text) from public;
grant execute on function public.transfer_host_role(uuid, uuid, text) to authenticated;

comment on function public.transfer_host_role(uuid, uuid, text) is
  'V0.91 — host promotes a member to host or demotes a host to member. Multi-host: a room can have N hosts (N ≥ 1). The caller must already be a host in the room. Demoting the last host fails with last_host.';