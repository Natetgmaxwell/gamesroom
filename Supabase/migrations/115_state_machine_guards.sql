-- 115_state_machine_guards.sql
-- Lane S — the server-side guards the explicit state machines need.
--
-- Bodies are copied from their current definitions and changed only
-- where listed below:
--   * 107-114: the repo migration file (they are live).
--   * older functions: docs/audit/2026-11-08/live-functions.sql (the
--     pre-107 live snapshot), except remove_room_member, which that
--     dump does not carry; 093 is its creating migration and nothing
--     after 093 redefines it.
--
-- 1. night_phase(played_at, settled_at, auto_close_hours, now) — NEW.
--    One scalar for "what phase is this night in". Text, not a new
--    enum type: an enum cannot be altered inside a transaction that
--    also uses its new value, and every consumer already speaks text
--    over PostgREST. States: none / upcoming / live / stranded /
--    recap / past. `stranded` is the state the app has been hiding —
--    started, never settled, auto-close window gone.
-- 2. get_active_event__inner — the settled branch only runs when
--    nothing was returned, so the function honours its documented
--    one-row contract (future + settled<24h used to return 2).
--    Priority: live > next future > settled<24h. Dead duplicate
--    `if found then return` removed.
-- 3. remove_room_member (kick) — the refund is one CTE: it flips
--    held -> returned and credits the sum of exactly the rows it
--    flipped. Before 113 the second step re-selected every
--    status='returned' deposit, so releasing then being kicked paid
--    the member twice, and more than one returned deposit credited
--    only one arbitrary row.
-- 4. claim_seat_with_deposit — a forfeited deposit is terminal: the
--    member cannot re-take the seat the host kept the deposit for.
-- 5. upsert_event_rsvp — same forfeit guard, on the claim path only
--    (declining or releasing after a forfeit is still allowed; the
--    host's decision was about the seat, not about silence).
-- 6. release_seat — refuses once the night has started, the same
--    `night_started` gate cancel_event (114) already has. Releasing
--    mid-night returned the deposit and defeated the host's forfeit.
-- 7. check_in_seat — refuses before the night has started, the
--    client's own rule (RoomDetailView's check-in button requires
--    played_at <= now, and NightPlan.plan offers no member action
--    before the night starts). `too_early`. Checking in late is
--    still allowed: the client never hides the button for lateness.
-- 8. auto_close_stale_events — stamps settled_at = played_at + the
--    room's window, not now(). A month-old stranded night then reads
--    as 'past', never as a recap that settled two seconds ago.
-- 9. one_upcoming_night — the rule is enforced by a trigger that
--    evaluates now() when the row is written, not by 012's partial
--    unique index (whose `where played_at > now()` PostgreSQL refuses
--    outright, so it never existed). The live database already
--    carries a hand-applied version of this trigger (public.
--    check_one_upcoming_event_per_room, 23505, no settled filter);
--    this migration takes that name and tightens it in place rather
--    than adding a second trigger over the same table.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/115_state_machine_guards.sql
--
-- Post-apply verification:
--   select public.night_phase(now() - interval '9 hours', null, 8, now());
--   select count(*) from public.get_active_event('<room>'::uuid);
--   select tgname from pg_trigger where tgrelid = 'public.events'::regclass and not tgisinternal;

begin;

-- ---------------------------------------------------------------------------
-- 1. night_phase — one rule for "what phase is this night in".
-- ---------------------------------------------------------------------------
create or replace function public.night_phase(
  p_played_at timestamp with time zone,
  p_settled_at timestamp with time zone,
  p_auto_close_hours integer,
  p_now timestamp with time zone default now()
)
returns text
language sql
immutable
as $$
  select case
    when p_played_at is null then 'none'
    when p_settled_at is not null
         and p_settled_at > p_now - interval '24 hours' then 'recap'
    when p_settled_at is not null then 'past'
    when p_played_at > p_now then 'upcoming'
    when p_now < p_played_at + make_interval(hours => coalesce(p_auto_close_hours, 8))
      then 'live'
    else 'stranded'
  end;
$$;

revoke all on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) from public, anon;
grant execute on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) to authenticated, service_role;

comment on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) is
  'S — the night''s phase as one scalar: none / upcoming / live / stranded / recap / past. `live` ends at played_at + auto_close_hours whether or not the night was settled; `stranded` is started, unsettled, window gone; `recap` is a settle inside the last 24h. Immutable: pass p_now to pin the clock.';

