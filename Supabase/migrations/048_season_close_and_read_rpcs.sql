-- 048: F-MVP-03 — season close RPC + missing season read RPCs (W1.5).
--
-- Closes the W1.5 gap found during implementation:
--   1. The Swift layer references `get_current_season(p_room_id)` and
--      `get_season_awards(p_season_id)` (RoomStore.swift) but NO
--      migration defines them — the season read path is dead in
--      production (only the in-memory store seeds seasons).
--   2. No `close_season` RPC exists, so the host "Declare season end"
--      CTA cannot exist.
--
-- Adds:
--   1. get_current_season(p_room_id) — the room's active-or-most-
--      recently-ended season, preferring `ended` so the `.seasonClose`
--      awards surface renders. Membership-guarded (no cross-room leak).
--   2. get_season_awards(p_season_id) — the season's awards with the
--      migration-045 drowning read set (recipient, host, opted-in
--      members). Membership-guarded.
--   3. close_season(p_room_id) — host-only. Closes the active season
--      (creating the first one if the room never opened a season),
--      computes the four awards (Phoenix / Veteran / Whale / Drowning)
--      from casino_settlement session deltas in the season window,
--      resets season scores, opens the next season, emits a
--      `season_closed` system event, and returns the closed season.

-- =================================================================
-- 1. get_current_season
-- =================================================================
create or replace function public.get_current_season(p_room_id uuid)
returns public.seasons
language sql
stable
security definer
set search_path = public
as $$
  select s.*
  from public.seasons s
  where s.room_id = p_room_id
    and exists (
      select 1 from public.room_memberships rm
      where rm.room_id = p_room_id
        and rm.user_id = public.current_user_id()
    )
  order by case when s.status = 'ended' then 0 else 1 end,
           s.ordinal desc
  limit 1;
$$;

grant execute on function public.get_current_season(uuid) to authenticated;

comment on function public.get_current_season(uuid) is
  'Returns the room''s active-or-most-recently-ended season, preferring ended so the awards surface renders after a Declare. Empty for non-members.';

-- =================================================================
-- 2. get_season_awards
-- =================================================================
create or replace function public.get_season_awards(p_season_id uuid)
returns table (
  id uuid,
  season_id uuid,
  room_id uuid,
  recipient_user_id uuid,
  recipient_display_name text,
  award_type text,
  caption text,
  acknowledged boolean,
  awarded_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select sa.id, sa.season_id, sa.room_id, sa.recipient_user_id,
         sa.recipient_display_name, sa.award_type, sa.caption,
         sa.acknowledged, sa.awarded_at
  from public.season_awards sa
  where sa.season_id = p_season_id
    and exists (
      select 1 from public.room_memberships rm
      where rm.room_id = sa.room_id
        and rm.user_id = public.current_user_id()
    )
    and (
      sa.award_type <> 'drowning'
      or sa.recipient_user_id = public.current_user_id()
      or exists (
        select 1 from public.rooms r
        where r.id = sa.room_id
          and r.created_by = public.current_user_id()
      )
      or exists (
        select 1 from public.room_memberships rm
        where rm.room_id = sa.room_id
          and rm.user_id = public.current_user_id()
          and rm.member_drowning_opt_in = true
      )
    );
$$;

grant execute on function public.get_season_awards(uuid) to authenticated;

comment on function public.get_season_awards(uuid) is
  'Returns the season''s awards. Drowning rows are readable only by the recipient, the room host, or opted-in members (migration 045 read set). Empty for non-members.';

-- =================================================================
-- 3. close_season
-- =================================================================
create or replace function public.close_season(p_room_id uuid)
returns public.seasons
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
  'Host-only. Closes the room''s active season, computes the four season awards, resets season scores, opens the next season, emits a season_closed system event, and returns the closed season.';
