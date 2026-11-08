-- =================================================================
-- 107 — Night lifecycle: active-event priority + settle_event
-- =================================================================
--
-- What changed and why
-- --------------------
-- 1. get_active_event / get_active_event__inner are dropped and
--    recreated.
--
--    063 fixed "the room page cannot show a night once it has
--    started": the old predicate `played_at > now()` made an event
--    vanish from the server the moment it began, so the live card,
--    the withdraw CTA, the witness screen and the recap were all
--    unreachable. 092 regressed that fix while widening the return
--    shape with pack_slugs, and 106 wrapped 092's body as
--    get_active_event__inner behind a membership guard without
--    restoring the predicate. The live RPC therefore still returns
--    future events only: a started night disappears at start time, a
--    settled night never comes back, and the per-event hidden list
--    (090) and the calendar identifier (087) were lost with it.
--
--    The recreated inner picks exactly ONE row, in this priority:
--      (i)   live    - played_at <= now(), settled_at is null and
--                     started inside the room's auto-close window
--                     (rooms.auto_close_hours, default 8h). The
--                     latest start wins.
--      (ii)  settled - settled_at within the last 24h. The latest
--                     settled_at wins. This is the row the recap
--                     (Ceremonial Card) reads.
--      (iii) future  - the next scheduled night, soonest first.
--    Every branch hides an event whose hidden_from_user_ids list
--    contains the caller.
--
--    The return shape keeps the live columns and adds back
--    hidden_from_user_ids (090) and event_calendar_identifier (087).
--
-- 2. settle_event(p_event_id) is new: the host closes the night.
--    Host-only (is_room_host), live-only (played_at <= now() and
--    settled_at is null, else P0001 'not_live'), stamps settled_at
--    and returns it. Until now the only writer of settled_at was the
--    lazy auto_close_stale_events (080/081), so the recap, the Live
--    Activity end and the next-night prompt had no signal to hang on.
--
-- Deposits
-- ---------
-- settle_event stamps settled_at and touches nothing else. The seat
-- deposit escrow (085) returns a member's held deposit on that
-- member's own "I'm here" tap (check_in_seat) or on the first play
-- transaction for the event (the transactions_auto_return_deposit
-- trigger, public.auto_return_on_settle, live body in
-- docs/audit/2026-11-08/live-functions.sql:43-90). That trigger is
-- AFTER INSERT on public.transactions, so it does not fire on an
-- UPDATE of events.settled_at - settling the night is not a play
-- transaction. That is deliberate: a member who neither checked in
-- nor played is a no-show, and 085 reserves the forfeit decision for
-- the host ("the host always decides; the system never decides
-- alone"). Handing a no-show's deposit back at settle time would
-- quietly take that decision away from the host.
--
-- Apply via:
--   psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/107_night_lifecycle.sql
--
-- Post-apply verification:
--   select pg_get_functiondef('public.get_active_event__inner'::regproc);
--   select pg_get_functiondef('public.settle_event'::regproc);
-- =================================================================

begin;

-- =================================================================
-- 1. get_active_event__inner — one row, three-branch priority.
--    Dropped first: the RETURNS TABLE column list changes (42P13).
-- =================================================================

drop function if exists public.get_active_event(uuid);
drop function if exists public.get_active_event__inner(uuid);

create function public.get_active_event__inner(p_room_id uuid)
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

  -- (ii) The night we just finished. Settled within the last 24h so
  --      the recap shows up tonight and is gone tomorrow. Latest
  --      settle wins.
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
  if found then
    return;
  end if;

  -- (iii) The next night. Soonest first.
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
end;
$$;

revoke all on function public.get_active_event__inner(uuid) from public, anon, authenticated;

comment on function public.get_active_event__inner(uuid) is
  'V1.24 — the one event a room page should show: the live night (started, unsettled, inside the room''s auto-close window), else the night settled in the last 24h, else the next scheduled night. Hidden members never see the events they are hidden from. Reads the live column set plus hidden_from_user_ids and event_calendar_identifier.';

-- =================================================================
-- 2. get_active_event — the membership-guarded wrapper. The guard
--    is the live one (106) unchanged; only the column list moved.
-- =================================================================

create function public.get_active_event(p_room_id uuid)
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
  if not (public.rpc_caller_trusted() or public.is_room_member(p_room_id, public.current_user_id())) then
    return;
  end if;
  return query select * from public.get_active_event__inner(p_room_id);
end;
$$;

revoke all on function public.get_active_event(uuid) from public, anon;
grant execute on function public.get_active_event(uuid) to authenticated, service_role;

comment on function public.get_active_event(uuid) is
  'V1.24 — the room''s live night, last night''s recap, or next scheduled night, for members of the room. Restores the 063 live-event semantics that 092 regressed and the 087/090 columns that 092 dropped.';

-- =================================================================
-- 3. settle_event — the host closes the night.
-- =================================================================

create function public.settle_event(p_event_id uuid)
returns timestamp with time zone
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_played_at timestamp with time zone;
  v_settled_at timestamp with time zone;
  v_new_settled_at timestamp with time zone;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- FOR UPDATE: two hosts tapping settle at once must not both stamp
  -- the night. The second call waits, then reads the settled row and
  -- fails with 'not_live'.
  select e.room_id, e.played_at, e.settled_at
    into v_room_id, v_played_at, v_settled_at
  from public.events e
  where e.id = p_event_id
  for update;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not public.is_room_host(v_room_id, v_caller) then
    raise exception 'Only the host can settle the night' using errcode = '42501';
  end if;

  -- A night can only be settled once it has started and while it is
  -- still open.
  if v_settled_at is not null or v_played_at > now() then
    raise exception 'not_live' using errcode = 'P0001';
  end if;

  update public.events
    set settled_at = now()
    where id = p_event_id
    returning settled_at into v_new_settled_at;

  return v_new_settled_at;
end;
$$;

revoke all on function public.settle_event(uuid) from public, anon;
grant execute on function public.settle_event(uuid) to authenticated;

comment on function public.settle_event(uuid) is
  'V1.24 — host-only. Stamps events.settled_at for a live night (played_at <= now(), settled_at is null) and returns the settle time. Raises P0001 ''not_live'' for a night that has not started or is already settled, and 42501 for a caller who is not a host of the room. Deposits are not touched: they come back through check_in_seat or a play transaction (085).';

-- =================================================================
-- 4. Refresh the PostgREST schema cache.
-- =================================================================

notify pgrst, 'reload schema';

commit;
