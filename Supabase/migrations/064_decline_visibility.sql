-- 064: Decline visibility — hide declined RSVPs from non-host members.
--
-- User feedback: "When someone can't make it, only show who can't make it
-- to the hosts, not general members."
--
-- Declining is a social signal, not public data. The host needs it for
-- logistics; other members don't. Two RPCs leaked declined state to every
-- room member:
--
--   1. get_event_rsvps — returned every member's RSVP state (claimed,
--      declined, unclaimed) to any room member. Now: hosts see all rows;
--      members see only claimed rows plus their own row (so their own
--      declined state is never hidden from them).
--
--   2. get_briefing_summary — returned seats_declined to everyone. Now:
--      hosts see the real declined count; members get 0. The member's
--      seatsLeft derivation (seatsTotal - seatsClaimed - seatsDeclined)
--      then treats declined seats as available, which is correct — a
--      declined seat is genuinely open to claim.
--
-- Host = room creator (rooms.created_by) OR a room_memberships row with
-- role='host'. Enforced server-side so a member cannot fetch declined
-- data by calling the RPC directly.

-- =================================================================
-- 1. get_event_rsvps — host sees all, member sees claimed + own
-- =================================================================
create or replace function public.get_event_rsvps(p_event_id uuid)
returns table (
  event_id uuid,
  member_id uuid,
  display_name text,
  state text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_caller uuid := auth.uid();
  v_is_host boolean;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Caller must be a member of the event's room.
  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Host = room creator OR a membership row with role='host'.
  select
    (r.created_by = v_caller)
    or exists (
      select 1 from public.room_memberships rm
      where rm.room_id = v_room_id and rm.user_id = v_caller and rm.role = 'host'
    )
  into v_is_host
  from public.rooms r
  where r.id = v_room_id;

  return query
    select
      p_event_id::uuid as event_id,
      rm.user_id as member_id,
      u.display_name as display_name,
      coalesce(er.state::text, 'unclaimed') as state
    from public.room_memberships rm
    join public.users u on u.id = rm.user_id
    left join public.event_rsvps er
      on er.event_id = p_event_id and er.member_id = rm.user_id
    where rm.room_id = v_room_id
      -- Members see only claimed rows plus their own row. Hosts see all.
      and (v_is_host or coalesce(er.state::text, 'unclaimed') = 'claimed' or rm.user_id = v_caller)
    order by case when rm.role = 'host' then 0 else 1 end, u.display_name;
end;
$$;

grant execute on function public.get_event_rsvps(uuid) to authenticated;

-- =================================================================
-- 2. get_briefing_summary — seats_declined host-only
-- =================================================================
create or replace function public.get_briefing_summary(p_event_id uuid)
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
    group by e.id, e.room_id, e.name, e.played_at, r.max_seats, e.host_note, r.created_by;
$$;

grant execute on function public.get_briefing_summary(uuid) to authenticated;

notify pgrst, 'reload schema';