-- ---------------------------------------------------------------------------
-- 2. get_active_event__inner — exactly one row, priority live > future >
--    settled<24h. Body is 107's; the settled query moves after the
--    future query and runs only when the future branch found nothing.
-- ---------------------------------------------------------------------------
create or replace function public.get_active_event__inner(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamp with time zone,
    created_at timestamp with time zone,
    host_note text,
    pack_slug text,
    settled_at timestamp with time zone,
    max_seats integer,
    pack_slugs text[],
    hidden_from_user_ids uuid[],
    event_calendar_identifier text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- (i) The live night. Started, not settled, and still inside the
  --     room's auto-close window, so a night from last month cannot
  --     masquerade as tonight. Latest start wins.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at <= now()
      and e.settled_at is null
      and e.played_at > now() - make_interval(hours => coalesce(r.auto_close_hours, 8))
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by e.played_at desc
    limit 1;
  if found then
    return;
  end if;

  -- (ii) The next night. Soonest first. A future night outranks a
  --      fresh recap: the claim card is what the room page needs,
  --      and get_recent_settled_event carries the recap alongside it.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at > now()
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by e.played_at asc
    limit 1;
  if found then
    return;
  end if;

  -- (iii) The night we just finished. Settled within the last 24h so
  --       the recap shows up tonight and is gone tomorrow. Latest
  --       settle wins. Only reached when there is no live or future
  --       night, so this function returns exactly one row.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.settled_at is not null
      and e.settled_at > now() - interval '24 hours'
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by e.settled_at desc
    limit 1;
end;
$$;

revoke all on function public.get_active_event__inner(uuid) from public, anon, authenticated;

comment on function public.get_active_event__inner(uuid) is
  'V1.24 — the one event a room page should show: the live night (started, unsettled, inside the room''s auto-close window), else the next scheduled night, else the night settled in the last 24h. Exactly one row. Hidden members never see the events they are hidden from.';

-- ---------------------------------------------------------------------------
-- 3. remove_room_member — kick. Body is 093's; 2h and 2i are one CTE so
--    the credit is the sum of exactly the rows the refund flipped.
-- ---------------------------------------------------------------------------
create or replace function public.remove_room_member(
  p_room_id uuid,
  p_target_user_id uuid
)
returns setof public.room_memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_target_status text;
  v_target_role text;
begin
  -- 2a. Auth check (cheap, first).
  if v_caller is null then
    raise exception 'not_authenticated: caller is not signed in'
      using errcode = '42501';
  end if;

  -- 2b. Caller must be a host role in this room. Uses the table
  -- directly (NOT rooms.created_by) so multi-host is inherited
  -- naturally — the second promoted host can also kick.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller
      and role = 'host'
      and membership_status = 'active'
  ) then
    raise exception 'not_authorized: caller is not a host in this room'
      using errcode = '42501';
  end if;

  -- 2c. Target must be a member of this room (any status — kicked
  -- is a no-op below, but the row must exist).
  select role, membership_status
    into v_target_role, v_target_status
  from public.room_memberships
  where room_id = p_room_id
    and user_id = p_target_user_id;
  if not found then
    raise exception 'not_found: target is not a member of this room'
      using errcode = 'P0002';
  end if;

  -- 2d. Idempotent: kicking an already-kicked member returns the
  -- roster unchanged. The roster is always active-only.
  if v_target_status = 'kicked' then
    return query
      select * from public.room_memberships
      where room_id = p_room_id
        and membership_status = 'active';
    return;
  end if;

  -- 2e. Target must not be a host — demote first. One tool per row
  -- prevents host-lockout accidents.
  if v_target_role = 'host' then
    raise exception 'is_host: demote the target to member before removing them'
      using errcode = '42501';
  end if;

  -- 2f. Target must not be the caller. (093 wrote `v_target_user_id`,
  -- which is not a declared variable: every kick of a plain member
  -- died with 42703 "column v_target_user_id does not exist" before
  -- this line was reached. The parameter is p_target_user_id.)
  if p_target_user_id = v_caller then
    raise exception 'is_self: you cannot remove yourself; use leave_room instead'
      using errcode = '42501';
  end if;

  -- 2g. Live-event guard: a held seat deposit on a LIVE event must
  -- be settled before the host can kick. "Live" = played_at <= now()
  -- AND no settlement transaction exists for the event yet (the
  -- night is in play or stalled, escrow money is mid-flight). For
  -- future events (played_at > now()), the deposit is auto-refunded
  -- below.
  if exists (
    select 1
    from public.seat_deposits sd
    join public.events e on e.id = sd.event_id
    where sd.room_id = p_room_id
      and sd.user_id = p_target_user_id
      and sd.status = 'held'
      and e.played_at <= now()
      and not exists (
        select 1 from public.transactions t
        where t.session_id = sd.event_id
          and t.room_id = sd.room_id
      )
  ) then
    raise exception 'active_deposit: settle the night before removing this member'
      using errcode = '42501';
  end if;

  -- 2h. Refund path: held deposits on FUTURE events are auto-
  -- refunded (escrow integrity, D5) AND the points they cost are
  -- credited back, in one statement, so the credit is the sum of
  -- exactly the rows this call flipped. Re-selecting every
  -- status='returned' deposit instead (093's second statement)
  -- paid a member twice when they had released the seat first, and
  -- credited only one arbitrary row when they held more than one.
  with refunded as (
    update public.seat_deposits sd
       set status = 'returned',
           returned_at = now(),
           settled_at = now()
      from public.events e
     where sd.event_id = e.id
       and sd.room_id = p_room_id
       and sd.user_id = p_target_user_id
       and sd.status = 'held'
       and e.played_at > now()
    returning sd.amount
  )
  update public.room_memberships m
     set points_balance = m.points_balance + coalesce((select sum(r.amount) from refunded r), 0)
   where m.room_id = p_room_id
     and m.user_id = p_target_user_id;

  -- 2j. Apply the kick — status change, not a row delete (D1,
  -- invariant 1). The kicked row is preserved so the ledger, season
  -- score, points balance, arcs and awards all survive.
  update public.room_memberships
    set membership_status = 'kicked'
  where room_id = p_room_id
    and user_id = p_target_user_id;

  -- 2k. Return the active-only roster so iOS can rebuild from one
  -- call (mirrors transfer_host_role, 091).
  return query
    select * from public.room_memberships
    where room_id = p_room_id
      and membership_status = 'active';
end;
$$;

revoke all on function public.remove_room_member(uuid, uuid) from public;
grant execute on function public.remove_room_member(uuid, uuid) to authenticated;

comment on function public.remove_room_member(uuid, uuid) is
  'V0.98 — host removes a member from the room (D1, D2). Status change, never row delete: ledger/season/history preserved. Caller must be an active host role (not rooms.created_by — multi-host). Five guards: not_authorized, not_found, is_host, is_self, active_deposit. Held deposits on future events are auto-refunded and credited once, as the sum of the rows refunded.';

-- ---------------------------------------------------------------------------
-- 4. claim_seat_with_deposit — 113's body plus the forfeit guard: a
--    deposit the host kept is terminal for that member on that night.
-- ---------------------------------------------------------------------------
create or replace function public.claim_seat_with_deposit(p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_amount integer;
  v_trigger text;
  v_balance integer;
  v_max_seats integer;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_amount, r.seat_deposit_trigger, r.max_seats
    into v_room_id, v_amount, v_trigger, v_max_seats
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Membership gate: only an active room member can claim.
  select m.points_balance into v_balance
  from public.room_memberships m
  where m.room_id = v_room_id
    and m.user_id = v_caller
    and m.membership_status = 'active';

  if v_balance is null then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Forfeit is terminal. The host kept this member's deposit for this
  -- night; re-claiming would overwrite the forfeited row back to
  -- 'held' and debit them a second time, making the host's decision
  -- reversible by the person it was made about. A new night is a new
  -- seat; this night's is gone.
  if exists (
    select 1 from public.seat_deposits sd
    where sd.event_id = p_event_id
      and sd.user_id = v_caller
      and sd.status = 'forfeited'
  ) then
    raise exception 'forfeited_seat' using errcode = 'P0001';
  end if;

  -- One claim at a time per night: two members cannot both take the
  -- last chair.
  perform 1 from public.events where id = p_event_id for update;

  -- Capacity. The caller who already holds a seat may always refresh
  -- it; everybody else needs a free chair.
  if v_max_seats is not null and v_max_seats > 0
     and not exists (
       select 1 from public.event_rsvps r
       where r.event_id = p_event_id
         and r.member_id = v_caller
         and r.state = 'claimed'
     )
     and (
       select count(*)
       from public.event_rsvps r
       where r.event_id = p_event_id
         and r.state = 'claimed'
         and exists (
           select 1 from public.room_memberships m
           where m.room_id = r.room_id
             and m.user_id = r.member_id
             and m.membership_status = 'active'
         )
     ) >= v_max_seats then
    raise exception 'night_full' using errcode = 'P0001';
  end if;

  -- Escrow off (or zero amount): plain claim, no deposit row.
  -- The RSVP upsert below is the whole effect.
  if v_amount is null or v_amount = 0 or v_trigger = 'off' then
    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
      values (p_event_id, v_room_id, v_caller, 'claimed', now())
      on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
    return true;
  end if;

  -- A deposit still in escrow means the seat is already paid for:
  -- no second debit, ever. The RSVP is upserted below either way.
  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    if v_balance < v_amount then
      raise exception 'Balance too low for the seat deposit (% CC needed)', v_amount
        using errcode = '42501';
    end if;

    update public.room_memberships
      set points_balance = points_balance - v_amount
      where room_id = v_room_id and user_id = v_caller;

    -- A released seat re-takes the deposit: the row goes back into
    -- escrow. The ledger keeps what happened the first time round.
    insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
      values (p_event_id, v_room_id, v_caller, v_amount, 'held')
      on conflict (event_id, user_id) do update set
        amount = excluded.amount,
        status = 'held',
        held_at = now(),
        returned_at = null,
        forfeited_at = null,
        forfeited_by = null,
        settled_at = null;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, v_caller, 'seat_deposit', v_amount,
      jsonb_build_object('direction', 'escrow'),
      v_caller
    );
  end if;

  -- Always: the seat is claimed, deposit or no deposit.
  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, v_caller, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  return true;
end;
$$;

revoke all on function public.claim_seat_with_deposit(uuid) from public, anon;
grant execute on function public.claim_seat_with_deposit(uuid) to authenticated, service_role;

comment on function public.claim_seat_with_deposit(uuid) is
  'S3.1 — member claims a seat; the room''s seat deposit leaves points_balance into escrow and the RSVP is always upserted to claimed. A released seat re-takes the deposit. P0001 ''night_full'' when the claimed count has reached the room''s max_seats; P0001 ''forfeited_seat'' when the host already kept this member''s deposit for this night.';

-- ---------------------------------------------------------------------------
-- 5. upsert_event_rsvp — 113's body plus the same forfeit guard on the
--    claim path.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_event_rsvp(p_event_id uuid, p_state text, p_target_member_id uuid DEFAULT NULL::uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
    v_caller uuid := auth.uid();
    v_target uuid := coalesce(p_target_member_id, v_caller);
    v_room uuid;
    v_max_seats integer;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    -- The event decides the room.
    select e.room_id into v_room
    from public.events e
    where e.id = p_event_id;

    if v_room is null then
        raise exception 'Event not found' using errcode = 'P0002';
    end if;

    if v_target <> v_caller then
        -- Host gate: only a host answers for another member.
        if not public.is_room_host(v_room, v_caller) then
            raise exception 'Only the host can update another member''s RSVP'
                using errcode = '42501';
        end if;
    else
        -- Member gate: only an active member answers for themselves.
        if not exists (
            select 1 from public.room_memberships m
            where m.room_id = v_room
              and m.user_id = v_caller
              and m.membership_status = 'active'
        ) then
            raise exception 'Not a member of this room' using errcode = '42501';
        end if;
    end if;

    -- Forfeit is terminal. A claim cannot take back the seat the host
    -- kept the deposit for. Declining or unclaiming is still allowed:
    -- the decision was about the seat, and stepping away from a night
    -- you were kept out of costs nobody anything.
    if p_state = 'claimed' and exists (
        select 1 from public.seat_deposits sd
        where sd.event_id = p_event_id
          and sd.user_id = v_caller
          and sd.status = 'forfeited'
    ) then
        raise exception 'forfeited_seat' using errcode = 'P0001';
    end if;

    -- Capacity. Only a claim can hit a full table; the caller who
    -- already holds a seat may always refresh it.
    if p_state = 'claimed' then
        select r.max_seats into v_max_seats
        from public.rooms r
        where r.id = v_room;

        perform 1 from public.events where id = p_event_id for update;

        if v_max_seats is not null and v_max_seats > 0
           and not exists (
               -- TARS fix: the seat that matters is the TARGET's, so a
               -- host claiming on a member's behalf is refused on a full
               -- night exactly like the member would be.
               select 1 from public.event_rsvps r
               where r.event_id = p_event_id
                 and r.member_id = v_target
                 and r.state = 'claimed'
           )
           and (
               select count(*)
               from public.event_rsvps r
               where r.event_id = p_event_id
                 and r.state = 'claimed'
                 and exists (
                   select 1 from public.room_memberships m
                   where m.room_id = r.room_id
                     and m.user_id = r.member_id
                     and m.membership_status = 'active'
                 )
           ) >= v_max_seats then
            raise exception 'night_full' using errcode = 'P0001';
        end if;
    end if;

    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room, v_target, p_state::event_rsvp_state, now())
    on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
end;
$function$;

revoke all on function public.upsert_event_rsvp(uuid, text, uuid) from public, anon;
grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated, service_role;

comment on function public.upsert_event_rsvp(uuid, text, uuid) is
  'S3.1 — answer for yourself or, as host, for another member. P0001 ''night_full'' when a claim would overfill the table; P0001 ''forfeited_seat'' when the caller''s deposit for this night was forfeited (a claim cannot undo the host''s decision).';

-- ---------------------------------------------------------------------------
-- 6. release_seat — 113's body plus the night_started gate (114's
--    pattern): once the night has started the host decides, not the
--    member changing their mind.
-- ---------------------------------------------------------------------------
create or replace function public.release_seat(p_event_id uuid, p_state text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_state is null or p_state not in ('unclaimed', 'declined') then
    raise exception 'bad_release_state' using errcode = '22023';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Member gate: only an active member releases their own seat.
  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id
      and m.user_id = v_caller
      and m.membership_status = 'active'
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- TARS fix: a started night is not releasable. The deposit's fate
  -- is the host's decision from the first minute of the night
  -- (085), so a member releasing after play began would refund the
  -- seat the host was about to keep. Same gate cancel_event uses
  -- (114): the host settles a started night instead.
  if exists (select 1 from public.events e where e.id = p_event_id and e.played_at <= now()) then
    raise exception 'night_started' using errcode = 'P0001';
  end if;

  -- The RSVP moves first: this is the member's own seat.
  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
  values (p_event_id, v_room_id, v_caller, p_state::public.event_rsvp_state, now())
  on conflict (event_id, member_id) do update set
    state = excluded.state,
    responded_at = excluded.responded_at;

  -- A held deposit returns exactly the way check_in_seat returns one.
  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is not null then
    update public.seat_deposits
      set status = 'returned', returned_at = now(), settled_at = now()
      where id = v_deposit.id;

    if v_deposit.amount > 0 then
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_room_id and user_id = v_caller;

      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_room_id, p_event_id, v_caller, 'seat_deposit_return', v_deposit.amount,
        jsonb_build_object('via', 'release', 'deposit_id', v_deposit.id),
        v_caller
      );
    end if;
  end if;

  return true;
