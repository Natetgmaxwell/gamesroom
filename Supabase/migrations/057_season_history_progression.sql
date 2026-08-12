-- 057: V0.35 — season history card v2. Adds per-event cumulative
-- progression to get_season_history (migration 053) so the client can
-- render the caller's intra-season arc ("doing better in round X than
-- last season at this point").
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/057_season_history_progression.sql

create or replace function public.get_season_history(p_room_id uuid)
returns table (
  season_id uuid,
  ordinal int,
  subtitle text,
  started_at timestamptz,
  ended_at timestamptz,
  caller_total bigint,
  caller_rank bigint,
  score_progression jsonb
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
  ),
  progression as (
    select
      s.id as season_id,
      coalesce(
        jsonb_agg(
          jsonb_build_object('at', pt.point_at, 'total', pt.cumulative)
          order by pt.point_at
        ),
        '[]'::jsonb
      ) as score_progression
    from public.seasons s
    join public.room_memberships m
      on m.room_id = s.room_id
     and m.user_id = public.current_user_id()
    left join lateral (
      select
        coalesce(e.played_at, t.created_at) as point_at,
        sum(t.amount_points) over (
          order by coalesce(e.played_at, t.created_at)
        ) as cumulative
      from public.transactions t
      left join public.events e on e.id = t.session_id
      where t.room_id = s.room_id
        and t.member_id = m.user_id
        and t.kind = 'casino_settlement'
        and t.session_id is not null
        and t.created_at >= s.started_at
        and t.created_at <= s.ended_at
    ) pt on true
    where s.room_id = p_room_id
      and s.status = 'ended'
    group by s.id
  )
  select r.season_id,
         r.ordinal,
         r.subtitle,
         r.started_at,
         r.ended_at,
         r.total as caller_total,
         r.rn as caller_rank,
         p.score_progression
  from ranked r
  left join progression p on p.season_id = r.season_id
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
  'Returns the room''s ended seasons with the caller''s net total + rank, most recent first, plus score_progression (per-session cumulative totals for the caller). Membership-guarded (non-members see zero rows). Reuses the migration-031 casino_settlement aggregation. Empty for rooms with no ended seasons or when the caller is not a member.';
