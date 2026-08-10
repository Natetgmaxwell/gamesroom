-- 050: W2.4 — member-side event edit RPC.
--
-- Members can edit the event's pre-play note + venue within the
-- allowed window (before play starts). Room scope derives from
-- `events.id` (F-IDENT-01) — never from the caller's membership
-- claim. Host-only RPCs (update_event_played_at, delete_event,
-- migration 022) are untouched; this is the member-side complement.
--
-- Adds:
--   1. update_event_member_fields(p_event_id, p_note, p_venue) —
--      any room member may set the event's host_note + venue while
--      the event is still in the future. Empty strings clear the
--      field. The host can also use it (hosts are members).

create or replace function public.update_event_member_fields(
  p_event_id uuid,
  p_note text,
  p_venue text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_played_at timestamptz;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- F-IDENT-01: room scope derives from the event, never from the
  -- caller's membership claim.
  select room_id, played_at into v_room_id, v_played_at
  from public.events
  where id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Only room members can edit event details' using errcode = '42501';
  end if;

  if v_played_at <= now() then
    raise exception 'Event details can only be edited before play starts' using errcode = '22023';
  end if;

  update public.events
    set host_note = nullif(trim(p_note), ''),
        venue = nullif(trim(p_venue), '')
  where id = p_event_id;

  return true;
end;
$$;

grant execute on function public.update_event_member_fields(uuid, text, text) to authenticated;

comment on function public.update_event_member_fields(uuid, text, text) is
  'Any room member may edit the event''s pre-play note + venue while the event is in the future. Room scope derives from the event (F-IDENT-01). Empty strings clear the field.';
