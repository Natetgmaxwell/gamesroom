-- 053: W-05 — previous-seasons comparison (US-10).
--
-- Closes the US-10 "improving over time" gap. Two design notes
-- inform the shape:
--
--   1. MEMBERSHIP-GUARDED. The outer query returns rows ONLY when
--      the caller is a member of the room (exists subquery on
--      room_memberships). Same pattern as migration 048's
--      `get_current_season` — non-members cannot sniff a room's
--      season history via the RPC. The guard sits in the outer
--      SELECT so a non-member gets zero rows, not a permission
--      error.
--
--   2. REUSES THE MIGRATION-031 casino_settlement aggregation. The
--      caller's per-season total is the same shape as the
--      leaderboard trajectory: sum of `casino_settlement`
--      transactions grouped per (member, session) inside the season
--      window (t.created_at between started_at and ended_at),
--      then summed per member. Members with no transactions inside
--      the window total 0 (the outer coalesce). Ranks use
--      `row_number()` so ties are broken deterministically by
--      user_id (the same tie-breaker the leaderboard uses).
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/053_season_history.sql

-- =================================================================
-- get_season_history
-- =================================================================
-- One row per ended season for the room, with the calling
-- member's net + rank in that season. Most recent season first
-- (ORDER BY ordinal DESC). Stable, security definer, and the
-- search_path is pinned to `public` per the V0.8 convention.
create or replace function public.get_season_history(p_room_id uuid)
returns table (
  season_id uuid,
  ordinal int,
  subtitle text,
  started_at timestamptz,
  ended_at timestamptz,
  caller_total bigint,
  caller_rank bigint
)
language sql
stable
security definer
set search_path = public
as $$
  with season_totals as (
    select
      s.id as season_id,
      s.ordinal,
      s.subtitle,
      s.started_at,
      s.ended_at,
      m.user_id,
      coalesce(sum(t.amount_points), 0)::bigint as total
    from public.seasons s
    join public.room_memberships m on m.room_id = s.room_id
    left join public.transactions t
      on t.room_id = s.room_id
     and t.member_id = m.user_id
     and t.kind = 'casino_settlement'
     and t.session_id is not null
     and t.created_at >= s.started_at
     and t.created_at <= s.ended_at
    where s.room_id = p_room_id
      and s.status = 'ended'
    group by s.id, s.ordinal, s.subtitle, s.started_at, s.ended_at, m.user_id
  ),
  ranked as (
    select st.*,
           row_number() over (
             partition by st.season_id
             order by st.total desc, st.user_id
           ) as rn
    from season_totals st
  )
  select r.season_id,
         r.ordinal,
         r.subtitle,
         r.started_at,
         r.ended_at,
         r.total as caller_total,
         r.rn as caller_rank
  from ranked r
  where r.user_id = public.current_user_id()
    and exists (
      select 1 from public.room_memberships rm
      where rm.room_id = p_room_id
        and rm.user_id = public.current_user_id()
    )
  order by r.ordinal desc;
$$;

grant execute on function public.get_season_history(uuid) to authenticated;

comment on function public.get_season_history(uuid) is
  'Returns the room''s ended seasons with the caller''s net total + rank, most recent first. Membership-guarded (non-members see zero rows). Reuses the migration-031 casino_settlement session-delta aggregation. Empty for rooms with no ended seasons or when the caller is not a member.';
