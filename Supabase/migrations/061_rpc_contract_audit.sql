-- 061: RPC contract audit — align every 45 RPC call site in the iOS
-- LiveRoomStore / CasinoService with the server's actual return
-- shape.
--
-- Background: the iOS Swift models were written against a richer
-- contract than the live RPCs actually return. The audit
-- (`build/rpc-contract-audit-spec.md`) catalogued every mismatch
-- and chose, for each, whether to fix the server or the client.
-- Decisions:
--
--   * Scalar-vs-array mismatches → fix the client. The server
--     scalar is the correct contract; the array wrapper was the
--     client's mistake.
--   * Table-via-object vs table-by-slug → fix the server (already
--     flowed through the model).
--   * Missing server shape for a model field → fix the server by
--     widening the RETURNS TABLE to the model's keys (or aliasing
--     old → new so the model decodes without modification).
--   * Missing RPCs entirely → create them.
--
-- DROP + CREATE wherever the RETURNS TABLE column list changed
-- (Postgres 42P13: CREATE OR REPLACE refuses drifted returns
-- tables). Follow migration 058's style: `language sql` where
-- possible, `security definer`, `set search_path = public`, grant
-- to authenticated, `notify pgrst, 'reload schema';` at the end.

-- =================================================================
-- 1a. get_briefing_summary — widen the return shape to the
--     BriefingSummary model's keys. The model decodes
--     event_id, room_id, seats_total, seats_claimed, seats_declined,
--     seats_unclaimed; extra columns (event_name, played_at,
--     venue, host_note, claimed_member_names) are ignored by the
--     decoder but kept for other consumers / migrations.
-- =================================================================
drop function if exists public.get_briefing_summary(uuid);
create function public.get_briefing_summary(p_event_id uuid)
returns table (
    event_id uuid,
    room_id uuid,
    event_name text,
    played_at timestamptz,
    venue text,
    seats_total integer,
    seats_claimed bigint,
    seats_declined bigint,
    seats_unclaimed bigint,
    host_note text,
    claimed_member_names text[]
)
language sql
stable
security definer
set search_path = public
as $$
    select
        e.id as event_id,
        e.room_id,
        e.name as event_name,
        e.played_at,
        null::text as venue,
        r.max_seats as seats_total,
        count(rsvp.id) filter (where rsvp.state = 'claimed') as seats_claimed,
        count(rsvp.id) filter (where rsvp.state = 'declined') as seats_declined,
        count(rsvp.id) filter (where rsvp.state = 'unclaimed') as seats_unclaimed,
        e.host_note,
        coalesce(
            array_agg(u.display_name)
            filter (where rsvp.state = 'claimed' and u.display_name is not null),
            '{}'::text[]
        ) as claimed_member_names
    from public.events e
    join public.rooms r on r.id = e.room_id
    left join public.event_rsvps rsvp on rsvp.event_id = e.id
    left join public.users u on u.id = rsvp.member_id
    where e.id = p_event_id
    group by e.id, e.room_id, e.name, e.played_at, r.max_seats, e.host_note;
$$;

grant execute on function public.get_briefing_summary(uuid) to authenticated;

-- =================================================================
-- 1b. get_room_packs — return pack slugs only. The iOS client
--     decodes [String]; the previous shape returned full pack
--     rows.
-- =================================================================
drop function if exists public.get_room_packs(uuid);
create function public.get_room_packs(p_room_id uuid)
returns table (pack_slug text)
language sql
stable
security definer
set search_path = public
as $$
    select pack_slug from public.room_packs where room_id = p_room_id order by added_at;
$$;

grant execute on function public.get_room_packs(uuid) to authenticated;

