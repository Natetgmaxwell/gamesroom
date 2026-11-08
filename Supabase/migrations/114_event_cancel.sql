-- 114_event_cancel.sql
-- Lane S3 — a host can cancel a night, and cancelling gives every
-- seat deposit back.
--
-- Bodies start from the LIVE definitions pulled 2026-11-08
-- (docs/audit/2026-11-08/live-functions.sql). The live shape is the
-- spec. This lane writes migrations, it never applies them: TARS
-- pushes this file.
--
-- 1. cancel_event(p_event_id) — NEW. Host only (the host role lives
--    on the membership row, so the check is public.is_room_host, not
--    rooms.created_by). Every seat deposit still in escrow returns to
--    its owner exactly the way check_in_seat returns one: the row
--    goes 'returned', the balance is credited, the ledger records it.
--    One transaction, then the night is deleted the way live
--    delete_event deletes one. A cancelled night never costs anyone
--    their deposit.
-- 2. delete_event(p_event_id) — recreated. Same body, plus
--    `set search_path = public` (the live one has none) and the host
--    check moved onto public.is_room_host. The live guard read
--    `created_by = v_caller OR is_room_host(...)`, so a host who
--    handed the room over kept the delete button; the role on the
--    membership row is the truth.
-- 3. update_event_played_at(p_event_id, p_played_at) — recreated
--    with the same host guard and `set search_path = public`.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/114_event_cancel.sql
--
-- Post-apply verification:
--   select pg_get_function_arguments('public.cancel_event(uuid)'::regprocedure);
--   select pg_get_functiondef('public.delete_event(uuid)'::regprocedure);
--   select pg_get_functiondef('public.update_event_played_at(uuid, timestamp with time zone)'::regprocedure);

begin;

-- ---------------------------------------------------------------------------
-- 1. cancel_event(p_event_id)
--
-- The host's way out of a night. The night is a plan; cancelling it
-- is not a fine. Every deposit still held for that night goes back
-- to the member who paid it, before the event row disappears (the
-- deposit rows ride the cascade, so the credit has to happen first).
-- ---------------------------------------------------------------------------
create or replace function public.cancel_event(p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Host only. The host role lives on the membership row, so a host
  -- who handed the room over loses the button with the role.
  if not public.is_room_host(v_room_id, v_caller) then
    raise exception 'Only the host can cancel a night' using errcode = '42501';
  end if;

  -- Every deposit still in escrow goes back, the way check_in_seat
  -- returns one.
  for v_deposit in
    select sd.id, sd.room_id, sd.user_id, sd.amount
    from public.seat_deposits sd
    where sd.event_id = p_event_id
      and sd.status = 'held'
    for update
  loop
    update public.seat_deposits
      set status = 'returned', returned_at = now(), settled_at = now()
      where id = v_deposit.id;

    if v_deposit.amount > 0 then
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_deposit.room_id and user_id = v_deposit.user_id;

      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_deposit.room_id, p_event_id, v_deposit.user_id, 'seat_deposit_return', v_deposit.amount,
        jsonb_build_object('via', 'cancel', 'deposit_id', v_deposit.id),
        v_caller
      );
    end if;
  end loop;

  -- The night goes away the way live delete_event removes one: its
  -- packs first, then the event row. The RSVPs and the deposit rows
  -- ride the cascade.
  delete from public.event_packs where event_id = p_event_id;
  delete from public.events where id = p_event_id;

  return true;
end;
$$;

revoke all on function public.cancel_event(uuid) from public, anon;
grant execute on function public.cancel_event(uuid) to authenticated, service_role;

comment on function public.cancel_event(uuid) is
  'S3.2 — host-only. Cancels a night and returns every seat deposit still held for it to its owner (the check_in_seat return path), then deletes the event. A cancelled night costs nobody their deposit.';

-- ---------------------------------------------------------------------------
-- 2. delete_event(p_event_id)
--
-- Live body, two changes: `set search_path = public` (the live one
-- runs with no search path at all) and the host guard moved onto
-- public.is_room_host. The live guard read `created_by = v_caller OR
-- public.is_room_host(...)`, so a host who transferred the room kept
-- the delete button; the role on the membership row is the truth.
-- ---------------------------------------------------------------------------
create or replace function public.delete_event(p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not public.is_room_host(v_room_id, v_caller) then
    raise exception 'Only the host can delete events' using errcode = '42501';
  end if;

  delete from public.event_packs where event_id = p_event_id;
  delete from public.events where id = p_event_id;

  return true;
end;
$$;

revoke all on function public.delete_event(uuid) from public, anon;
grant execute on function public.delete_event(uuid) to authenticated, service_role;

comment on function public.delete_event(uuid) is
  'S3.2 — host-only (public.is_room_host). Deletes an event and its packs. Use cancel_event to refund held seat deposits first.';

-- ---------------------------------------------------------------------------
-- 3. update_event_played_at(p_event_id, p_played_at)
--
-- Live body, two changes: `set search_path = public` and the host
-- guard moved onto public.is_room_host. Moving a night is a host
-- move: the role on the membership row is the truth.
-- ---------------------------------------------------------------------------
create or replace function public.update_event_played_at(p_event_id uuid, p_played_at timestamp with time zone)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not public.is_room_host(v_room_id, v_caller) then
    raise exception 'Only the host can change event dates' using errcode = '42501';
  end if;

  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;

  update public.events
    set played_at = p_played_at
    where id = p_event_id;

  return true;
end;
$$;

revoke all on function public.update_event_played_at(uuid, timestamp with time zone) from public, anon;
grant execute on function public.update_event_played_at(uuid, timestamp with time zone) to authenticated, service_role;

comment on function public.update_event_played_at(uuid, timestamp with time zone) is
  'S3.2 — host-only (public.is_room_host). Moves a night to a new time. The date must be in the future.';

commit;

-- 4. Refresh the PostgREST schema cache so cancel_event is visible to
--    the app straight away.
notify pgrst, 'reload schema';
