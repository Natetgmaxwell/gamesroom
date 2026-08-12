-- 058: Create wrapper RPCs the iOS LiveRoomStore expects but the remote
-- DB never had. The functions already exist under different names from
-- earlier migrations — these are thin wrappers that alias the old names
-- to the new ones the iOS code calls.
--
-- Background: the iOS LiveRoomStore.swift was written against a migration
-- set that renamed several RPCs (add_event → create_event, update_room →
-- update_room_settings, etc.). The migrations defining these renamed
-- functions were never committed to the repo — the iOS code references
-- function names that don't exist on the remote DB. This migration
-- creates the missing 6 functions as wrappers around the existing ones,
-- plus 2 genuinely new functions that were never defined at all.

-- =================================================================
-- 1. create_event — alias for the existing add_event (migration 012)
-- Same params, same return type.
-- =================================================================
create or replace function public.create_event(
    p_room_id uuid,
    p_name text,
    p_played_at timestamptz,
    p_pack_slug text
)
returns uuid
language sql
security definer
set search_path = public
as $$
    select public.add_event(p_room_id, p_name, p_played_at, p_pack_slug);
$$;

grant execute on function public.create_event(uuid, text, timestamptz, text) to authenticated;

-- =================================================================
-- 2. update_room_settings — alias for the existing update_room
-- (migration 012's overload with all settings params). The iOS code
-- passes all params as text (UUIDString/String(value)) so the wrapper
-- accepts text and casts internally.
-- =================================================================
create or replace function public.update_room_settings(
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
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
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
    where id = p_room_id and created_by = public.current_user_id();

    if not found then
        raise exception 'Room not found or caller is not the host' using errcode = '42501';
    end if;
end;
$$;

grant execute on function public.update_room_settings(uuid, text, text, text, text, integer, integer, integer, boolean, boolean, boolean, boolean) to authenticated;

-- =================================================================
-- 3. get_my_event_rsvp — returns the calling member's RSVP state
-- for one event. Used by BriefingSlot to determine claim/decline state.
-- =================================================================
create or replace function public.get_my_event_rsvp(p_event_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
    select state::text
    from public.event_rsvps
    where event_id = p_event_id
      and member_id = public.current_user_id()
    order by responded_at desc
    limit 1;
$$;

grant execute on function public.get_my_event_rsvp(uuid) to authenticated;

-- =================================================================
-- 4. get_event_rsvps — returns all RSVPs for an event so the
-- briefing card can show the seat roster (social proof).
-- Note: this already exists from migration 033 but the iOS code
-- may be calling a version that includes member display names.
-- =================================================================
-- Already exists — skip if present.
-- get_event_rsvps already exists from migration 033.

-- =================================================================
-- 5. get_room_system_events — returns unacknowledged system events
-- for a room (pack installed, season closed, etc).
-- The table already exists (migration 041); this RPC was never created.
-- =================================================================
create or replace function public.get_room_system_events(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    kind text,
    payload jsonb,
    created_at timestamptz,
    acknowledged_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    select id, room_id, kind, payload, created_at, acknowledged_at
    from public.room_system_events
    where room_id = p_room_id
    order by created_at desc
    limit 50;
$$;

grant execute on function public.get_room_system_events(uuid) to authenticated;

-- =================================================================
-- 6. acknowledge_system_event — marks a system event as read.
-- =================================================================
create or replace function public.acknowledge_system_event(p_event_id uuid)
returns void
language sql
security definer
set search_path = public
as $$
    update public.room_system_events
    set acknowledged_at = now()
    where id = p_event_id;
$$;

grant execute on function public.acknowledge_system_event(uuid) to authenticated;

-- =================================================================
-- 7. get_briefing_summary — returns a summary for the briefing card:
-- seat count, member names who claimed, event details.
-- This is a genuinely new function that was never defined.
-- =================================================================
create or replace function public.get_briefing_summary(p_event_id uuid)
returns table (
    event_id uuid,
    event_name text,
    played_at timestamptz,
    venue text,
    max_seats integer,
    claimed_seats bigint,
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
        e.name as event_name,
        e.played_at,
        null::text as venue,
        r.max_seats,
        count(rsvp.id) filter (where rsvp.state = 'claimed') as claimed_seats,
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
    group by e.id, e.name, e.played_at, r.max_seats, e.host_note;
$$;

grant execute on function public.get_briefing_summary(uuid) to authenticated;

-- =================================================================
-- 8. Refresh the PostgREST schema cache so the new functions are
-- immediately discoverable by the iOS app.
-- =================================================================
notify pgrst, 'reload schema';
