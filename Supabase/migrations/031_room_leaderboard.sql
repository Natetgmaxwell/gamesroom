-- 031: Season leaderboard RPC.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/031_room_leaderboard.sql
--
-- V0.31 — get_room_leaderboard(p_room_id). Returns one row per
-- member with their points_balance, season_score, sessions_played,
-- last_session_at, last_session_delta, and a trajectory JSONB array
-- of the last 7 casino_settlement deltas (most recent last) for
-- the trajectory sparkline.

-- 1. The RPC. Per-member aggregates are computed via lateral join
--    so the host gets one row per member with the same shape. The
--    trajectory is a JSONB array of {session_id, delta} pairs, oldest
--    first. Trajectory maxes at 7 entries.
create or replace function public.get_room_leaderboard(p_room_id uuid)
returns table (
  user_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  sessions_played bigint,
  last_session_at timestamptz,
  last_session_delta bigint,
  trajectory jsonb
)
language sql
security definer
stable
as $$
  with
  -- All session deltas for the room's members. Grouped by
  -- (session, member) so multi-transaction sessions collapse to
  -- one delta. The kind='casino_settlement' filter keeps the
  -- per-session net, not the per-round movement.
  session_deltas as (
    select
      t.member_id,
      t.session_id,
      sum(t.amount_points)::bigint as delta,
      max(t.created_at) as created_at
    from public.transactions t
    join public.room_memberships m
      on m.user_id = t.member_id and m.room_id = t.room_id
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
    group by t.member_id, t.session_id
  ),
  -- Last 7 deltas per member, ordered oldest-to-newest. Use
  -- row_number over a per-member order-by-created_at-desc so the
  -- subquery can pick the most recent N; then re-sort in the
  -- jsonb_agg so the trajectory reads forward in time.
  recent_per_member as (
    select
      sd.member_id,
      sd.session_id,
      sd.delta,
      sd.created_at,
      row_number() over (partition by sd.member_id order by sd.created_at desc) as rn
    from session_deltas sd
  ),
  trajectory_per_member as (
    select
      rpm.member_id,
      jsonb_agg(
        jsonb_build_object('session_id', rpm.session_id, 'delta', rpm.delta)
        order by rpm.created_at asc
      ) as trajectory
    from recent_per_member rpm
    where rpm.rn <= 7
    group by rpm.member_id
  ),
  aggregates_per_member as (
    select
      sd.member_id,
      count(*) as sessions_played,
      max(sd.created_at) as last_session_at
    from session_deltas sd
    group by sd.member_id
  ),
  last_delta_per_member as (
    select distinct on (sd.member_id)
      sd.member_id,
      sd.delta as last_session_delta
    from session_deltas sd
    order by sd.member_id, sd.created_at desc
  )
  select
    m.user_id,
    coalesce(u.display_name, 'Member') as display_name,
    m.role::text as role,
    m.points_balance,
    m.season_score,
    coalesce(aggr.sessions_played, 0) as sessions_played,
    aggr.last_session_at,
    coalesce(ld.last_session_delta, 0) as last_session_delta,
    coalesce(trajectory.trajectory, '[]'::jsonb) as trajectory
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  left join aggregates_per_member aggr on aggr.member_id = m.user_id
  left join last_delta_per_member ld on ld.member_id = m.user_id
  left join trajectory_per_member trajectory on trajectory.member_id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_leaderboard(uuid) to authenticated;
