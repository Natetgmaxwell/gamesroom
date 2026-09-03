-- 095: V0.98 fold-in — host authorization migrated from created_by to role-based
-- across every host-gated RPC (the update_room_packs bug class).
--
-- Background:
--   2026-09-03: pack toggles in Operations silently failed for Nathan
--   (role-host in Felt Faction, not created_by). Root cause: migration 041/089's
--   `update_room_packs` (and 30+ sibling RPCs) authorize with
--   `rooms.created_by = v_caller` — the pre-multi-host guard. V0.91 introduced
--   role-based multi-host, but only transfer_host_role (094) and remove_room_member
--   (093) were migrated to role checks. Every other host RPC still locks out every
--   host except the room creator.
--
--   Bug-class history: leave_room (fixed in 093 D7), transfer_host_role (re-homed
--   in 094), now the rest.
--
-- Semantics:
--   A canonical SECURITY DEFINER helper `is_room_host(p_room_id, p_user)` replaces
--   each inline guard: TRUE iff the user has an active host membership row.
--   1. A promoted host can do everything the creator could (V0.91's contract).
--   2. Kicked members confer nothing (membership_status = 'active' required).
--   3. created_by alone confers nothing — a creator who was demoted or kicked is
--      subject to the same rules as everyone. (No live room has a non-host creator
--      today: verified `created_by` users all hold active host rows.)
--
-- Scope — ONLY functions whose guard exists to authorize HOST powers:
--   packs:      update_room_packs, add_pack_to_room, remove_pack_from_room,
--               set_room_pack_config
--   room:       update_room (all overloads), update_room_settings (all overloads),
--               delete_room
--   events:     create_event, add_event, add_event_with_packs, delete_event,
--               update_event_played_at
--   scores:     record_score, record_round_score, delete_round_score,
--               set_tonight_star_pick
--   season:     close_season, set_season_subtitle
--   host tools: update_host_journal, mark_member_notes_consumed,
--               list_arrival_candidates, get_season_awards
--   deposits:   forfeit_seat_deposit, waive_seat_deposit, claim_seat_waived
--   casino:     upsert_casino_config (all overloads), withdraw_casino_chips,
--               mark_withdrawal_dispensed, open_casino_attestation_window,
--               finalize_casino_session
--   joins:      approve_tier_two_join
--
-- Deliberately NOT touched (member-scoped or semantic):
--   get_unconsumed_member_notes (creator OR host visibility guard — read path,
--     member-benign; left as-is this slice),
--   remove_room_member / transfer_host_role / leave_room / redeem_join_code
--     (already role-based via 091/093/094),
--   member self-service RPCs (upsert_event_rsvp etc. — their created_by
--     appearances, where any, are joins to resolve the room, not guards).
--
-- Mechanics:
--   Each target function is regenerated from the LIVE pg_proc definition with the
--   guard expression swapped. This file documents + applies the canonical helper;
--   the per-function regeneration is generated programmatically (see
--   scripts/make_095_guards.py) because 40+ function bodies cannot be hand-maintained.

-- =================================================================
-- 1. Canonical host check helper
-- =================================================================
create or replace function public.is_room_host(
  p_room_id uuid,
  p_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = p_user_id
      and role = 'host'
      and membership_status = 'active'
  );
$$;

revoke all on function public.is_room_host(uuid, uuid) from public;
grant execute on function public.is_room_host(uuid, uuid) to authenticated;

comment on function public.is_room_host(uuid, uuid) is
  'V0.98 — canonical host authorization: active host-role membership. Replaces the pre-multi-host rooms.created_by guard across host RPCs (migration 095).';

-- ==== END PART 1 (helper) ==== do not regenerate above this line
-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- add_event(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slug text, p_hidden_from_user_ids uuid[] DEFAULT '{}'::uuid[])
-- =================================================================
create or replace function public.add_event(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slug text, p_hidden_from_user_ids uuid[] DEFAULT '{}'::uuid[])
returns uuid
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_event_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can create events' using errcode = '42501';
  end if;
  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;
  if not exists (select 1 from public.packs where slug = p_pack_slug) then
    raise exception 'Unknown pack' using errcode = 'P0002';
  end if;
  insert into public.events (room_id, name, played_at, created_by, pack_slug, hidden_from_user_ids)
  values (p_room_id, p_name, p_played_at, v_caller, p_pack_slug, coalesce(p_hidden_from_user_ids, '{}'::uuid[]))
  returning id into v_event_id;
  return v_event_id;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- add_event_with_packs(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slugs text[])
-- =================================================================
create or replace function public.add_event_with_packs(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slugs text[])
returns uuid
language plpgsql
volatile
security definer
as $body$
declare
  v_event_id uuid;
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms
                 where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can create events' using errcode = '42501';
  end if;
  if p_pack_slugs is null or array_length(p_pack_slugs, 1) = 0 then
    raise exception 'At least one pack required' using errcode = '22023';
  end if;
  -- Validate every slug exists.
  if exists (
    select 1 from unnest(p_pack_slugs) as s(slug)
    where not exists (select 1 from public.packs where slug = s.slug)
  ) then
    raise exception 'Unknown pack in p_pack_slugs' using errcode = 'P0002';
  end if;

  -- Insert event. Set pack_slug to the first pack for legacy
  -- single-pack reads (kept until v0.10 cleanup).
  insert into public.events (room_id, name, played_at, pack_slug, created_by)
  values (p_room_id, p_name, p_played_at, p_pack_slugs[1], v_caller)
  returning id into v_event_id;

  -- Insert junction rows.
  insert into public.event_packs (event_id, pack_slug)
  select v_event_id, unnest(p_pack_slugs);

  return v_event_id;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- add_pack_to_room(p_room_id uuid, p_pack_slug text)
-- =================================================================
create or replace function public.add_pack_to_room(p_room_id uuid, p_pack_slug text)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can add packs' using errcode = '42501';
  end if;
  if not exists (select 1 from public.packs where slug = p_pack_slug) then
    raise exception 'Unknown pack' using errcode = 'P0002';
  end if;
  insert into public.room_packs (room_id, pack_slug, added_by)
  values (p_room_id, p_pack_slug, v_caller)
  on conflict do nothing;
  return true;
end;
$body$;


-- =================================================================
-- approve_tier_two_join(p_room_id uuid, p_user_id uuid, p_remove boolean)
-- =================================================================
create or replace function public.approve_tier_two_join(p_room_id uuid, p_user_id uuid, p_remove boolean)
returns void
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Host-only: the caller must be the room's host.
  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can approve tier-2 joins' using errcode = '42501';
  end if;

  if p_remove then
    delete from public.room_memberships
    where room_id = p_room_id
      and user_id = p_user_id
      and invite_tier = 2;
  end if;
end;
$body$;


-- =================================================================
-- claim_seat_waived(p_event_id uuid, p_member_id uuid)
-- =================================================================
create or replace function public.claim_seat_waived(p_event_id uuid, p_member_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller));

  if v_room_id is null then
    raise exception 'Only the host can waive a seat deposit at claim' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.seat_deposits
    where event_id = p_event_id and user_id = p_member_id
  ) then
    return true;
  end if;

  insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
    values (p_event_id, v_room_id, p_member_id, 0, 'held');

  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, p_member_id, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, p_member_id, 'seat_deposit_waive', 0,
    jsonb_build_object('at_claim', true),
    v_caller
  );

  return true;