end;
$$;

revoke all on function public.release_seat(uuid, text) from public, anon;
grant execute on function public.release_seat(uuid, text) to authenticated;

comment on function public.release_seat(uuid, text) is
  'S3.1 — member releases or declines their own seat: the RSVP moves to the given state and a held seat deposit returns to the balance in the same transaction (the check_in_seat return path). P0001 ''night_started'' once the night has begun.';

-- ---------------------------------------------------------------------------
-- 7. check_in_seat — the live body plus the too_early gate. The
--    client's own rule is played_at <= now (RoomDetailView shows the
--    "I'm here" button only for a started night, NightPlan.plan
--    offers no member action before it), so that is the line mirrored
--    here. Late check-ins stay allowed.
-- ---------------------------------------------------------------------------
create or replace function public.check_in_seat(p_event_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Check-in is a physical arrival. The button only exists once the
  -- night has started, so a client that fires earlier is stale; it
  -- must not void the host's arrival signal before the night begins.
  -- Five minutes of slack absorbs a phone clock running ahead of the
  -- server's, so a member tapping right at start time is never refused.
  if exists (select 1 from public.events e where e.id = p_event_id and e.played_at > now() + interval '5 minutes') then
    raise exception 'too_early' using errcode = 'P0001';
  end if;

  select sd.id, sd.room_id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- nothing held: already checked in, waived, or no deposit
  end if;

  update public.seat_deposits
    set status = 'returned', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_deposit.room_id and user_id = v_caller;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_deposit.room_id, p_event_id, v_caller, 'seat_deposit_return', v_deposit.amount,
      jsonb_build_object('via', 'check_in'),
      v_caller
    );
  end if;

  return true;
