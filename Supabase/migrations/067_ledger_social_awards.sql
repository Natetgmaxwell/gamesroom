-- 067: ledger-as-social-surface — four new awards + Tonight's Star.
--
-- Implements docs/vision/LEDGER_SOCIAL_SURFACE_SPEC.md (§6 Handoff to build).
-- Extends migration 048's `close_season` award computation from four
-- awards (Phoenix / Veteran / Whale / Drowning) to seven season-end
-- awards by adding Iron Mann, Comeback Kid, and Good Sport, and adds an
-- ephemeral `get_tonight_star` read RPC computed at the session-finalize
-- path (NOT season close) — no `season_awards` row, no persistence.
--
-- Award_type is the `public.season_award_type` enum (migration 039 /
-- 045). Three new enum values are added. All three new awards are public
-- (the enum has no privacy flag; the RLS read set in `get_season_awards`
-- treats every non-'drowning' value as public).
--
--   - Iron Mann:   longest run of consecutive attended sessions (min
--                  run 3). Attended = ≥1 casino_settlement transaction
--                  in the session (the same def as Veteran). A missed
--                  session (attendees exist but no transaction from
--                  this member) resets the run. Tie-break: total
--                  sessions attended, then member id. Not awarded if no
--                  member reached a 3-session run.
--   - Comeback Kid: member who went season-minimum net < 0 AND ended
--                  the season net > 0; winner = largest
--                  (season_end_net − season_minimum). Not awarded if no
--                  member qualifies.
--   - Good Sport:  among members with ≥3 losing sessions (session net
--                  < 0), the winner is the one with the highest median
--                  of those session nets (smallest typical loss).
--                  Tie-break: total sessions attended, then member id.
--                  Not awarded if no member has 3 losing sessions.
--                  Voice-only per the Good Sport principle — never a
--                  leaderboard position or a scored metric.
--
-- Reuses the `casino_settlement` session-delta CTE from migration 048
-- (per-(member, session) net inside the season window).
--
-- Also: `get_tonight_star(p_session_id)` — the member with the biggest
-- single-session net positive for one just-finalized session. The host
-- may override in the UI to point at a social moment instead.

-- =================================================================
-- 1. Extend the award_type enum with the three new season-end awards.
-- =================================================================
alter type public.season_award_type add value if not exists 'iron_mann';
alter type public.season_award_type add value if not exists 'comeback_kid';
alter type public.season_award_type add value if not exists 'good_sport';