end;
$body$;


-- =================================================================
-- close_season(p_room_id uuid)
-- =================================================================
create or replace function public.close_season(p_room_id uuid)
returns SETOF seasons
language plpgsql
volatile
security definer
set search_path=public
as $body$
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
    where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
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
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- create_event(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slugs text[], p_hidden_from_user_ids uuid[] DEFAULT '{}'::uuid[])
-- =================================================================
create or replace function public.create_event(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slugs text[], p_hidden_from_user_ids uuid[] DEFAULT '{}'::uuid[])
returns uuid
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
    v_event_id uuid;
    v_caller uuid := public.current_user_id();
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.rooms
        where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
    ) then
        raise exception 'Only the host can create events' using errcode = '42501';
    end if;
    if p_pack_slugs is null or array_length(p_pack_slugs, 1) = 0 then
        raise exception 'At least one pack required' using errcode = '22023';
    end if;
    if exists (
        select 1 from unnest(p_pack_slugs) as s(slug)
        where not exists (select 1 from public.packs where slug = s.slug)
    ) then
        raise exception 'Unknown pack in p_pack_slugs' using errcode = 'P0002';
    end if;

    insert into public.events (room_id, name, played_at, pack_slug, created_by)
    values (p_room_id, p_name, p_played_at, p_pack_slugs[1], v_caller)
    returning id into v_event_id;

    insert into public.event_packs (event_id, pack_slug)
    select v_event_id, unnest(p_pack_slugs);

    -- V0.94 hidden members ride along unchanged.
    update public.events
    set hidden_from_user_ids = p_hidden_from_user_ids
    where id = v_event_id;

    return v_event_id;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- delete_event(p_event_id uuid)
-- =================================================================
create or replace function public.delete_event(p_event_id uuid)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can delete events' using errcode = '42501';
  end if;

  delete from public.event_packs where event_id = p_event_id;
  delete from public.events where id = p_event_id;

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- delete_room(p_room_id uuid)
-- =================================================================
create or replace function public.delete_room(p_room_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller)) and deleted_at is null
  ) then
    raise exception 'Only the host can delete a room' using errcode = '42501';
  end if;

  -- Soft delete: the ledger (transactions, seat_deposits, awards) survives
  -- for disputes. Do NOT hard-delete.
  update public.rooms set deleted_at = now() where id = p_room_id;

  -- Expire every open join code for the room.
  delete from public.join_codes where room_id = p_room_id;

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- delete_round_score(p_room_id uuid, p_event_id uuid, p_round_index integer)
-- =================================================================
create or replace function public.delete_round_score(p_room_id uuid, p_event_id uuid, p_round_index integer)
returns void
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_old_entries jsonb;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can delete a round' using errcode = '42501';
  end if;

  -- Idempotent: no row for the round → return without error.
  select rs.entries into v_old_entries
  from public.round_submissions rs
  where rs.room_id = p_room_id
    and rs.event_id = p_event_id
    and rs.round_index = p_round_index;

  if v_old_entries is null then
    return;
  end if;

  for v_entry in select * from jsonb_array_elements(v_old_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;

    update public.room_memberships
      set season_score = season_score - v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  delete from public.round_submissions
    where room_id = p_room_id
      and event_id = p_event_id
      and round_index = p_round_index;
end;
$body$;


-- =================================================================
-- finalize_casino_session(p_session_id uuid)
-- =================================================================
create or replace function public.finalize_casino_session(p_session_id uuid)
returns integer
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_forfeited integer := 0;
  v_entitlement bigint;
  v_member uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
    from public.events e where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.rooms r
                 where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))) then
    raise exception 'Only the room host can finalize the session' using errcode = '42501';
  end if;

  -- Non-scanners: forfeit their open entitlement (they walked with
  -- the chips and never settled). One did_not_scan row per member;
  -- balance + score absorb the loss.
  for v_member, v_entitlement in
    select cw.member_id, sum(cw.points_withdrawn)::bigint
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id
    group by cw.member_id
    having not exists (
      select 1 from public.casino_scans cs
      where cs.session_id = p_session_id
        and cs.member_id = cw.member_id
    )
  loop
    insert into public.casino_scans (
      session_id, room_id, member_id,
      vision_amount_points, vision_snapshot,
      detection_source, confidence_avg,
      did_not_scan, recorded_at, finalized_at
    )
    values (
      p_session_id, v_room_id, v_member,
      0, '{"source":"did_not_scan"}'::jsonb,
      'did_not_scan', 0.0,
      true, now(), now()
    );

    if v_entitlement > 0 then
      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      )
      values (
        v_room_id, p_session_id, v_member, 'casino_settlement', -v_entitlement,
        jsonb_build_object('source', 'did_not_scan', 'forfeited', v_entitlement),
        v_caller
      );

      update public.room_memberships
        set points_balance = points_balance - v_entitlement,
            season_score   = season_score   - v_entitlement
        where user_id = v_member and room_id = v_room_id;
    end if;

    v_forfeited := v_forfeited + 1;
  end loop;

  -- Stamp every scan row in this session.
  update public.casino_scans
    set finalized_at = coalesce(finalized_at, now())
    where session_id = p_session_id;

  return v_forfeited;
