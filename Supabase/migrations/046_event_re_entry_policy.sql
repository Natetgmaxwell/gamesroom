-- 046: V0.9 Wave 1 Slice 1.2 — Decline re-entry RLS (host override).
--
-- Migration 033 already has an `event_rsvps_update_self` policy
-- (member can update their own row). Migration 046 adds a
-- `event_rsvps_update_host` policy so the host can also update a
-- member's RSVP. The host's existing `events` write authority
-- already covers marking the event settled; this fills the gap
-- for host-driven RSVP changes (e.g. forcing a declined member
-- back to unclaimed if the host wants to re-open RSVP for that
-- event).
--
-- The iOS-side change (Wave 1 Slice 1.2) is purely UX: a member
-- who has declined can re-accept or re-decline through the same
-- `upsert_event_rsvp` RPC. The server-side write already works
-- because the existing update-self policy covers the member's own
-- row. The new host policy is additive.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/046_event_re_entry_policy.sql

-- Host can update any RSVP row in their room.
do $$ begin
  create policy "event_rsvps_update_host"
    on public.event_rsvps
    for update
    using (
      exists (
        select 1 from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = event_rsvps.event_id
          and r.created_by = auth.uid()
      )
    )
    with check (
      exists (
        select 1 from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = event_rsvps.event_id
          and r.created_by = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- The host-side override is also exposed at the RPC level. The
-- existing `upsert_event_rsvp(p_event_id, p_state)` RPC is already
-- self-gated: SECURITY DEFINER, with the row's own member_id
-- enforced via the existing update-self policy. To support the
-- host path, redefine upsert_event_rsvp to accept an optional
-- target member id (NULL = self-write, non-NULL = host write of
-- another member's RSVP). The RPC validates the caller is the
-- event's host when p_target_member_id is non-NULL.
create or replace function public.upsert_event_rsvp(
  p_event_id uuid,
  p_state text,
  p_target_member_id uuid default null
)
returns table (
  event_id uuid,
  member_id uuid,
  state text,
  responded_at timestamptz
)
language plpgsql
security definer
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
    select er.event_id, er.member_id, er.state, er.responded_at
    from public.event_rsvps er
    where er.event_id = p_event_id and er.member_id = v_target;
end;
$$;

grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated;
