-- 101: season grid (v1.2 slice 2c, card t_08ff9c28). READ-ONLY RPC.
-- NOT DEPLOYED. Ship with the 2c app build, same handling as 100.
--
-- Why: the Seasons comparison needs points per game night per member.
-- Nothing on the client carries that today:
--   * get_room_leaderboard.trajectory is the last 7 sessions per
--     member, all-time (not season-scoped), with no dates.
--   * get_season_history.score_progression is the CALLER's arc only.
-- The data itself exists: every scored night writes transactions
-- with session_id = events.id (casino_settlement + round_score).
--
-- get_season_grid(p_room_id, p_season_id default null) returns one row
-- per (night, member) inside the season window:
--   * p_season_id null  -> the room's active season (started_at..now()).
--   * p_season_id given -> that season (started_at..ended_at), any status.
-- points = sum of casino_settlement + round_score for that member on
-- that night (corrections included, they are signed transactions).
-- Matches what room_memberships.season_score accumulates, so a member's
-- column sums to their season score.
--
-- Membership-guarded: non-members get zero rows. security definer,
-- stable, no writes. Idempotent (create or replace). Rollback:
--   drop function if exists public.get_season_grid(uuid, uuid);
begin;

create or replace function public.get_season_grid(
  p_room_id uuid,
  p_season_id uuid default null
)
returns table (
  session_id uuid,
  played_at timestamptz,
  member_id uuid,
  display_name text,
  points bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with season as (
    select s.started_at,
           coalesce(s.ended_at, now()) as ends_at
    from public.seasons s
    where s.room_id = p_room_id
      and (
        (p_season_id is null and s.status = 'active')
        or s.id = p_season_id
      )
    order by s.ordinal desc
    limit 1
  )
  select t.session_id,
         coalesce(e.played_at, min(t.created_at)) as played_at,
         t.member_id,
         coalesce(u.display_name, 'Member') as display_name,
         sum(t.amount_points)::bigint as points
  from season
  join public.transactions t
    on t.room_id = p_room_id
   and t.kind in ('casino_settlement', 'round_score')
   and t.session_id is not null
   and t.created_at >= season.started_at
   and t.created_at <= season.ends_at
  left join public.events e on e.id = t.session_id
  left join public.users u on u.id = t.member_id
  where exists (
    select 1 from public.room_memberships rm
    where rm.room_id = p_room_id
      and rm.user_id = public.current_user_id()
  )
  group by t.session_id, e.played_at, t.member_id, u.display_name
  order by 2, 3;
$$;

grant execute on function public.get_season_grid(uuid, uuid) to authenticated;

comment on function public.get_season_grid(uuid, uuid) is
  'v1.2 slice 2c: points per game night per member for one season (null = active season). casino_settlement + round_score, grouped by session_id (= events.id). Membership-guarded, read-only. Drives the Seasons dual trace and season grid.';

commit;