end;
$body$;


-- =================================================================
-- forfeit_seat_deposit(p_event_id uuid, p_member_id uuid)
-- =================================================================
create or replace function public.forfeit_seat_deposit(p_event_id uuid, p_member_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can forfeit a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'forfeited', forfeited_at = now(), forfeited_by = v_caller, settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_forfeit', v_deposit.amount,
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$body$;


-- =================================================================
-- get_season_awards(p_season_id uuid)
-- =================================================================
create or replace function public.get_season_awards(p_season_id uuid)
returns TABLE(id uuid, season_id uuid, room_id uuid, recipient_user_id uuid, recipient_display_name text, award_type text, caption text, acknowledged boolean, awarded_at timestamp with time zone)
language sql
stable
security definer
set search_path=public
as $body$
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
$body$;


-- =================================================================
-- list_arrival_candidates(p_event_id uuid)
-- =================================================================
create or replace function public.list_arrival_candidates(p_event_id uuid)
returns TABLE(user_id uuid, display_name text, deposit_amount integer, status text, within_grace boolean)
language sql
stable
security definer
set search_path=public
as $body$
  with event_row as (
    select e.id, e.room_id, e.played_at, r.created_by,
           r.seat_deposit_grace_minutes
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.id = p_event_id
  ),
  unresolved as (
    select sd.user_id, sd.amount, sd.status::text as status
    from public.seat_deposits sd
    where sd.event_id = p_event_id
      and sd.status = 'held'
      and not exists (
        select 1 from public.transactions t
        where t.session_id = p_event_id
          and t.member_id = sd.user_id
          and t.kind not in (
            'seat_deposit', 'seat_deposit_return',
            'seat_deposit_forfeit', 'seat_deposit_waive',
            'no_show_tax', 'no_show_tax_waiver'
          )
      )
  )
  select
    u.id as user_id,
    coalesce(u.display_name, 'Member') as display_name,
    un.amount as deposit_amount,
    un.status,
    (now() < event_row.played_at + make_interval(mins => event_row.seat_deposit_grace_minutes)) as within_grace
  from unresolved un
  cross join event_row
  join public.users u on u.id = un.user_id
  where event_row.created_by = public.current_user_id();
$body$;


-- =================================================================
-- mark_member_notes_consumed(p_room_id uuid, p_note_ids uuid[])
-- =================================================================
create or replace function public.mark_member_notes_consumed(p_room_id uuid, p_note_ids uuid[])
returns integer
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_count integer;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can mark notes consumed' using errcode = '42501';
  end if;

  update public.room_member_notes n
    set consumed_by_host_at = now()
  where n.room_id = p_room_id
    and n.id = any(p_note_ids)
    and n.consumed_by_host_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$body$;


-- =================================================================
-- mark_withdrawal_dispensed(p_transaction_id uuid)
-- =================================================================
create or replace function public.mark_withdrawal_dispensed(p_transaction_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
    v_caller uuid := public.current_user_id();
    v_event_id uuid;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    select t.session_id into v_event_id
    from public.transactions t
    where t.id = p_transaction_id
      and t.kind = 'casino_withdrawal';

    if v_event_id is null then
        raise exception 'Withdrawal not found' using errcode = '42501';
    end if;

    if not exists (
        select 1
        from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = v_event_id
          and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
    ) then
        raise exception 'Only the host can mark chips dispensed' using errcode = '42501';
    end if;

    update public.transactions as t
    set meta = coalesce(t.meta, '{}'::jsonb)
             || jsonb_build_object('dispensed', true, 'dispensed_at', now())
    where t.id = p_transaction_id;
end;
$body$;


-- =================================================================
-- open_casino_attestation_window(p_session_id uuid)
-- =================================================================
create or replace function public.open_casino_attestation_window(p_session_id uuid)
returns integer
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_inserted integer := 0;
  v_member_id uuid;
  v_amount bigint;
  v_source text;
  v_conf double precision;
  v_existing integer;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
    from public.events e where e.id = p_session_id;

  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.rooms r
                 where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))) then
    raise exception 'Only the room host can open the attestation window' using errcode = '42501';
  end if;

  -- Idempotent: if attestations already exist for this session, return
  -- the count and don't double-insert.
  select count(*) into v_existing
    from public.settlement_attestations
    where session_id = p_session_id;
  if v_existing > 0 then
    return v_existing;
  end if;

  -- For each member who withdrew chips in this session, create an
  -- attestation row seeded with the transaction amount (which is the
  -- net delta: chip_value - withdrawn). Vision source + confidence
  -- are read from the latest transaction's meta.vision_snapshot.
  for v_member_id in
    select distinct member_id
    from public.casino_withdrawals
    where session_id = p_session_id
  loop
    -- Find the settlement transaction for this member in this session.
    -- The transaction's amount_points IS the net delta (per V0.28).
    select amount_points, meta->'vision_snapshot'->>'source',
           (meta->'vision_snapshot'->>'confidence_avg')::double precision
      into v_amount, v_source, v_conf
      from public.transactions
      where session_id = p_session_id
        and member_id = v_member_id
        and kind = 'casino_settlement'
      limit 1;

    -- If no settlement transaction exists for this member, skip. This
    -- happens if the host settled some but not all members.
    if v_amount is null then
      continue;
    end if;

    insert into public.settlement_attestations (
      session_id, room_id, member_id,
      vision_amount_points, detection_source, confidence_avg
    )
    values (
      p_session_id, v_room_id, v_member_id,
      v_amount, coalesce(v_source, 'on_device'), v_conf
    );
    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- record_round_score(p_room_id uuid, p_event_id uuid, p_pack_slug text, p_round_index integer, p_entries jsonb DEFAULT '[]'::jsonb, p_correction_of uuid DEFAULT NULL::uuid)
