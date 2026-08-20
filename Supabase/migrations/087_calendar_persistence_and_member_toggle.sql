-- 087: V0.86 — server-side calendar persistence + per-member toggle (2026-08-20).
--
-- The host's `rooms.calendar_auto_add_host` toggle was per-room and
-- died with the device — the EventKit identifier was stored in
-- UserDefaults keyed by event UUID, and iOS event UUIDs are not stable
-- across reinstalls. The toggle persisted server-side but the
-- identifier map died: writes looked like they succeeded but update /
-- delete couldn't find the EKEvent row. User directive: "Auto-add to
-- host calendar keeps turning off every time I rebuild the app.
-- Extend to members too — calendar solidifies the event."
--
-- Locked design: a SINGLE per-user toggle (NOT per-room), applies to
-- every room the member is in. The host toggle is REMOVED entirely —
-- the calendar mirror is now purely a member-comfort feature.
--
-- Changes:
--   1. events: add event_calendar_identifier text (nullable). The
--      EventKit row identifier that maps back to the server event id.
--      Null = never written to any calendar.
--   2. rooms: DROP calendar_auto_add_host column and its CHECK
--      constraint (created in 026/082/084/086).
--   3. room_memberships: add calendar_auto_add boolean (per-user
--      toggle, applies to every room the member is in). Migration 026
--      added calendar_auto_add_member (dormant) on the same table —
--      rename it forward so the column the iOS code targets is the
--      one the server surface returns.
--   4. update_room_settings: drop the 16-arg (086) version, recreate
--      as 15-arg (no p_calendar_auto_add_host). 42P13 pattern — DROP
--      before CREATE.
--   5. New RPCs (idempotent, guarded):
--      set_member_calendar_auto_add(p_enabled boolean) — caller
--      writes their own room_memberships.calendar_auto_add. Per the
--      spec: this is a SINGLE per-user toggle, applies to every
--      room. The RPC is parameterless on room_id on purpose.
--      report_calendar_identifier(p_event_id uuid, p_identifier text)
--      — called by the iOS client after a successful EKEvent.save()
--      so the server knows which EventKit row belongs to this event.
--      Idempotent (upsert).
--   6. get_active_event: extend the return shape to include
--      event_calendar_identifier so clients can pick up an existing
--      identifier when editing an event.
--   7. get_my_rooms: drop calendar_auto_add_host from the return
--      shape (column gone).
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/087_calendar_persistence_and_member_toggle.sql
--
-- Post-apply verification:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='events'
--     and column_name = 'event_calendar_identifier';
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='room_memberships'
--     and column_name = 'calendar_auto_add';
--   select pg_get_function_arguments('public.update_room_settings(uuid,text,text,text,text,integer,integer,integer,boolean,boolean,boolean,integer,integer,text,integer)'::regprocedure);
--   select pg_get_function_arguments('public.set_member_calendar_auto_add(boolean)'::regprocedure);
--   select pg_get_function_arguments('public.report_calendar_identifier(uuid,text)'::regprocedure);

-- =================================================================
-- 1. events.event_calendar_identifier — the EventKit row id that
--    maps back to the server event. Nullable; null = never written.
-- =================================================================
alter table public.events
    add column if not exists event_calendar_identifier text;

-- =================================================================
-- 2. rooms.calendar_auto_add_host is GONE. Drop its CHECK first
--    (026/082/084/086 may have named it differently — drop the
--    plausible names defensively), then the column itself.
-- =================================================================
alter table public.rooms drop constraint if exists rooms_calendar_auto_add_host_check;
alter table public.rooms drop constraint if exists rooms_calendar_auto_add_host_range;
alter table public.rooms drop column if exists calendar_auto_add_host;

-- =================================================================
-- 3. room_memberships.calendar_auto_add — per-user toggle. The 026
--    migration added calendar_auto_add_member (dormant); rename it
--    forward so the iOS code's column name matches what the server
--    surface returns. Idempotent per-column guards so a re-run is
--    safe (rename fails hard when the target already exists).
-- =================================================================
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'room_memberships'
      and column_name = 'calendar_auto_add_member'
  ) and not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'room_memberships'
      and column_name = 'calendar_auto_add'
  ) then
    alter table public.room_memberships
      rename column calendar_auto_add_member to calendar_auto_add;
  end if;
end $$;

-- Add the column if neither path landed (fresh DB). Default false
-- (calendar mirror is opt-in, quiet-by-default per the substrate).
alter table public.room_memberships
    add column if not exists calendar_auto_add boolean not null default false;

-- =================================================================
-- 4. update_room_settings — DROP the 086 16-arg overload, recreate
--    as 15-arg (no p_calendar_auto_add_host). 42P13 — cannot CREATE
--    OR REPLACE across an argument-count change.
-- =================================================================
drop function if exists public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, integer,
    integer, text, integer
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
    p_social_preferences_enabled boolean,
    p_auto_close_hours integer,
    p_seat_deposit_amount integer,
    p_seat_deposit_trigger text,
    p_seat_deposit_grace_minutes integer
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
    social_preferences_enabled boolean,
    social_narration_enabled boolean,
    max_seats integer,
    member_invite_quota integer,
    host_journal text,
    auto_close_hours integer,
    seat_deposit_amount integer,
    seat_deposit_trigger text,
    seat_deposit_grace_minutes integer
)
language plpgsql
security definer
set search_path = public
as $$
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
  where r.id = p_room_id and r.created_by = v_caller
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
$$;