-- =================================================================
-- 2. close_season — extend to compute all seven season-end awards.
-- =================================================================
create or replace function public.close_season(p_room_id uuid)
returns setof public.seasons
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_season_id uuid;
  v_ordinal int;
  v_started_at timestamptz;
  v_ended_at timestamptz;
  v_member_id uuid;
  v_display_name text;
  v_value bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can close a season' using errcode = '42501';
  end if;

  -- The active season, if any. A fresh room has none — create the
  -- first one so the close still computes awards over the room's
  -- full history.
  select id, ordinal, started_at into v_season_id, v_ordinal, v_started_at
  from public.seasons
  where room_id = p_room_id and status = 'active'
  order by ordinal desc
  limit 1;

  if v_season_id is null then
    insert into public.seasons (room_id, ordinal, subtitle, status, started_at)
    values (
      p_room_id,
      1,
      '',
      'active',
      coalesce(
        (select min(created_at) from public.transactions where room_id = p_room_id),
        now()
      )
    )
    returning id, ordinal, started_at into v_season_id, v_ordinal, v_started_at;
  end if;

  v_ended_at := now();

  -- Close the season.
  update public.seasons
    set status = 'ended', ended_at = v_ended_at
    where id = v_season_id;

  -- -----------------------------------------------------------------
  -- Award computation. The base `sd` CTE (per-(member, session) net of
  -- casino_settlement transactions inside the season window) is the
  -- session-delta shape reused from migration 048. Awards 5–7
  -- (Iron Mann, Comeback Kid, Good Sport) extend the four already
  -- computed here (Veteran, Whale, Phoenix, Drowning).
  -- -----------------------------------------------------------------

  -- Veteran: most sessions played.
  select sd.member_id, count(*)::bigint
    into v_member_id, v_value
  from (
    select t.member_id, t.session_id
    from public.transactions t
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
      and t.created_at >= v_started_at
      and t.created_at <= v_ended_at
    group by t.member_id, t.session_id
  ) sd
  group by sd.member_id
  order by count(*) desc, sd.member_id
  limit 1;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'veteran',
      'Played ' || v_value || ' session' || case when v_value = 1 then '' else 's' end || ' this season.'
    );
  end if;

  -- Whale: biggest single-session net positive.
  select sd.member_id, sd.delta
    into v_member_id, v_value
  from (
    select t.member_id, t.session_id, sum(t.amount_points)::bigint as delta
    from public.transactions t
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
      and t.created_at >= v_started_at
      and t.created_at <= v_ended_at
    group by t.member_id, t.session_id
  ) sd
  where sd.delta > 0
  order by sd.delta desc, sd.member_id
  limit 1;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'whale',
      'Biggest single-session net: +' || v_value || '.'
    );
  end if;

  -- Phoenix: most-improved — largest total positive movement.
  select sd.member_id, sum(sd.climb)
    into v_member_id, v_value
  from (
    select t.member_id, t.session_id,
           sum(case when t.amount_points > 0 then t.amount_points else 0 end)::bigint as climb
    from public.transactions t
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
      and t.created_at >= v_started_at
      and t.created_at <= v_ended_at
    group by t.member_id, t.session_id
  ) sd
  group by sd.member_id
  having sum(sd.climb) > 0
  order by sum(sd.climb) desc, sd.member_id
  limit 1;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'phoenix',
      'Climbed +' || v_value || ' across the season.'
    );
  end if;

  -- Drowning: most negative total movement. Only awarded when the
  -- member actually went negative.
  select sd.member_id, sum(sd.sink)
    into v_member_id, v_value
  from (
    select t.member_id, t.session_id,
           sum(case when t.amount_points < 0 then t.amount_points else 0 end)::bigint as sink
    from public.transactions t
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
      and t.created_at >= v_started_at
      and t.created_at <= v_ended_at
    group by t.member_id, t.session_id
  ) sd
  group by sd.member_id
  having sum(sd.sink) < 0
  order by sum(sd.sink) asc, sd.member_id
  limit 1;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'drowning',
      'Kept showing up. The ledger remembers.'
    );
  end if;

  -- ---------------------------------------------------------------
  -- 5. Iron Mann: longest run of consecutive attended sessions.
  --    Attended = ≥1 casino_settlement transaction in the session.
  --    Sessions are the distinct `session_id`s that have any
  --    casino_settlement transaction in the season window (i.e. a
  --    session that happened). A session with attendees but no
  --    transaction from this member resets the run. Minimum run 3.
  --    Tie-break: total sessions attended, then member id.
  -- ---------------------------------------------------------------
  select streak.member_id, streak.longest
    into v_member_id, v_value
  from (
    -- All sessions in the window, with their earliest transaction as
    -- the chronological anchor.
    with seasons_sessions as (
      select t.session_id, min(t.created_at) as session_at
      from public.transactions t
      where t.room_id = p_room_id
        and t.kind = 'casino_settlement'
        and t.session_id is not null
        and t.created_at >= v_started_at
        and t.created_at <= v_ended_at
      group by t.session_id
    ),
    -- Attendance per member per session.
    attendance as (
      select s.session_id, s.session_at, rm.user_id as member_id,
             bool_or(t.member_id is not null) as attended
      from seasons_sessions s
      cross join public.room_memberships rm
      left join public.transactions t
        on t.room_id = p_room_id
       and t.kind = 'casino_settlement'
       and t.session_id = s.session_id
       and t.member_id = rm.user_id
      where rm.room_id = p_room_id
      group by s.session_id, s.session_at, rm.user_id
    ),
    -- Consecutive-attendance islands (gaps-and-islands).
    with_runs as (
      select member_id, attended, session_at, session_id,
             row_number() over (partition by member_id order by session_at, session_id)
               - row_number() over (partition by member_id, attended order by session_at, session_id) as grp
      from attendance
    ),
    -- Longest attended run per member + total attended sessions.
    streaks as (
      select r.member_id,
             count(*) filter (where r.attended) as longest,
             (select count(*) from attendance a where a.member_id = r.member_id and a.attended) as total_sessions
      from with_runs r
      group by r.member_id, r.grp, r.attended
      having r.attended
    )
    select member_id, max(longest) as longest
    from streaks
    group by member_id, total_sessions
    having max(longest) >= 3
    order by max(longest) desc, total_sessions desc, member_id
    limit 1
  ) streak;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'iron_mann',
      'Attended ' || v_value || ' consecutive nights.'
    );
  end if;

  -- ---------------------------------------------------------------
  -- 6. Comeback Kid: went season-minimum net < 0 and ended the
  --    season net > 0. Winner = largest (season_end_net −
  --    season_minimum). Not awarded if no member qualifies.
  -- ---------------------------------------------------------------
  select cb.member_id, cb.recovery
    into v_member_id, v_value
  from (
    -- Per-(member, session) net, ordered chronologically.
    with sd as (
      select t.member_id, t.session_id,
             sum(t.amount_points)::bigint as delta,
             min(t.created_at) as session_at
      from public.transactions t
      where t.room_id = p_room_id
        and t.kind = 'casino_settlement'
        and t.session_id is not null
        and t.created_at >= v_started_at
        and t.created_at <= v_ended_at
      group by t.member_id, t.session_id
    ),
    -- Running cumulative net per member (the season arc).
    arc as (
      select member_id, session_at, delta,
             sum(delta) over (partition by member_id order by session_at, session_id) as cumulative
      from sd
    ),
    comeback as (
      select member_id,
             min(cumulative) as season_min,
             sum(delta) as season_end
      from arc
      group by member_id
    )
    select member_id, (season_end - season_min) as recovery
    from comeback
    where season_min < 0 and season_end > 0
    order by (season_end - season_min) desc, member_id
    limit 1
  ) cb;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'comeback_kid',
      'Climbed back ' || v_value || ' points from the season''s low.'
    );
  end if;

  -- ---------------------------------------------------------------
  -- 7. Good Sport: among members with ≥3 losing sessions (session net
  --    < 0), the winner is the one with the highest median of those
  --    session nets (the smallest typical loss). Tie-break: total
  --    sessions attended, then member id. Not awarded if no member
  --    has 3 losing sessions.
  --    Voice-only per the Good Sport principle — never a leaderboard
  --    position, never a scored metric.
  -- ---------------------------------------------------------------
  select gs.member_id
    into v_member_id
  from (
    with sd as (
      select t.member_id, t.session_id,
             sum(t.amount_points)::bigint as delta
      from public.transactions t
      where t.room_id = p_room_id
        and t.kind = 'casino_settlement'
        and t.session_id is not null
        and t.created_at >= v_started_at
        and t.created_at <= v_ended_at
      group by t.member_id, t.session_id
    ),
    losing as (
      select member_id, delta
      from sd
      where delta < 0
    ),
    medians as (
      select member_id,
             percentile_cont(0.5) within group (order by delta) as median_loss,
             count(*) as losing_sessions,
             (select count(*) from sd s2 where s2.member_id = l.member_id) as total_sessions
      from losing l
      group by member_id
      having count(*) >= 3
    )
    select member_id
    from medians
    order by median_loss desc, total_sessions desc, member_id
    limit 1
  ) gs;

  if v_member_id is not null then
    select coalesce(u.display_name, 'Member') into v_display_name
    from public.users u where u.id = v_member_id;
    insert into public.season_awards (
      season_id, room_id, recipient_user_id, recipient_display_name,
      member_id, award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, v_member_id, 'good_sport',
      'Lost well — kept every loss small.'
    );
  end if;

  -- Reset season scores for the next arc.
  update public.room_memberships
    set season_score = 0
    where room_id = p_room_id;

  -- Open the next season.
  insert into public.seasons (room_id, ordinal, subtitle, status)
  values (p_room_id, v_ordinal + 1, '', 'active');

  -- Emit the system event for the briefing banner.
  insert into public.room_system_events (room_id, kind, payload)
  values (
    p_room_id,
    'season_closed',
    jsonb_build_object('season_ordinal', v_ordinal)
  );

  return query select s.* from public.seasons s where s.id = v_season_id;