-- =================================================================
create or replace function public.record_round_score(p_room_id uuid, p_event_id uuid, p_pack_slug text, p_round_index integer, p_entries jsonb DEFAULT '[]'::jsonb, p_correction_of uuid DEFAULT NULL::uuid)
returns TABLE(id uuid, room_id uuid, event_id uuid, round_index integer, pack_slug text, created_at timestamp with time zone, correction_of uuid)
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_submission_id uuid;
  v_old_entries jsonb;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
  v_meta jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can record a round' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.events
    where id = p_event_id and room_id = p_room_id
  ) then
    raise exception 'Event does not belong to room' using errcode = 'P0002';
  end if;

  -- Capture the existing entries BEFORE the upsert replaces the row.
  -- Null for a fresh round; the reverse loop is a no-op in that case.
  select rs.entries into v_old_entries
  from public.round_submissions rs
  where rs.room_id = p_room_id
    and rs.event_id = p_event_id
    and rs.round_index = p_round_index;

  insert into public.round_submissions (
    room_id, event_id, pack_slug, round_index, entries, created_by, correction_of
  ) values (
    p_room_id, p_event_id, p_pack_slug, p_round_index, p_entries, v_caller, p_correction_of
  )
  on conflict (room_id, event_id, round_index) do update
    set entries = excluded.entries,
        pack_slug = excluded.pack_slug,
        created_by = excluded.created_by,
        correction_of = excluded.correction_of,
        created_at = now()
  returning id into v_submission_id;

  -- Reverse the old deltas first so the new deltas land on a clean
  -- season_score. Reverse + delete ordering matches migration 035's
  -- "delete then apply" flow inverted: here we replace, so we must
  -- subtract before we add.
  for v_entry in select * from jsonb_array_elements(coalesce(v_old_entries, '[]'::jsonb))
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;

    update public.room_memberships
      set season_score = season_score - v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;
    v_meta := coalesce(v_entry->'meta', '{}'::jsonb) || jsonb_build_object(
      'submission_id', v_submission_id,
      'round_index', p_round_index,
      'pack_slug', p_pack_slug,
      'correction_of', p_correction_of
    );

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      p_room_id, p_event_id, v_member_id, 'round_score', v_points_delta, v_meta, v_caller
    );

    update public.room_memberships
      set season_score = season_score + v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  return query
    select v_submission_id, p_room_id, p_event_id, p_round_index,
           p_pack_slug, now(), p_correction_of;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- record_score(p_event_id uuid, p_user_id uuid, p_score integer, p_withdrawn integer DEFAULT 0, p_returned integer DEFAULT 0)