-- =================================================================
-- 1c. upsert_event_rsvp — return the full MemberRSVP row. The
--     model decodes id, event_id, room_id, member_id, state,
--     responded_at. The previous return table omitted id + room_id.
-- =================================================================
drop function if exists public.upsert_event_rsvp(uuid, text, uuid);
create function public.upsert_event_rsvp(
  p_event_id uuid,
  p_state text,
  p_target_member_id uuid default null
)
returns table (
  id uuid,
  event_id uuid,
  room_id uuid,
  member_id uuid,
  state text,
  responded_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := auth.uid();
  v_target uuid := coalesce(p_target_member_id, v_caller);
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- If writing someone else's row, the caller must be the host.
  if v_target <> v_caller then
    select e.room_id into v_room_id
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.id = p_event_id and r.created_by = v_caller;
    if v_room_id is null then
      raise exception 'Only the host can update another member''s RSVP'
        using errcode = '42501';
    end if;
  else
    -- Self-write: capture the room id for the row write.
    select room_id into v_room_id
    from public.events where id = p_event_id;
  end if;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Validate state value matches the table's CHECK constraint
  -- (claimed | tentative | declined | unclaimed).
  if p_state not in ('claimed', 'tentative', 'declined', 'unclaimed') then
    raise exception 'Invalid RSVP state: %', p_state using errcode = '22000';
  end if;

  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, v_target, p_state, now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  return query
    select er.id, er.event_id, er.room_id, er.member_id, er.state::text as state, er.responded_at
    from public.event_rsvps er
    where er.event_id = p_event_id and er.member_id = v_target;
end;
$$;

grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated;

-- =================================================================
-- 1d. get_event_chapter_line — return the ChapterLine model shape.
--     The model decodes id, room_id, session_id, title,
--     next_episode_teaser, written_at. The table has id, event_id,
--     room_id, title, call_forward, created_at — alias the
--     mismatched column names so the model decodes without
--     modification.
-- =================================================================
drop function if exists public.get_event_chapter_line(uuid);
create function public.get_event_chapter_line(p_event_id uuid)
returns table (
    id uuid,
    room_id uuid,
    session_id uuid,
    title text,
    next_episode_teaser text,
    written_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select cl.id, cl.room_id, cl.event_id as session_id, cl.title,
         cl.call_forward as next_episode_teaser, cl.created_at as written_at
  from public.chapter_lines cl
  where cl.event_id = p_event_id
    and exists (
      select 1 from public.events e
      join public.room_memberships rm
        on rm.room_id = e.room_id
      where e.id = p_event_id
        and rm.user_id = public.current_user_id()
    )
  limit 1;
$$;

grant execute on function public.get_event_chapter_line(uuid) to authenticated;

-- =================================================================
-- 1e. update_room_settings — change returns void → returns the
--     full Room row. Mirror update_host_journal's return shape so
--     the existing Room decoder works without modification.
-- =================================================================
drop function if exists public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean
);
create function public.update_room_settings(
    p_room_id uuid,
    p_name text,
    p_mascot_name text,
    p_mascot_personality text,
    p_mascot_political_ideology text,
    p_max_seats integer,
    p_member_invite_quota integer,
    p_join_starting_bonus integer,
    p_social_narration_enabled boolean,
    p_briefing_48h_enabled boolean,
    p_calendar_auto_add_host boolean,
    p_social_preferences_enabled boolean
)
returns table (
    id uuid,
    name text,
    mascot_name text,
    mascot_personality public.mascot_personality,
    mascot_political_ideology text,
    created_by uuid,
    created_at timestamptz,
    updated_at timestamptz,
    is_live boolean,
    next_event_description text,
    join_starting_bonus integer,
    user_role text,
    briefing_48h_enabled boolean,
    calendar_auto_add_host boolean,
    social_preferences_enabled boolean,
    social_narration_enabled boolean,
    max_seats integer,
    member_invite_quota integer,
    host_journal text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.rooms set
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
      updated_at = now()
  where id = p_room_id and created_by = v_caller;

  if not found then
    raise exception 'Room not found or caller is not the host' using errcode = '42501';
  end if;

  return query
    select r.id, r.name, r.mascot_name, r.mascot_personality,
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
    where r.id = p_room_id and m.user_id = public.current_user_id();
end;
$$;

grant execute on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean
) to authenticated;

-- =================================================================
-- 1f. withdraw_casino_chips — change returns boolean → returns the
--     freshly-inserted casino_withdrawals row. The iOS client
--     decoder expects id, session_id, member_id, points_withdrawn,
--     withdrawn_at, withdrawn_by (the full CasinoWithdrawal model).
--     The signature stays (p_session_id, p_member_id, p_points);
--     the iOS call site is fixed in 3a to use the correct param
--     names.
-- =================================================================
drop function if exists public.withdraw_casino_chips(uuid, uuid, int);
create function public.withdraw_casino_chips(
  p_session_id uuid,
  p_member_id uuid,
  p_points int
)
returns table (
    id uuid,
    session_id uuid,
    member_id uuid,
    points_withdrawn bigint,
    withdrawn_at timestamptz,
    withdrawn_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_current_balance bigint;
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
       where r.id = v_room_id and r.created_by = v_caller
     ) then
    raise exception 'Not authorized to withdraw for this member' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = p_member_id
  ) then
    raise exception 'Member is not in the event room' using errcode = 'P0002';
  end if;

  select m.points_balance into v_current_balance
    from public.room_memberships m
    where m.user_id = p_member_id and m.room_id = v_room_id;
  if v_current_balance is null or v_current_balance < p_points then
    raise exception 'Insufficient points balance' using errcode = '23514';
  end if;

  update public.room_memberships
    set points_balance = points_balance - p_points,
        season_score   = season_score   - p_points
    where user_id = p_member_id and room_id = v_room_id;

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
$$;

