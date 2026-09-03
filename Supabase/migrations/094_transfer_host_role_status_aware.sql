-- 094: V0.98 fold-in — transfer_host_role status-awareness + untracked-migration repair
--
-- Background:
--   The error "Could not find the function public.transfer_host_role(...)"
--   (2026-09-03, promote-to-host from the Members sheet) traced to a gap in
--   the live DB: migration 091 was never applied. The project's migration
--   history table (supabase_migrations.schema_migrations) is EMPTY — every
--   migration in this repo was applied ad hoc via `supabase db query`,
--   and 091 slipped through the V0.91 release (its UI shipped in the same
--   commit as the RPC, so nothing exercised the RPC until now).
--
--   This migration:
--     1. Applies 091's transfer_host_role (promote/demote, multi-host,
--        last-host guard) — unchanged mechanics.
--     2. Layers membership_status awareness on top (093 fold-in): the
--        caller must be an ACTIVE host, the target must be an ACTIVE
--        member, and the returned roster filters to active rows so a
--        kicked member never reappears client-side.
--
--   Idempotent (create-or-replace; the function did not exist, but re-runs
--   are safe). Comment carried from 091, updated for status-awareness.
--
--   NOTE 2026-09-03: 091's function was found UNAPPLIED in the live DB
--   (the V0.91 promote-to-host RPC 404'd from the app — "Could not find
--   the function public.transfer_host_role"). This file re-homes 091's
--   mechanics plus the 093 status filters. 091 itself is superseded by
--   this file; both remain in history.

-- =================================================================
-- 1. transfer_host_role(p_room_id, p_target_user_id, p_action)
--    (091 mechanics + 093 status filters)
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

  -- 3. Caller must be an ACTIVE host in this room. Role-based (not
  --    rooms.created_by) so multi-host inherits naturally. The
  --    membership_status filter is the 093 fold-in — a kicked row can
  --    never confer host powers.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller
      and role = 'host'
      and membership_status = 'active'
  ) then
    raise exception 'not_authorized: caller is not a host in this room'
      using errcode = '42501';
  end if;

  -- 4. Target must be an ACTIVE member of this room (kicked rows are
  --    invisible to promote/demote — use remove_room_member/redeem flow).
  select role into v_target_role
  from public.room_memberships
  where room_id = p_room_id
    and user_id = p_target_user_id
    and membership_status = 'active';
  if not found then
    raise exception 'not_found: target is not an active member of this room'
      using errcode = 'P0002';
  end if;

  -- 5. Apply the change.
  if p_action = 'promote' then
    -- Idempotent: same-value UPDATE matches 0 rows (no spurious
    -- updated_at bump).
    update public.room_memberships
    set role = 'host'
    where room_id = p_room_id
      and user_id = p_target_user_id
      and role <> 'host';
  elsif p_action = 'demote' then
    -- Last-ACTIVE-host guard. Count before the update so the count is
    -- accurate even when the caller demotes themselves.
    select count(*) into v_host_count
    from public.room_memberships
    where room_id = p_room_id
      and role = 'host'
      and membership_status = 'active';
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

  -- 6. Return the ACTIVE roster so iOS rebuilds from one call. A kicked
  --    member must never reappear in the client cache via this path.
  return query
    select * from public.room_memberships
    where room_id = p_room_id
      and membership_status = 'active';
end;
$$;

revoke all on function public.transfer_host_role(uuid, uuid, text) from public;
grant execute on function public.transfer_host_role(uuid, uuid, text) to authenticated;

comment on function public.transfer_host_role(uuid, uuid, text) is
  'V0.91 mechanics (promote/demote, multi-host, last_host guard) + V0.98 status-awareness: caller must be an active host, target an active member, returned roster active-only. Originally shipped in 091 but found unapplied in the live DB on 2026-09-03 (promote-to-host 404 from the app); re-homed here with the 093 filters.';