-- =================================================================
create or replace function public.record_score(p_event_id uuid, p_user_id uuid, p_score integer, p_withdrawn integer DEFAULT 0, p_returned integer DEFAULT 0)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_pack_slug text;
  v_scoring_type text;
  v_effective_score int;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  select e.room_id, e.pack_slug into v_room_id, v_pack_slug
  from public.events e
  where e.id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;
  if not exists (select 1 from public.rooms where id = v_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can record scores' using errcode = '42501';
  end if;
  select p.scoring_type into v_scoring_type from public.packs p where p.slug = v_pack_slug;
  if v_scoring_type = 'withdraw_return' then
    v_effective_score := p_returned - p_withdrawn;
  else
    v_effective_score := p_score;
    p_withdrawn := 0;
    p_returned := 0;
  end if;
  insert into public.scores (event_id, user_id, room_id, score, withdrawn, returned)
  values (p_event_id, p_user_id, v_room_id, v_effective_score, p_withdrawn, p_returned)
  on conflict (event_id, user_id) do update
    set score = excluded.score, withdrawn = excluded.withdrawn, returned = excluded.returned;
  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- remove_pack_from_room(p_room_id uuid, p_pack_slug text)
-- =================================================================
create or replace function public.remove_pack_from_room(p_room_id uuid, p_pack_slug text)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can remove packs' using errcode = '42501';
  end if;
  delete from public.room_packs where room_id = p_room_id and pack_slug = p_pack_slug;
  return true;
end;
$body$;


-- =================================================================
-- set_room_pack_config(p_room_id uuid, p_pack_slug text, p_win_points integer)
-- =================================================================
create or replace function public.set_room_pack_config(p_room_id uuid, p_pack_slug text, p_win_points integer)
returns void
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
    v_caller uuid := public.current_user_id();
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.rooms r
        where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
    ) then
        raise exception 'Only the host can configure pack payouts' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.packs p where p.slug = p_pack_slug
    ) then
        raise exception 'Unknown pack: %', p_pack_slug using errcode = 'P0002';
    end if;

    if p_win_points < 0 then
        raise exception 'win_points must be >= 0' using errcode = '22000';
    end if;

    insert into public.room_pack_configs (room_id, pack_slug, win_points)
    values (p_room_id, p_pack_slug, p_win_points)
    on conflict (room_id, pack_slug) do update set
        win_points = excluded.win_points,
        updated_at = now();
end;
$body$;


-- =================================================================
-- set_season_subtitle(p_room_id uuid, p_subtitle text)
-- =================================================================
create or replace function public.set_season_subtitle(p_room_id uuid, p_subtitle text)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can set the season subtitle' using errcode = '42501';
  end if;

  update public.seasons
    set subtitle = nullif(trim(p_subtitle), '')
    where room_id = p_room_id and status = 'active';

  return true;
end;
$body$;


-- =================================================================
-- set_tonight_star_pick(p_event_id uuid, p_member_id uuid, p_override_category text, p_custom_text text)
-- =================================================================
create or replace function public.set_tonight_star_pick(p_event_id uuid, p_member_id uuid, p_override_category text, p_custom_text text)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_custom_text text;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_override_category not in ('best_play','good_sport','held_the_room','showed_up','custom') then
    raise exception 'Unknown override_category' using errcode = '22023';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can set Tonight''s Star' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = p_member_id
  ) then
    raise exception 'Picked member is not in this room' using errcode = '22023';
  end if;

  if p_override_category = 'custom' then
    v_custom_text := nullif(trim(coalesce(p_custom_text, '')), '');
    if v_custom_text is null then
      raise exception 'Custom category requires a non-empty custom_text' using errcode = '22023';
    end if;
  else
    v_custom_text := null;
  end if;

  insert into public.tonight_star_picks (
    event_id, room_id, member_id, override_category, custom_text, created_at
  ) values (
    p_event_id, v_room_id, p_member_id, p_override_category, v_custom_text, now()
  )
  on conflict (event_id) do update
    set member_id = excluded.member_id,
        override_category = excluded.override_category,
        custom_text = excluded.custom_text,
        created_at = now();

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- update_event_played_at(p_event_id uuid, p_played_at timestamp with time zone)
-- =================================================================
create or replace function public.update_event_played_at(p_event_id uuid, p_played_at timestamp with time zone)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can change event dates'
      using errcode = '42501';
  end if;

  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;

  update public.events
  set played_at = p_played_at
  where id = p_event_id;

  return true;
end;
$body$;


-- =================================================================
-- update_host_journal(p_room_id uuid, p_journal text)
-- =================================================================
create or replace function public.update_host_journal(p_room_id uuid, p_journal text)
returns TABLE(id uuid, name text, mascot_name text, mascot_personality mascot_personality, mascot_political_ideology text, created_by uuid, created_at timestamp with time zone, updated_at timestamp with time zone, is_live boolean, next_event_description text, join_starting_bonus integer, user_role text, briefing_48h_enabled boolean, calendar_auto_add_host boolean, social_preferences_enabled boolean, social_narration_enabled boolean, max_seats integer, member_invite_quota integer, host_journal text)
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
    v_caller uuid := public.current_user_id();
    v_normalised_journal text;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if not exists (select 1 from public.rooms r
                   where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))) then
        raise exception 'Only the host can edit the room journal' using errcode = '42501';
    end if;

    v_normalised_journal := case
        when p_journal is null then null
        when btrim(p_journal) = '' then null
        else btrim(p_journal)
    end;

    if v_normalised_journal is not null
       and char_length(v_normalised_journal) > 280 then
        raise exception 'host_journal must be <= 280 characters' using errcode = '22023';
    end if;

    update public.rooms as r
    set host_journal = v_normalised_journal,
        updated_at = now()
    where r.id = p_room_id;

    return query
    select
        r.id, r.name, r.mascot_name, r.mascot_personality,
        r.mascot_political_ideology,
        r.created_by, r.created_at, r.updated_at, r.is_live,
        r.next_event_description,
        r.join_starting_bonus,
        m.role::text as user_role,
        r.briefing_48h_enabled,
        r.calendar_auto_add_host,
        r.social_preferences_enabled,
        r.social_narration_enabled,
        r.max_seats,
        r.member_invite_quota,
        r.host_journal
    from public.rooms r
    join public.room_memberships m on m.room_id = r.id
    where r.id = p_room_id and m.user_id = v_caller;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer)
-- =================================================================
create or replace function public.update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;
  update public.rooms
  set name = p_name, mascot_name = p_mascot_name, mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota, max_seats = p_max_seats, updated_at = now()
  where id = p_room_id;
  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text)
