-- 017: Per-room points balance (denormalized cache).
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/017_member_points_balance.sql

-- 1. Add the column. Default 0 so any path that doesn't explicitly set
--    it (e.g. an out-of-date trigger) leaves a sensible value rather
--    than NULL. The backfill below overrides it to the onboarding default.
alter table public.room_memberships
  add column if not exists points_balance bigint not null default 0;

-- 2. Backfill: every existing member starts on the onboarding default
--    so they have points to withdraw for the casino pack.
update public.room_memberships set points_balance = 200;

-- 3. handle_new_room: when a room is created, the host is auto-inserted
--    as a 'host' membership. Give them the onboarding default here so
--    they don't have to wait for a backfill.
create or replace function public.handle_new_room()
returns trigger as $$
begin
  insert into public.room_memberships (room_id, user_id, role, points_balance)
  values (new.id, new.created_by, 'host', 200);
  return new;
end;
$$ language plpgsql security definer;

-- 4. redeem_join_code: give the joining member the onboarding default.
--    The trigger on rooms already covers the host path; this covers the
--    member path. Idempotency branch is unchanged — re-redeem by an
--    existing member returns the room without mutating points_balance.
create or replace function public.redeem_join_code(code text)
returns table(room_id uuid, room_name text)
language plpgsql
security definer
as $$
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
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

  -- Insert membership with the onboarding points default.
  insert into public.room_memberships (room_id, user_id, role, points_balance)
  values (v_room_id, v_user_id, 'member', 200);

  -- Mark code redeemed.
  update public.join_codes jc
  set redeemed_at = now(), redeemed_by = v_user_id
  where jc.code = upper(redeem_join_code.code);

  -- Return the room.
  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name;
end;
$$;

-- 5. get_room_members: include points_balance so the iOS slider can read
--    the current user's balance. DROP then CREATE because the RETURNS TABLE
--    column list changed; Postgres refuses CREATE OR REPLACE on row type
--    differences (error 42P13).
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (user_id uuid, display_name text, role text, points_balance bigint)
language sql
security definer
stable
as $$
  select m.user_id, u.display_name, m.role::text, m.points_balance
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end, u.display_name;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;

-- 6. withdraw_casino_chips: decrement the denormalized balance and write
--    a ledger row. The original RPC only INSERTed into casino_withdrawals
--    and never touched the per-room balance, so withdrawing 10 points
--    from a fresh account left the balance unchanged.
--
--    Room resolution: the iOS caller passes only sessionId/memberId/points.
--    We resolve the member's room from room_memberships (limit 1). For a
--    user with multiple room memberships this picks the oldest; matches
--    the typical case where a user has one room open at a time.
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

  -- Resolve the room + read the current balance for the guard.
  select m.room_id, m.points_balance
    into v_room_id, v_current_balance
  from public.room_memberships m
  where m.user_id = p_member_id
  order by m.joined_at asc
  limit 1;

  if v_room_id is null then
    raise exception 'No room membership for member' using errcode = 'P0002';
  end if;

  -- Guard: refuse if the member doesn't have enough points.
  if v_current_balance < p_points then
    raise exception 'Insufficient points balance' using errcode = '23514';
  end if;

  -- Decrement the denormalized balance.
  update public.room_memberships
    set points_balance = points_balance - p_points
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