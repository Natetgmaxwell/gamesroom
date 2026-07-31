-- 028: Casino settle → balance conversion. Idempotent safety net.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/028_casino_settle_balance_update.sql
--
-- Why this exists
-- ---------------
-- Migration 014 shipped the original `settle_casino_session` RPC, which
-- only wrote a `transactions` row. It did NOT update `points_balance` or
-- `season_score` on `room_memberships`. As a result, the member's
-- spendable balance never moved at cashout — exactly the Felt Faction
-- "net_worth doesn't update" bug from 2026-06-30, now in the casino pack.
--
-- Migration 025 was supposed to fix this (the 025 body updates both
-- `points_balance` and `season_score`). If 025 was never applied, the bug
-- is still live. This migration 028 makes the fix idempotent: the new
-- function body is the 025 version verbatim, and it uses
-- `CREATE OR REPLACE` so re-applying 028 over 025 (or 025 over 028) is
-- safe and the live DB always ends up with the same correct function.
--
-- The body also derives `room_id` from the event/session id (the 025
-- identity fix), so this migration is a strict superset of 025's
-- `settle_casino_session` change.

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
  v_withdrawals_total bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Derive room from the event/session id. The event row IS the session.
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

  -- Validate the settlements array: every member must have a withdrawal
  -- row for this session (so we know the chip bracket they were playing
  -- against) and the array must not be empty.
  select coalesce(sum(points_withdrawn), 0) into v_withdrawals_total
    from public.casino_withdrawals
    where session_id = p_session_id;

  if v_withdrawals_total = 0 then
    raise exception 'No withdrawals recorded for this session. Nothing to settle.' using errcode = '23514';
  end if;

  if jsonb_array_length(p_settlements) = 0 then
    raise exception 'Settlements array is empty' using errcode = '23502';
  end if;

  -- For each settlement: write a transaction row AND update the member's
  -- balance + leaderboard score in the same loop. The two writes are in
  -- the same transaction; either both commit or both roll back.
  for v_item in select * from jsonb_array_elements(p_settlements)
  loop
    v_member_id := (v_item->>'member_id')::uuid;
    v_amount    := (v_item->>'amount_points')::int;
    v_snapshot  := v_item->'vision_snapshot';

    -- The member must have withdrawn in this session. Without a withdrawal
    -- row, we can't reconcile the chip value against the chip bracket.
    if not exists (
      select 1 from public.casino_withdrawals cw
      where cw.session_id = p_session_id and cw.member_id = v_member_id
    ) then
      raise exception 'Member % has no withdrawal in this session', v_member_id
        using errcode = '23502';
    end if;

    -- Confirm the member is still in the room.
    if not exists (
      select 1 from public.room_memberships m
      where m.room_id = v_room_id and m.user_id = v_member_id
    ) then
      raise exception 'Member % is not in the event room', v_member_id
        using errcode = 'P0002';
    end if;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    )
    values (
      v_room_id, p_session_id, v_member_id, 'casino_settlement', v_amount,
      jsonb_build_object('vision_snapshot', v_snapshot), v_caller
    );

    -- THE FIX: apply the net delta to both points_balance and
    -- season_score. The 014 version was missing this line, which is why
    -- settle_casino_session never moved the member's balance.
    update public.room_memberships
      set points_balance = points_balance + v_amount,
          season_score   = season_score   + v_amount
      where user_id = v_member_id and room_id = v_room_id;
  end loop;

  return true;
end;
$$;

grant execute on function public.settle_casino_session(uuid, jsonb) to authenticated;