-- =================================================================
create or replace function public.update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  -- No inline whitelist: the rooms CHECK constraint is the single
  -- source of allowed values (V0.82 widened to 11).
  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text, p_join_starting_bonus integer DEFAULT 200)
-- =================================================================
create or replace function public.update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text, p_join_starting_bonus integer DEFAULT 200)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  if p_join_starting_bonus < 0 then
    raise exception 'join_starting_bonus must be >= 0' using errcode = '23514';
  end if;

  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      join_starting_bonus = p_join_starting_bonus,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text, p_join_starting_bonus integer DEFAULT 200, p_mascot_api_key text DEFAULT NULL::text, p_briefing_48h_enabled boolean DEFAULT true, p_calendar_auto_add_host boolean DEFAULT false, p_social_preferences_enabled boolean DEFAULT true, p_social_narration_enabled boolean DEFAULT true)
-- =================================================================
create or replace function public.update_room(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality mascot_personality, p_member_invite_quota integer, p_max_seats integer, p_mascot_political_ideology text DEFAULT 'centrist'::text, p_join_starting_bonus integer DEFAULT 200, p_mascot_api_key text DEFAULT NULL::text, p_briefing_48h_enabled boolean DEFAULT true, p_calendar_auto_add_host boolean DEFAULT false, p_social_preferences_enabled boolean DEFAULT true, p_social_narration_enabled boolean DEFAULT true)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  if p_join_starting_bonus < 0 then
    raise exception 'join_starting_bonus must be >= 0' using errcode = '23514';
  end if;

  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      join_starting_bonus = p_join_starting_bonus,
      mascot_api_key = p_mascot_api_key,
      briefing_48h_enabled = p_briefing_48h_enabled,
      calendar_auto_add_host = p_calendar_auto_add_host,
      social_preferences_enabled = p_social_preferences_enabled,
      social_narration_enabled = p_social_narration_enabled,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$body$;


-- =================================================================
-- update_room_packs(p_room_id uuid, p_slugs text[])
-- =================================================================
create or replace function public.update_room_packs(p_room_id uuid, p_slugs text[])
returns void
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
    v_invalid_slug text;
    v_removed_slug text;
    v_caller uuid := public.current_user_id();
begin
    -- Caller must be the room's host.
    if not exists (
        select 1 from public.rooms r
        where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
    ) then
        raise exception 'Only the host can update room packs' using errcode = '42501';
    end if;

    -- Validate every slug exists in the global packs catalog.
    select p.slug into v_invalid_slug
    from unnest(p_slugs) as p(slug)
    where not exists (select 1 from public.packs pk where pk.slug = p.slug)
    limit 1;
    if v_invalid_slug is not null then
        raise exception 'Unknown pack slug: %', v_invalid_slug using errcode = '22023';
    end if;

    -- Compute the set of slugs being uninstalled so we can
    -- emit system events.
    --
    -- Note: migration 041 originally tried to settle in-flight
    -- casino_withdrawals here (`cw.settled_at = now()`), but the
    -- live schema has neither an `event_id` column nor a
    -- `settled_at` column on casino_withdrawals (per migration
    -- 014 it uses `session_id`). That side-effect was already
    -- broken on live — leaving it out here; a separate
    -- reconciliation migration can address casino-withdrawal
    -- settle semantics.
    for v_removed_slug in
        select rp.pack_slug
        from public.room_packs rp
        where rp.room_id = p_room_id
          and rp.pack_slug <> all(p_slugs)
    loop
        -- Emit the system event for the briefing banner.
        insert into public.room_system_events (room_id, kind, payload)
        values (
            p_room_id,
            'pack_removed',
            jsonb_build_object('pack_slug', v_removed_slug)
        );
    end loop;

    -- Insert slugs not already present (idempotent on the
    -- presence-based model).
    insert into public.room_packs (room_id, pack_slug, added_by)
    select p_room_id, slug, v_caller
    from unnest(p_slugs) as s(slug)
    on conflict (room_id, pack_slug) do nothing;

    -- DELETE any prior rows not in the new set. Replaces the
    -- original UPDATE ... SET enabled = false, since there is no
    -- enabled flag on the live schema.
    delete from public.room_packs rp
    where rp.room_id = p_room_id
      and rp.pack_slug <> all(p_slugs);
end;
$body$;


