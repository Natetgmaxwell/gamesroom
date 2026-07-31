-- 019: Per-room season score (denormalized cache).
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/019_season_score.sql

-- 1. New column. Default 0 so existing rows stay sensible. The denormalized
--    cache is kept in sync by withdraw_casino_chips (decrement) and
--    settle_casino_session (increment); get_room_members reads it.
alter table public.room_memberships
  add column if not exists season_score bigint not null default 0;

-- 2. get_room_members: include season_score so the iOS leaderboard can
--    render the score caption, and update the ORDER BY to put the host
--    first then highest-score then name. DROP then CREATE because the
--    RETURNS TABLE column list changed; Postgres refuses CREATE OR REPLACE
--    on row type differences (error 42P13).
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint
)
language sql
security definer
stable
as $$
  select m.user_id, u.display_name, m.role::text,
         m.points_balance, m.season_score
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;

-- 3. withdraw_casino_chips: also decrement season_score so a withdrawal
--    reduces both the spendable balance and the leaderboard score. The
--    existing function only INSERTed into casino_withdrawals; we add an
--    UPDATE that resolves the room from room_memberships (oldest join,
--    matching the typical single-room-open case).
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
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_points is null or p_points <= 0 then
    raise exception 'Points must be positive' using errcode = '23514';
  end if;

  -- Existing behavior: record the withdrawal.
  insert into public.casino_withdrawals (session_id, member_id, points_withdrawn, withdrawn_by)
  values (p_session_id, p_member_id, p_points, v_caller);

  -- Resolve the member's room (oldest membership) and decrement season_score.
  select m.room_id into v_room_id
    from public.room_memberships m
    where m.user_id = p_member_id
    order by m.joined_at asc
    limit 1;

  if v_room_id is not null then
    update public.room_memberships
      set season_score = season_score - p_points
      where user_id = p_member_id and room_id = v_room_id;
  end if;

  return true;
end;
$$;

grant execute on function public.withdraw_casino_chips(uuid, uuid, int) to authenticated;

-- 4. settle_casino_session: also increment season_score per settled member
--    so a settlement increases both the spendable balance (via the
--    transactions ledger) and the leaderboard score. The existing function
--    already iterates p_settlements and writes one transactions row per
--    member; we add an UPDATE inside the same loop, after the INSERT.
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

  -- Find room from a withdrawal in this session
  select cw.member_id into v_member_id
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id
    limit 1;

  -- Resolve room from the caller's rooms
  select r.id into v_room_id
    from public.rooms r
    where r.created_by = v_caller
    limit 1;

  if v_room_id is null then
    raise exception 'Room not found for host' using errcode = 'P0002';
  end if;

  -- Write one transaction row per member
  for v_item in select * from jsonb_array_elements(p_settlements)
  loop
    v_member_id := (v_item->>'member_id')::uuid;
    v_amount := (v_item->>'amount_points')::int;
    v_snapshot := v_item->>'vision_snapshot';

    insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
    values (v_room_id, p_session_id, v_member_id, 'casino_settlement', v_amount,
            jsonb_build_object('vision_snapshot', v_snapshot), v_caller);

    -- Increment season_score for the settled member.
    update public.room_memberships
      set season_score = season_score + v_amount
      where user_id = v_member_id and room_id = v_room_id;
  end loop;

  return true;
end;
$$;

grant execute on function public.settle_casino_session(uuid, jsonb) to authenticated;