grant execute on function public.withdraw_casino_chips(uuid, uuid, int) to authenticated;

-- =================================================================
-- 1g. get_my_open_attestations — NEW (snake_case canonical). The
--     camelCase name the iOS code used to call never existed
--     server-side; migration 029's `get_my_open_casino_attestations`
--     was also never applied to remote. The new function returns
--     the full OpenAttestationSummary shape including the
--     `has_dispute` column from migration 029.
-- =================================================================
create or replace function public.get_my_open_attestations()
returns table (
  attestation_id uuid,
  session_id uuid,
  room_id uuid,
  room_name text,
  session_name text,
  vision_amount_points bigint,
  detection_source text,
  confidence_avg double precision,
  opened_at timestamptz,
  has_dispute boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select
    sa.id, sa.session_id, sa.room_id, r.name, e.name,
    sa.vision_amount_points, sa.detection_source, sa.confidence_avg,
    sa.opened_at, sa.disputed as has_dispute
  from public.settlement_attestations sa
  join public.rooms r on r.id = sa.room_id
  left join public.events e on e.id = sa.session_id
  where sa.member_id = public.current_user_id()
    and sa.closed_at is null
  order by sa.opened_at desc;
$$;

grant execute on function public.get_my_open_attestations() to authenticated;

-- =================================================================
-- 1h. close_stale_attestations — NEW. Lazy 24h finalizer. Mirrors
--     migration 029's definition; was never applied to remote.
-- =================================================================
create or replace function public.close_stale_attestations()
returns integer
language sql
security definer
set search_path = public
as $$
  with closed as (
    update public.settlement_attestations
      set closed_at = now()
      where closed_at is null
        and now() > opened_at + interval '24 hours'
      returning id
  )
  select count(*)::integer from closed;
$$;

grant execute on function public.close_stale_attestations() to authenticated;

-- =================================================================
-- 1i. get_withdrawal_balance — NEW. The member's points_balance
--     for the event's room. NULL when no membership (the iOS
--     client collapses to 0).
-- =================================================================
create or replace function public.get_withdrawal_balance(p_event_id uuid, p_user_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select m.points_balance
  from public.room_memberships m
  join public.events e on e.id = p_event_id
  where m.room_id = e.room_id and m.user_id = p_user_id
  limit 1;
$$;

grant execute on function public.get_withdrawal_balance(uuid, uuid) to authenticated;

-- =================================================================
-- 2. Refresh the PostgREST schema cache so the new return shapes
--    are immediately visible to the iOS app.
-- =================================================================
notify pgrst, 'reload schema';
