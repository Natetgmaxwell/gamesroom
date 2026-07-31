-- 025: V0.24 — casino event/session identity integrity.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/025_casino_event_integrity.sql
--
-- Prior migrations (014, 017, 019) resolved `room_id` for a withdrawal or
-- settlement by either picking the caller's oldest room_memberships row or
-- the first room the caller hosts. That drifted from the active event the
-- iOS client was actually playing. This migration makes the event/session
-- id the source of truth: `events.id = p_session_id` is the room boundary.
--
-- Withdrawals: the caller must be either the member themselves or the
-- host of the event's room. Settlements: the caller must host the
-- event's room.

-- 1. withdraw_casino_chips: derive room_id from the event/session id.
--    Update both points_balance and season_score in that exact room.
--    Signature preserved: (p_session_id uuid, p_member_id uuid, p_points int)
--    returns boolean.
create or replace function public.withdraw_casino_chips(
  p_session_id uuid,
  p_member_id uuid,
  p_points int
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_current_balance bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_points is null or p_points <= 0 then
    raise exception 'Points must be positive' using errcode = '23514';
  end if;

  -- Derive room from the event/session id. The event row IS the session.
  select e.room_id into v_room_id
    from public.events e
    where e.id = p_session_id;

  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  -- Authorize: the caller must be the withdrawing member, or the host
  -- of the event's room. Anyone else is rejected.
  if v_caller <> p_member_id
     and not exists (
       select 1 from public.rooms r
       where r.id = v_room_id and r.created_by = v_caller
     ) then
    raise exception 'Not authorized to withdraw for this member' using errcode = '42501';
  end if;

  -- Confirm the member is a member of the event's room.
  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = p_member_id
  ) then
    raise exception 'Member is not in the event room' using errcode = 'P0002';
  end if;

  -- Guard against overdraft.
  select m.points_balance into v_current_balance
    from public.room_memberships m
    where m.user_id = p_member_id and m.room_id = v_room_id;
  if v_current_balance is null or v_current_balance < p_points then
    raise exception 'Insufficient points balance' using errcode = '23514';
  end if;

  -- Decrement both the spendable balance and the leaderboard score,
  -- scoped to the event's exact room.
  update public.room_memberships
    set points_balance = points_balance - p_points,
        season_score   = season_score   - p_points
    where user_id = p_member_id and room_id = v_room_id;

  -- Ledger row so future migrations can prefer ledger-based balance.
  insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_by)
  values (v_room_id, p_session_id, p_member_id, 'casino_withdrawal', -p_points, v_caller);

  -- Existing behavior: record the withdrawal.
  insert into public.casino_withdrawals (session_id, member_id, points_withdrawn, withdrawn_by)
  values (p_session_id, p_member_id, p_points, v_caller);

  return true;
end;
$$;

grant execute on function public.withdraw_casino_chips(uuid, uuid, int) to authenticated;

-- 2. settle_casino_session: derive room_id from the event/session id and
--    require the caller to host that room. Store vision_snapshot as JSONB
--    using `v_item->'vision_snapshot'`, not text extraction.
--    Signature preserved: (p_session_id uuid, p_settlements jsonb) returns boolean.
create or replace function public.settle_casino_session(
  p_session_id uuid,
  p_settlements jsonb
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_item jsonb;
  v_member_id uuid;
  v_amount int;
  v_snapshot jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Derive room from the event/session id.
  select e.room_id into v_room_id
    from public.events e
    where e.id = p_session_id;

  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  -- Authorize: caller must host the event's room.
  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the room host can settle' using errcode = '42501';
  end if;

  -- Write one transaction row per member, scoped to the event's room.
  -- Store vision_snapshot as JSONB directly from the element, not as
  -- text extracted via `->>`.
  for v_item in select * from jsonb_array_elements(p_settlements)
  loop
    v_member_id := (v_item->>'member_id')::uuid;
    v_amount    := (v_item->>'amount_points')::int;
    v_snapshot  := v_item->'vision_snapshot';

    insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
    values (v_room_id, p_session_id, v_member_id, 'casino_settlement', v_amount,
            jsonb_build_object('vision_snapshot', v_snapshot), v_caller);

    -- Apply the net delta to both points_balance and season_score for
    -- the event's exact room.
    update public.room_memberships
      set points_balance = points_balance + v_amount,
          season_score   = season_score   + v_amount
      where user_id = v_member_id and room_id = v_room_id;
  end loop;

  return true;
end;
$$;

grant execute on function public.settle_casino_session(uuid, jsonb) to authenticated;
