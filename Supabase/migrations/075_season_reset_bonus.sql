-- 075: Season rollover resets every member to the room's starting bonus.
--
-- Product decision (2026-08-16): when a season closes, each member's
-- points_balance returns to join_starting_bonus — a true fresh start,
-- winnings do not carry into the new season. This mirrors the join
-- bonus (018) so the starting grant applies at both entry points:
--   * joining a room (redeem_join_code, 018)
--   * a new season kicking off (close_season, this migration)
--
-- Implementation: replaces close_season (048) so the reset block
--   * reads the bonus from rooms.join_starting_bonus (not hardcoded,
--     so a host who changes the bonus gets consistent behavior)
--   * writes a `season_reset` ledger row per member capturing the
--     delta (bonus − balance) BEFORE the balance update, so the delta
--     computes from the pre-reset balance (074 §5b pattern)
--   * skips zero-delta members (no noise rows)
--   * resets both points_balance AND season_score
--
-- The ledger rows use session_id = null, matching 074's null-session
-- rows, so they are excluded from get_season_history (which requires
-- session_id is not null) and don't pollute the season trajectory.

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
  -- the leaderboard trajectory's definition (migration 031).
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
      award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, 'veteran',
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
      award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, 'whale',
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
      award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, 'phoenix',
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
      award_type, caption
    ) values (
      v_season_id, p_room_id, v_member_id, v_display_name, 'drowning',
      'Kept showing up. The ledger remembers.'
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
  'Host-only. Closes the room''s active season, computes the four season awards, resets every member''s points_balance to the room''s join_starting_bonus and season_score to 0 (true fresh start), opens the next season, emits a season_closed system event, and returns the closed season.';
