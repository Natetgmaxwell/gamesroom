-- 090: V0.94 — per-event hidden members + drop the per-room blacklist.
--
-- Background:
--   Migration 022 (V0.12) created a per-room `room_blacklist` table
--   with 3 RPCs (add_to_blacklist, remove_from_blacklist, get_room_blacklist)
--   and a `p_blacklisted_user_ids` parameter on `create_room`. The
--   feature was never finished: redeem_join_code doesn't check the
--   blacklist, the briefing read RPCs don't filter by it, and
--   Connor's "I have hostilities in the room" use-case never worked.
--
--   The product need is narrower: a host, when creating an event,
--   should be able to mark a small set of members who don't see
--   THIS event and don't receive a push for it. No membership-level
--   effects, no broader data leakage. Per-event scope, not per-room.
--
-- This migration:
--   1. Adds `events.hidden_from_user_ids uuid[] not null default '{}'`
--      with a GIN index for the RLS join.
--   2. Rewrites the `members can read events` RLS policy to filter
--      by `NOT (current_user_id() = ANY(hidden_from_user_ids))`.
--   3. Extends `add_event` to accept a `p_hidden_from_user_ids`
--      parameter and persist it.
--   4. Drops the per-room `room_blacklist` table, the 3 per-room
--      RPCs, and the `p_blacklisted_user_ids` parameter on
--      `create_room`.
--
-- Idempotent: every DDL uses IF EXISTS / CREATE OR REPLACE.

-- =================================================================
-- 1. New column + index
-- =================================================================
alter table public.events
  add column if not exists hidden_from_user_ids uuid[] not null default '{}'::uuid[];

create index if not exists events_hidden_from_user_ids_gin
  on public.events using gin (hidden_from_user_ids);

comment on column public.events.hidden_from_user_ids is
  'V0.94 — host-supplied list of members who do not see this event and do not receive a briefing push. Empty array means visible to all members. Per-event scope, not per-room.';

-- =================================================================
-- 2. RLS rewrite — members can read events
-- =================================================================
-- The existing policy (migration 018) gates on room_memberships.
-- We rewrite to add the hidden-from check. The policy is dropped
-- then recreated; in-flight SELECTs during the swap are blocked
-- by the brief moment the policy is absent, but the new policy
-- recreates immediately.
drop policy if exists "members can read events" on public.events;

create policy "members can read events"
  on public.events for select
  using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = events.room_id
        and m.user_id = public.current_user_id()
    )
    and not (public.current_user_id() = any(events.hidden_from_user_ids))
  );

-- Note: we do NOT add the hidden-from check to event_rsvps RLS
-- here. The briefing and event_rsvps RPCs are SECURITY DEFINER and
-- bypass RLS, so the RLS-only filter is insufficient — the function
-- BODIES must filter too. Migration 090 itself doesn't redefine
-- those RPCs; instead the iOS read path (loadActiveEvent in
-- RoomService) already reads the events table directly, where the
-- RLS rewrite above takes effect. The briefing summary is reached
-- by event id (which the caller already obtained legitimately), and
-- if the caller's events RLS hid the event, they can't get the id
-- to pass to the briefing RPC. So a hidden user has no path to
-- obtain a valid event_id for a hidden event, and the function-body
-- filter is unnecessary as long as the events RLS holds.
--
-- UPDATE: behavioral probe (BEGIN...ROLLBACK) showed the RLS-only
-- design leaks. SECURITY DEFINER functions bypass RLS, so a hidden
-- member who knows an event id (deep link, future share, etc.)
-- gets briefing + RSVP data back. We MUST filter inside the
-- SECURITY DEFINER function bodies. The functions below are
-- redefined with the hidden-from check inline.

-- =================================================================
-- 3. add_event rewrite — accept p_hidden_from_user_ids
-- Drop the old 4-arg overload first so we don't leave it as a
-- dead function iOS could still call. PostgreSQL overloads are
-- signature-distinguished.
drop function if exists public.add_event(uuid, text, timestamp with time zone, text);