-- =================================================================
-- update_room_settings(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality text, p_mascot_political_ideology text, p_max_seats integer, p_member_invite_quota integer, p_join_starting_bonus integer, p_social_narration_enabled boolean, p_briefing_48h_enabled boolean, p_social_preferences_enabled boolean, p_auto_close_hours integer, p_seat_deposit_amount integer, p_seat_deposit_trigger text, p_seat_deposit_grace_minutes integer)
-- =================================================================
create or replace function public.update_room_settings(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality text, p_mascot_political_ideology text, p_max_seats integer, p_member_invite_quota integer, p_join_starting_bonus integer, p_social_narration_enabled boolean, p_briefing_48h_enabled boolean, p_social_preferences_enabled boolean, p_auto_close_hours integer, p_seat_deposit_amount integer, p_seat_deposit_trigger text, p_seat_deposit_grace_minutes integer)
returns TABLE(id uuid, name text, mascot_name text, mascot_personality mascot_personality, mascot_political_ideology text, created_by uuid, created_at timestamp with time zone, updated_at timestamp with time zone, is_live boolean, next_event_description text, join_starting_bonus integer, user_role text, briefing_48h_enabled boolean, social_preferences_enabled boolean, social_narration_enabled boolean, max_seats integer, member_invite_quota integer, host_journal text, auto_close_hours integer, seat_deposit_amount integer, seat_deposit_trigger text, seat_deposit_grace_minutes integer)
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_updated boolean := false;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.rooms as r set
      name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality::mascot_personality,
      mascot_political_ideology = p_mascot_political_ideology,
      max_seats = p_max_seats,
      member_invite_quota = p_member_invite_quota,
      join_starting_bonus = p_join_starting_bonus,
      social_narration_enabled = p_social_narration_enabled,
      briefing_48h_enabled = p_briefing_48h_enabled,
      social_preferences_enabled = p_social_preferences_enabled,
      auto_close_hours = p_auto_close_hours,
      seat_deposit_amount = p_seat_deposit_amount,
      seat_deposit_trigger = p_seat_deposit_trigger,
      seat_deposit_grace_minutes = p_seat_deposit_grace_minutes,
      updated_at = now()
  where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  returning true into v_updated;

  if v_updated is not true then
    raise exception 'Room not found or caller is not the host' using errcode = '42501';
  end if;

  return query
  select
      r.id, r.name, r.mascot_name, r.mascot_personality,
      r.mascot_political_ideology,
      r.created_by, r.created_at, r.updated_at, r.is_live,
      r.next_event_description,
      r.join_starting_bonus,
      m.role::text as user_role,
      r.briefing_48h_enabled,
      r.social_preferences_enabled,
      r.social_narration_enabled,
      r.max_seats,
      r.member_invite_quota,
      r.host_journal,
      r.auto_close_hours,
      r.seat_deposit_amount,
      r.seat_deposit_trigger,
      r.seat_deposit_grace_minutes
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id and m.user_id = v_caller;
end;
$body$;


-- =================================================================
-- update_room_settings(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality text, p_mascot_political_ideology text, p_max_seats integer, p_member_invite_quota integer, p_join_starting_bonus integer, p_social_narration_enabled boolean, p_briefing_48h_enabled boolean, p_calendar_auto_add_host boolean, p_social_preferences_enabled boolean, p_auto_close_hours integer, p_seat_deposit_amount integer, p_seat_deposit_trigger text, p_seat_deposit_grace_minutes integer)
-- =================================================================
create or replace function public.update_room_settings(p_room_id uuid, p_name text, p_mascot_name text, p_mascot_personality text, p_mascot_political_ideology text, p_max_seats integer, p_member_invite_quota integer, p_join_starting_bonus integer, p_social_narration_enabled boolean, p_briefing_48h_enabled boolean, p_calendar_auto_add_host boolean, p_social_preferences_enabled boolean, p_auto_close_hours integer, p_seat_deposit_amount integer, p_seat_deposit_trigger text, p_seat_deposit_grace_minutes integer)
returns TABLE(id uuid, name text, mascot_name text, mascot_personality mascot_personality, mascot_political_ideology text, created_by uuid, created_at timestamp with time zone, updated_at timestamp with time zone, is_live boolean, next_event_description text, join_starting_bonus integer, user_role text, briefing_48h_enabled boolean, calendar_auto_add_host boolean, social_preferences_enabled boolean, social_narration_enabled boolean, max_seats integer, member_invite_quota integer, host_journal text, auto_close_hours integer, seat_deposit_amount integer, seat_deposit_trigger text, seat_deposit_grace_minutes integer)
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_updated boolean := false;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.rooms as r set
      name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality::mascot_personality,
      mascot_political_ideology = p_mascot_political_ideology,
      max_seats = p_max_seats,
      member_invite_quota = p_member_invite_quota,
      join_starting_bonus = p_join_starting_bonus,
      social_narration_enabled = p_social_narration_enabled,
      briefing_48h_enabled = p_briefing_48h_enabled,
      calendar_auto_add_host = p_calendar_auto_add_host,
      social_preferences_enabled = p_social_preferences_enabled,
      auto_close_hours = p_auto_close_hours,
      seat_deposit_amount = p_seat_deposit_amount,
      seat_deposit_trigger = p_seat_deposit_trigger,
      seat_deposit_grace_minutes = p_seat_deposit_grace_minutes,
      updated_at = now()
  where r.id = p_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  returning true into v_updated;

  if v_updated is not true then
    raise exception 'Room not found or caller is not the host' using errcode = '42501';
  end if;

  return query
  select
      r.id, r.name, r.mascot_name, r.mascot_personality,
      r.mascot_political_ideology,
      r.created_by, r.created_at, r.updated_at, r.is_live,
      r.next_event_description,
      r.join_starting_bonus,
      m.role::text as user_role,
      r.briefing_48h_enabled,
      r.calendar_auto_add_host,
      r.social_preferences_enabled,
      r.social_narration_enabled,
      r.max_seats,
      r.member_invite_quota,
      r.host_journal,
      r.auto_close_hours,
      r.seat_deposit_amount,
      r.seat_deposit_trigger,
      r.seat_deposit_grace_minutes
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id and m.user_id = v_caller;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- upsert_casino_config(p_room_id uuid, p_enabled boolean, p_chip_color_map jsonb DEFAULT '{}'::jsonb, p_standard_presets boolean DEFAULT true)
-- =================================================================
create or replace function public.upsert_casino_config(p_room_id uuid, p_enabled boolean, p_chip_color_map jsonb DEFAULT '{}'::jsonb, p_standard_presets boolean DEFAULT true)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can configure casino' using errcode = '42501';
  end if;

  insert into public.casino_room_config (room_id, enabled, chip_color_map, standard_presets)
  values (p_room_id, p_enabled, p_chip_color_map, p_standard_presets)
  on conflict (room_id) do update
    set enabled = excluded.enabled,
        chip_color_map = excluded.chip_color_map,
        standard_presets = excluded.standard_presets,
        updated_at = now();

  return true;