end;
$$;

grant execute on function public.close_season(uuid) to authenticated;

comment on function public.close_season(uuid) is
  'Host-only. Closes the room''s active season, computes the seven season awards (Veteran, Whale, Phoenix, Drowning, Iron Mann, Comeback Kid, Good Sport), resets season scores, opens the next season, emits a season_closed system event, and returns the closed season.';

-- =================================================================
-- 3. get_tonight_star — ephemeral, computed at the session-finalize
--    path, NOT at season close. No `season_awards` row, no
--    persistence beyond the ceremonial card. Returns the member with
--    the biggest single-session net positive for one session (the
--    same computation as Whale, but for this one session). The host
--    may override in the UI with one tap to point at a social moment.
--    Empty when the session has no net-positive member.
-- =================================================================
create or replace function public.get_tonight_star(p_session_id uuid)
returns table (
  member_id uuid,
  member_display_name text,
  net_positive bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select t.member_id,
         coalesce(u.display_name, 'Member'),
         sum(t.amount_points)::bigint as net
  from public.transactions t
  join public.users u on u.id = t.member_id
  where t.session_id = p_session_id
    and t.kind = 'casino_settlement'
    and exists (
      select 1 from public.events e
      join public.room_memberships rm on rm.room_id = e.room_id
      where e.id = p_session_id
        and rm.user_id = public.current_user_id()
    )
  group by t.member_id, u.display_name
  having sum(t.amount_points) > 0
  order by sum(t.amount_points) desc, t.member_id
  limit 1;
$$;

grant execute on function public.get_tonight_star(uuid) to authenticated;

comment on function public.get_tonight_star(uuid) is
  'Ephemeral read for the ceremonial card. Returns the member with the biggest single-session net positive for one session (Tonight''s Star), or an empty set when no member net positive. Host may override in the UI. No season_awards row is written.';