end;
$function$;

revoke all on function public.check_in_seat(uuid) from public, anon;
grant execute on function public.check_in_seat(uuid) to authenticated, service_role;

comment on function public.check_in_seat(uuid) is
  'V0.85 — member''s "I''m here" tap. Returns the held deposit to points_balance and stamps the row returned. The reclaim is the check-in: attendance records itself. Idempotent. P0001 ''too_early'' before the night starts.';

-- ---------------------------------------------------------------------------
-- 8. auto_close_stale_events — 081's body, with settled_at stamped at
--    played_at + the room's window instead of now(), so a long
--    stranded night is 'past' rather than a recap settled a second ago.
-- ---------------------------------------------------------------------------
create or replace function public.auto_close_stale_events(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_closed integer := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Member gate: the caller must belong to the room.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id and user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Close events whose night passed the room's window and were
  -- never settled. The window rides the room row so the host's
  -- Room Settings choice is the single source of truth.
  --
  -- settled_at is when the night CLOSED, not when this lazy call ran:
  -- played_at + the room's window. Stamping now() made a month-old
  -- night look like it settled two seconds ago, so it rendered as
  -- last night's recap with "plan the next night" seeded a week after
  -- the wrong date. With the true close time the same night reads
  -- 'past'.
  update public.events e
  set settled_at = e.played_at + make_interval(hours => r.auto_close_hours)
  from public.rooms r
  where e.room_id = p_room_id
    and e.settled_at is null
    and e.played_at < now() - make_interval(hours => r.auto_close_hours)
    and r.id = p_room_id;

  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

revoke all on function public.auto_close_stale_events(uuid) from public, anon;
grant execute on function public.auto_close_stale_events(uuid) to authenticated, service_role;

comment on function public.auto_close_stale_events(uuid) is
  'V0.83 — lazy, idempotent close of a night that was never settled: stamps settled_at at played_at + the room''s auto_close_hours (the moment the night stopped being live), not now(). A long-stranded night therefore reads as past, never as a fresh recap.';

-- ---------------------------------------------------------------------------
-- 9. One upcoming night per room, decided at write time.
--
--    012 declares a partial unique index whose predicate is now():
--
--        create unique index one_upcoming_event_per_room
--          on public.events(room_id) where played_at > now();
--
--    PostgreSQL refuses that statement outright — "functions in index
--    predicate must be marked IMMUTABLE" — so the frozen-now index has
--    never existed in any environment; the rule was hand-applied live
--    as trigger public.check_one_upcoming_event_per_room (23505).
--    A predicate evaluated at write time is what the rule needs, and
--    the trigger is that. This migration takes the live trigger's
--    name and function and tightens them: it now also ignores a night
--    that has been settled (a settled future row is not a pending
--    night), it only re-checks when a write actually moves the
--    schedule, and it raises P0001 'one_upcoming_night', the same
--    friendly-code shape as 'night_full' / 'night_started'.
-- ---------------------------------------------------------------------------
create or replace function public.check_one_upcoming_event_per_room()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Only a pending night can collide, and only a write that moves the
  -- schedule can create the collision. A rename or a note edit on an
  -- existing pending night (including on legacy data that a stricter
  -- rule could not retro-fix) is a no-op here.
  if new.played_at is null or new.settled_at is not null or new.played_at <= now() then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and new.played_at is not distinct from old.played_at
     and new.room_id is not distinct from old.room_id then
    return new;
  end if;

  if exists (
    select 1 from public.events e
    where e.room_id = new.room_id
      and e.id <> new.id
      and e.played_at > now()
      and e.settled_at is null
  ) then
    raise exception 'one_upcoming_night' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke all on function public.check_one_upcoming_event_per_room() from public, anon, authenticated;

drop trigger if exists trg_check_one_upcoming_event on public.events;
create trigger trg_check_one_upcoming_event
  before insert or update on public.events
  for each row
  when (new.played_at > now() and new.settled_at is null)
  execute function public.check_one_upcoming_event_per_room();

-- 012's index, if any environment ever managed to carry it (see above:
-- PostgreSQL refuses the statement). Dropping it here is the belt to
-- the trigger's braces, and a no-op where it never existed.
drop index if exists public.one_upcoming_event_per_room;

notify pgrst, 'reload schema';

commit;
