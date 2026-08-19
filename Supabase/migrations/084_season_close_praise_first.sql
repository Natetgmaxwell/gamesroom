-- 084: Season-close captions rewritten to Carnegie praise-first.
--
-- Product decision (2026-08-19): per CARNEGIE_CHAMPIONS_SPEC §C4 (Season
-- Close Voice), every public season-close caption must follow the
-- praise-first pattern — name the specific behaviour, praise it
-- sincerely (earned by the act, so it can't be flattery), and keep it
-- about the behaviour, never a blanket "you're great." The old captions
-- ("Played N session(s) this season.", "Biggest single-session net: +N.")
-- were informational stat-readouts, not praise.
--
-- This migration:
--   * Restores the three awards 075 dropped (iron_mann, comeback_kid,
--     good_sport). 075 silently regressed the function to the 048 four-
--     award set; the full seven-award set was originally introduced by
--     067 and is restored verbatim here (same gaps-and-islands streak
--     CTE, same cumulative-arc recovery CTE, same percentile_cont(0.5)
--     median CTE).
--   * Adds the `member_id` column to all seven season_awards INSERTs
--     (067 added it for the original seven; 075 also dropped it from
--     the four it kept). All seven awards now write the same column
--     shape.
--   * Replaces the captions of the four original awards (veteran,
--     whale, phoenix) and the three restored awards (iron_mann,
--     comeback_kid, good_sport) with praise-first forms. The
--     `drowning` caption is PRIVATE and stays verbatim — praise-first
--     is for public, behaviour-praising voice only; the private loss
--     acknowledgement reads as-is.
--
-- Implementation: replaces close_season (075) so the reset block
--   * reads the bonus from rooms.join_starting_bonus (unchanged)
--   * writes a `season_reset` ledger row per member (unchanged)
--   * skips zero-delta members (unchanged)
--   * resets both points_balance AND season_score (unchanged)
--   * opens the next season and emits the season_closed system event
--     (unchanged)

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
  v_bonus integer;
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
  -- Award computation. Session deltas = per-(member, session) net of
  -- casino_settlement transactions inside the season window, matching
  -- the leaderboard trajectory's definition (migration 031). Awards
  -- 5–7 (Iron Mann, Comeback Kid, Good Sport) are restored verbatim
  -- from migration 067 — 075 dropped them.
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
      'Showed up ' || v_value || ' time' || (case when v_value = 1 then '' else 's' end) || ' this season — the player the table could always count on. That reliability is its own kind of win.'
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
      'One night, +' || v_value || ' — the biggest single score the room has seen. That kind of night doesn''t happen by accident.'
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
      'Climbed ' || v_value || ' points from the bottom of the table — kept showing up, kept playing it out. The biggest climb in the room.'
    );
  end if;

  -- Drowning: most negative total movement. Only awarded when the
  -- member actually went negative. PRIVATE award — caption stays
  -- verbatim, NOT praise-first.
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
  --    (Restored from migration 067; 075 dropped this award.)
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
      'Came ' || v_value || ' nights in a row — never missed, never late. The streak that held the season together.'
    );
  end if;

  -- ---------------------------------------------------------------
  -- 6. Comeback Kid: went season-minimum net < 0 and ended the
  --    season net > 0. Winner = largest (season_end_net −
  --    season_minimum). Not awarded if no member qualifies.
  --    (Restored from migration 067; 075 dropped this award.)
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
      'Went ' || v_value || ' points down and climbed all the way back into the black. That''s not luck — that''s showing up and playing it out.'
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
  --    (Restored from migration 067; 075 dropped this award.)
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
      'Lost night after night and never once tilted — kept every loss small and the table laughing. The player who makes a table worth sitting at.'
    );
  end if;

  -- Reset season scores and points for the next arc. Every member
  -- returns to the room's join_starting_bonus — a true fresh start,
  -- winnings do not carry. A `season_reset` ledger row per member
  -- captures the delta (bonus − balance) so the reset is auditable;
  -- zero-delta members get no row. Written BEFORE the balance update
  -- so the delta computes from the pre-reset balance (074 §5b).
  select r.join_starting_bonus into v_bonus
  from public.rooms r
  where r.id = p_room_id;

  insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
  select m.room_id, null::uuid, m.user_id, 'season_reset', v_bonus - m.points_balance,
         jsonb_build_object('reason', 'season reset: balance returned to starting bonus'),
         m.user_id
  from public.room_memberships m
  where m.room_id = p_room_id
    and m.points_balance <> v_bonus;

  update public.room_memberships
    set points_balance = v_bonus,
        season_score = 0
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
  'Host-only. Closes the room''s active season, computes the seven season awards (Veteran, Whale, Phoenix, Drowning, Iron Mann, Comeback Kid, Good Sport) with Carnegie praise-first captions per CARNEGIE_CHAMPIONS_SPEC §C4, resets every member''s points_balance to the room''s join_starting_bonus and season_score to 0 (true fresh start), opens the next season, emits a season_closed system event, and returns the closed season. Restores the iron_mann / comeback_kid / good_sport awards that 075 silently dropped.';