grant execute on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, integer,
    integer, text, integer
) to authenticated;

comment on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, integer,
    integer, text, integer
) is 'V0.86 — host-only room settings update. 15-arg signature: the per-room calendar_auto_add_host toggle is gone (V0.86 moved calendar mirroring to a per-user surface). Carries V0.83 auto-close window + V0.85 seat-deposit escrow settings (amount, trigger escrow|off, grace). Returns the full Room row.';

-- =================================================================
-- 5a. set_member_calendar_auto_add(p_enabled boolean) — caller
--     writes their own room_memberships.calendar_auto_add for EVERY
--     room they're in. Per the V0.86 spec this is a single per-user
--     toggle, applies to every room — no room_id parameter. The RPC
--     updates all rows for the caller (one user can be in many rooms).
-- =================================================================
create or replace function public.set_member_calendar_auto_add(p_enabled boolean)
returns void
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

  update public.room_memberships
    set calendar_auto_add = p_enabled,
        updated_at = now()
    where user_id = v_caller;
end;
$$;

grant execute on function public.set_member_calendar_auto_add(boolean) to authenticated;

comment on function public.set_member_calendar_auto_add(boolean) is 'V0.86 — caller flips their own room_memberships.calendar_auto_add across EVERY room they belong to (per-user toggle, NOT per-room). Idempotent.';

-- =================================================================
-- 5b. report_calendar_identifier(p_event_id, p_identifier) — called
--     by the iOS client after a successful EKEvent.save() so the
--     server knows which EventKit row belongs to this event.
--     Idempotent (upsert via plain UPDATE — events.id is the PK).
-- =================================================================
create or replace function public.report_calendar_identifier(
  p_event_id uuid,
  p_identifier text
)
returns void
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

  update public.events
    set event_calendar_identifier = p_identifier
    where id = p_event_id;
end;
$$;

grant execute on function public.report_calendar_identifier(uuid, text) to authenticated;

comment on function public.report_calendar_identifier(uuid, text) is 'V0.86 — caller reports the EventKit row identifier for one of their room''s events so the server can map back to the EKEvent on update/delete. Idempotent (no-op when the event id is unknown to the RLS-gated row).';

-- =================================================================
-- 6. get_active_event — widen the return shape to include
--    event_calendar_identifier so clients can pick up an existing
--    identifier when editing an event (the V0.86 flow needs to look
--    it up, not store it locally). DROP first because the RETURNS
--    TABLE column list changes (42P13).
-- =================================================================
drop function if exists public.get_active_event(uuid);
create function public.get_active_event(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamptz,
    created_at timestamptz,
    host_note text,
    pack_slug text,
    settled_at timestamptz,
    max_seats integer,
    event_calendar_identifier text
)
language sql
stable
security definer
set search_path = public
as $$
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.settled_at is null
    order by e.played_at desc
    limit 1;
$$;

grant execute on function public.get_active_event(uuid) to authenticated;

comment on function public.get_active_event(uuid) is 'V0.86 — most recent UNSETTLED event for the room (063 semantics) widened with event_calendar_identifier so the iOS CalendarService can pick up an existing EventKit row id when the event is edited. Migration 012 + 060 + 063 lineage.';

-- =================================================================
-- 7. get_my_rooms — drop calendar_auto_add_host (the column is
--    gone). Also surface the caller''s own calendar_auto_add flag so
--    the iOS settings UI can render the toggle state without a
--    separate fetch. DROP+CREATE because the RETURNS TABLE column
--    list changes (42P13).
-- =================================================================
drop function if exists public.get_my_rooms();
create function public.get_my_rooms()
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
  mascot_api_key text,
  user_role text,
  member_drowning_opt_in boolean,
  notifications_enabled boolean,
  overlap_count bigint,
  overlap_names text[],
  auto_close_hours integer,
  seat_deposit_amount integer,
  seat_deposit_trigger text,
  seat_deposit_grace_minutes integer,
  calendar_auto_add boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    r.join_starting_bonus,
    r.mascot_api_key,
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in,
    coalesce(m.notifications_enabled, false) as notifications_enabled,
    ov.overlap_count,
    ov.overlap_names,
    r.auto_close_hours,
    r.seat_deposit_amount,
    r.seat_deposit_trigger,
    r.seat_deposit_grace_minutes,
    coalesce(m.calendar_auto_add, false) as calendar_auto_add
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  left join lateral (
    select
      count(distinct other.user_id) as overlap_count,
      array_agg(distinct u.display_name) filter (where u.display_name is not null) as overlap_names
    from public.room_memberships other
    join public.room_memberships shared
      on shared.user_id = other.user_id
     and shared.room_id <> r.id
    join public.users u on u.id = other.user_id
    where other.room_id = r.id
      and other.user_id <> m.user_id
      and exists (
        select 1 from public.room_memberships mine
        where mine.user_id = m.user_id
          and mine.room_id = shared.room_id
      )
  ) ov on true
  where m.user_id = public.current_user_id()
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

comment on function public.get_my_rooms() is 'V0.86 — caller''s rooms. Surfaces member_drowning_opt_in / notifications_enabled / calendar_auto_add per-row (all coalesce to false). No more rooms.calendar_auto_add_host — that toggle is gone (V0.86).';

-- =================================================================
-- 8. Refresh the PostgREST schema cache so the new return shapes
--    are immediately visible to the iOS app.
-- =================================================================
notify pgrst, 'reload schema';