end;
$body$;

-- (bare guard verified: unaliased public.rooms scope, id = room id)

-- =================================================================
-- upsert_casino_config(p_room_id uuid, p_enabled boolean, p_chip_color_map jsonb DEFAULT '{}'::jsonb, p_standard_presets boolean DEFAULT true, p_vision_provider text DEFAULT 'on_device'::text, p_vision_model text DEFAULT NULL::text, p_vision_api_key text DEFAULT NULL::text)
-- =================================================================
create or replace function public.upsert_casino_config(p_room_id uuid, p_enabled boolean, p_chip_color_map jsonb DEFAULT '{}'::jsonb, p_standard_presets boolean DEFAULT true, p_vision_provider text DEFAULT 'on_device'::text, p_vision_model text DEFAULT NULL::text, p_vision_api_key text DEFAULT NULL::text)
returns boolean
language plpgsql
volatile
security definer
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))) then
    raise exception 'Only the host can configure casino' using errcode = '42501';
  end if;

  if p_vision_provider not in ('on_device', 'minimax_vision') then
    raise exception 'Unknown vision provider: %', p_vision_provider using errcode = '23514';
  end if;

  insert into public.casino_room_config (
    room_id, enabled, chip_color_map, standard_presets,
    vision_provider, vision_model, vision_api_key
  )
  values (
    p_room_id, p_enabled, p_chip_color_map, p_standard_presets,
    p_vision_provider, p_vision_model, p_vision_api_key
  )
  on conflict (room_id) do update
    set enabled = excluded.enabled,
        chip_color_map = excluded.chip_color_map,
        standard_presets = excluded.standard_presets,
        vision_provider = excluded.vision_provider,
        vision_model = excluded.vision_model,
        vision_api_key = excluded.vision_api_key,
        updated_at = now();

  return true;
end;
$body$;


-- =================================================================
-- waive_seat_deposit(p_event_id uuid, p_member_id uuid)
-- =================================================================
create or replace function public.waive_seat_deposit(p_event_id uuid, p_member_id uuid)
returns boolean
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can waive a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'waived', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_room_id and user_id = p_member_id;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_waive', v_deposit.amount,
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$body$;


-- =================================================================
-- withdraw_casino_chips(p_session_id uuid, p_member_id uuid, p_points integer)
-- =================================================================
create or replace function public.withdraw_casino_chips(p_session_id uuid, p_member_id uuid, p_points integer)
returns TABLE(id uuid, session_id uuid, member_id uuid, points_withdrawn bigint, withdrawn_at timestamp with time zone, withdrawn_by uuid)
language plpgsql
volatile
security definer
set search_path=public
as $body$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_available bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_points is null or p_points <= 0 then
    raise exception 'Points must be positive' using errcode = '23514';
  end if;

  select e.room_id into v_room_id
    from public.events e
    where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if v_caller <> p_member_id
     and not exists (
       select 1 from public.rooms r
       where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
     ) then
    raise exception 'Not authorized to withdraw for this member' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = p_member_id
  ) then
    raise exception 'Member is not in the event room' using errcode = 'P0002';
  end if;

  -- Reservation gate: p_points <= unreserved wealth. Open
  -- entitlement E = last scan value + withdrawals after that scan
  -- (or Σ all session withdrawals when the member never scanned).
  -- finalized_at is a host bookkeeping stamp only — a scan settles
  -- at record time (074), so the E formula keys off the scan row,
  -- not finalized_at.
  select m.points_balance - (
    coalesce((
      select cs.vision_amount_points
      from public.casino_scans cs
      where cs.session_id = p_session_id
        and cs.member_id = p_member_id
      order by cs.recorded_at desc
      limit 1
    ), 0)
    +
    coalesce((
      select sum(cw.points_withdrawn)
      from public.casino_withdrawals cw
      where cw.session_id = p_session_id
        and cw.member_id = p_member_id
        and not exists (
          select 1 from public.casino_scans cs
          where cs.session_id = p_session_id
            and cs.member_id = p_member_id
            and cs.recorded_at >= cw.withdrawn_at
        )
    ), 0)
  )
  into v_available
  from public.room_memberships m
  where m.user_id = p_member_id and m.room_id = v_room_id;

  if v_available is null or v_available < p_points then
    raise exception 'Insufficient unreserved points balance' using errcode = '23514';
  end if;

  -- RESERVATION ONLY: no balance/score mutation. The memo row keeps
  -- amount = −p_points for display (host dispense list, night
  -- recap); the principal returns via scan-delta settlement, and an
  -- open withdrawal at finalize is forfeited for non-scanners.
  insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_by)
  values (v_room_id, p_session_id, p_member_id, 'casino_withdrawal', -p_points, v_caller);

  insert into public.casino_withdrawals (session_id, member_id, points_withdrawn, withdrawn_by)
  values (p_session_id, p_member_id, p_points, v_caller);

  return query
    select cw.id, cw.session_id, cw.member_id, cw.points_withdrawn, cw.withdrawn_at, cw.withdrawn_by
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id and cw.member_id = p_member_id
    order by cw.withdrawn_at desc
    limit 1;
end;
$body$;
