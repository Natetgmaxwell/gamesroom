-- 060: get_active_event — widen the return shape to the full Event row
-- so the iOS `Event` decoder (which now reads `id`, `room_id`, `name`,
-- `played_at`, `created_at`, `host_note`, `pack_slug`, `settled_at`,
-- `max_seats`) can decode the RPC without throwing.
--
-- Background: the iOS `RoomStore.fetchActiveEvent` decodes the result as
-- `[Event]` (see GamesRoom/Services/RoomStore.swift). Migration 012
-- returned only the 6-column summary (`event_id, name, played_at,
-- seat_count, max_seats, pack_slug, scoring_type`), which made
-- `Event.init(from:)` throw on the missing `id` / `room_id` /
-- `created_at` keys and left `activeEventByRoom` nil — so a freshly
-- created event disappeared from the room page.
--
-- This migration redefines `get_active_event(p_room_id)` to return the
-- full row shape (`id, room_id, name, played_at, created_at, host_note,
-- pack_slug, settled_at, max_seats`). WHERE/ORDER/LIMIT semantics are
-- preserved exactly (upcoming event, earliest first). `seat_count` and
-- `scoring_type` are dropped because no client consumer decodes them
-- from this RPC — seat totals come from `get_briefing_summary` (migration
-- 058) and the scoring type is implicit in the pack.
--
-- DROP first because the RETURNS TABLE column list changed (42P13).

-- =================================================================
-- 1. Drop the old (6-column) get_active_event.
-- =================================================================
drop function if exists public.get_active_event(uuid);

-- =================================================================
-- 2. Recreate get_active_event with the full Event-shaped return.
-- =================================================================
create or replace function public.get_active_event(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamptz,
    created_at timestamptz,
    host_note text,
    pack_slug text,
    settled_at timestamptz,
    max_seats int
)
language sql
stable
security definer
set search_path = public
as $$
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at > now()
    order by e.played_at asc
    limit 1;
$$;

grant execute on function public.get_active_event(uuid) to authenticated;

-- =================================================================
-- 3. Refresh the PostgREST schema cache so the new return shape is
-- immediately visible to the iOS app.
-- =================================================================
notify pgrst, 'reload schema';