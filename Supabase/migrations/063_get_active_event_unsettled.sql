-- 063: get_active_event — return most recent UNSETTLED event, not just upcoming.
--
-- The old filter `played_at > now()` meant an event that had started
-- (played_at <= now()) disappeared from the room page entirely — no
-- live state, no withdraw CTA, no witness screen. The client's V0State
-- machine already handles live events (`.tonightEvent` / `.inPlay` /
-- `.settleRound`); the RPC just never returned them.
--
-- Fix: return the most recent unsettled event (played_at desc). The
-- client decides briefing vs witness based on played_at <= Date().

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
    max_seats integer
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
      and e.settled_at is null
    order by e.played_at desc
    limit 1;
$$;

grant execute on function public.get_active_event(uuid) to authenticated;

notify pgrst, 'reload schema';