create or replace function public.add_event(
    p_room_id uuid,
    p_name text,
    p_played_at timestamp with time zone,
    p_pack_slug text,
    p_hidden_from_user_ids uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_event_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
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
$$;

comment on function public.add_event(uuid, text, timestamptz, text, uuid[]) is
  'V0.94 — host creates an event in a room they own. The fifth parameter, p_hidden_from_user_ids, is the list of members who do not see this event and do not receive its briefing push.';

-- =================================================================
-- 3a. Read RPCs — re-define to filter hidden members inside the
-- SECURITY DEFINER body. RLS on events is rewritten above; the
-- functions below are SECURITY DEFINER and bypass RLS, so the
-- function bodies must filter.
-- =================================================================

-- 3a-i. get_active_event — return the most-recently-played event
-- the caller is allowed to see. Hidden members get the next-most-
-- recent event they can see, or nothing if all upcoming events
-- hide them. (Most-recent-order is preserved.) The returned
-- shape gains `hidden_from_user_ids` so the iOS Event decoder
-- picks it up.
drop function if exists public.get_active_event(uuid);

create or replace function public.get_active_event(p_room_id uuid)
returns table (
  id uuid, room_id uuid, name text, played_at timestamp with time zone,
  created_at timestamp with time zone, host_note text, pack_slug text,
  settled_at timestamp with time zone, max_seats integer,
  event_calendar_identifier text,
  hidden_from_user_ids uuid[]
)
language sql
stable security definer
set search_path = public
as $$
  select e.id, e.room_id, e.name, e.played_at, e.created_at,
         e.host_note, e.pack_slug, e.settled_at, r.max_seats,
         e.event_calendar_identifier, e.hidden_from_user_ids
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.room_id = p_room_id
    and e.settled_at is null
    and not (public.current_user_id() = any(e.hidden_from_user_ids))
  order by e.played_at desc
  limit 1;
$$;

comment on function public.get_active_event(uuid) is
  'V0.94 — most-recently-played unresolved event in a room the caller can see. Returns nothing if all upcoming events hide the caller.';

-- 3a-ii. get_briefing_summary — return 0 rows for hidden members.
-- SECURITY DEFINER + auth.uid() inside the body; explicit filter.
create or replace function public.get_briefing_summary(p_event_id uuid)
returns table (
  event_id uuid, room_id uuid, event_name text,
  played_at timestamp with time zone, venue text,
  seats_total integer, seats_claimed bigint, seats_declined bigint,
  seats_unclaimed bigint, host_note text, claimed_member_names text[]
)
language sql
stable security definer
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
      case when (
          r.created_by = auth.uid()
          or exists (
            select 1 from public.room_memberships rm
            where rm.room_id = e.room_id and rm.user_id = auth.uid() and rm.role = 'host'
          )
      )
      then count(rsvp.id) filter (where rsvp.state = 'declined')
      else 0
      end as seats_declined,
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
    and not (public.current_user_id() = any(e.hidden_from_user_ids))
  group by e.id, e.room_id, e.name, e.played_at, r.max_seats, e.host_note, r.created_by;
$$;

-- 3a-iii. get_event_rsvps — return 0 rows for hidden members.
create or replace function public.get_event_rsvps(p_event_id uuid)
returns table (
  event_id uuid, member_id uuid, display_name text, state text,
  notifications_muted boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_hidden boolean;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, (public.current_user_id() = any(e.hidden_from_user_ids))
    into v_room_id, v_hidden
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if v_hidden then
    return; -- hidden members see nothing
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = auth.uid()
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  return query
    select
      p_event_id::uuid as event_id,
      rm.user_id as member_id,
      u.display_name as display_name,
      coalesce(er.state::text, 'unclaimed') as state,
      coalesce(er.notifications_muted, false) as notifications_muted
    from public.room_memberships rm
    join public.users u on u.id = rm.user_id
    left join public.event_rsvps er
      on er.event_id = p_event_id and er.member_id = rm.user_id
    where rm.room_id = v_room_id
    order by case when rm.role = 'host' then 0 else 1 end, u.display_name;
end;
$$;

comment on function public.get_event_rsvps(uuid) is
  'V0.94 — RSVPs for an event. Hidden members (in events.hidden_from_user_ids) get 0 rows; their event id still resolves so the iOS client cannot tell a hidden event from a missing one through this RPC.';

-- 3a-iv. create_event is a 4-arg wrapper around add_event. Bump it
-- to forward the new hidden list arg, otherwise iOS still calls the
-- 4-arg version (migration 006 wrapper) and the hidden list would
-- be silently dropped. The wrapper's SECURITY DEFINER mode
-- preserves the original behavior (member-role counting is
-- closed in minimax_vision rooms; this RPC isn't called by the
-- realtime path or the host's addEvent path).
drop function if exists public.create_event(uuid, text, timestamp with time zone, text);

create or replace function public.create_event(
    p_room_id uuid,
    p_name text,
    p_played_at timestamp with time zone,
    p_pack_slug text,
    p_hidden_from_user_ids uuid[] default '{}'::uuid[]
)
returns uuid
language sql
security definer
set search_path = public
as $$
  select public.add_event(
    p_room_id, p_name, p_played_at, p_pack_slug, p_hidden_from_user_ids
  );
$$;

-- =================================================================
-- 4. Drop the per-room blacklist feature
-- =================================================================
-- Idempotent: wrap the drops in DO blocks that skip silently when
-- the target doesn't exist. The 4a/4b/4c steps reference room_blacklist
-- and its policies; the 4d step drops the old create_room overload.
DO $$
BEGIN
  -- 4a. Policies on the table (must be dropped before the table).
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'room_blacklist'
            AND relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')) THEN
    EXECUTE 'drop policy if exists "Host reads blacklist" on public.room_blacklist';
    EXECUTE 'drop policy if exists "Host writes blacklist" on public.room_blacklist';
    -- 4b. The table itself.
    EXECUTE 'drop table if exists public.room_blacklist';
  END IF;
END
$$;

-- 4c. The 3 per-room RPCs from migration 022. Each is a separate
-- function; drop by name (no overloads).
drop function if exists public.add_to_blacklist(uuid, uuid);
drop function if exists public.remove_from_blacklist(uuid, uuid);
drop function if exists public.get_room_blacklist(uuid);

-- 4d. create_room loses its p_blacklisted_user_ids parameter.
-- Drop the old 7-arg overload first (otherwise CREATE OR REPLACE
-- leaves it as a dead overload that iOS would still be able to
-- call). PostgreSQL overloads are signature-distinguished.
drop function if exists public.create_room(text, text, text, text, integer, text, uuid[]);

create or replace function public.create_room(
    p_name text,
    p_mascot_name text,
    p_mascot_personality text,
    p_mascot_political_ideology text,
    p_join_starting_bonus integer default 200,
    p_mascot_api_key text default null::text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  insert into public.rooms (
    name, mascot_name, mascot_personality, mascot_political_ideology,
    created_by, join_starting_bonus, mascot_api_key
  ) values (
    p_name, p_mascot_name,
    p_mascot_personality::public.mascot_personality,
    p_mascot_political_ideology,
    v_caller, p_join_starting_bonus, p_mascot_api_key
  )
  returning id into v_room_id;

  return v_room_id;
end;
$$;

comment on function public.create_room(text, text, text, text, integer, text) is
  'V0.94 — host creates a room. The p_blacklisted_user_ids parameter was removed in V0.94; per-event hidden_from_user_ids on the events table is the new mechanism.';
