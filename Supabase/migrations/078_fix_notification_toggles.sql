-- 078: Fix the two dead V0.54 notification toggles.
--
-- Bug class: migration 066 shipped two RPCs with runtime-fatal
-- defects that surface as silently-dead UI toggles:
--
--   1. `set_notifications_enabled` was `language sql` + `stable`
--      while containing an UPDATE. Postgres rejects UPDATE inside
--      a non-volatile SQL function at call time (0A000), so every
--      "Remind me about this room's nights" tap returned a 400
--      that the client swallowed — the toggle flipped and snapped
--      back. Fix: `volatile` (writes require volatility).
--
--   2. `set_event_notifications_muted` INSERT path omitted
--      `room_id`, a NOT NULL column on event_rsvps. The upsert's
--      insert branch (the common case: caller has no RSVP row yet,
--      e.g. a freshly created event) died with 23502. Fix: derive
--      room_id from the event server-side and include it.
--
-- Both defects were verified live (JWT-simulated caller, rolled
-- back) before this migration was written.

-- =================================================================
-- 1. set_notifications_enabled — volatile
-- =================================================================
create or replace function public.set_notifications_enabled(
  p_room_id uuid,
  p_enabled boolean
)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
begin
  if public.current_user_id() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.room_memberships m
    set notifications_enabled = p_enabled
    where m.room_id = p_room_id
      and m.user_id = public.current_user_id();

  if not found then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;
end;
$$;

-- =================================================================
-- 2. set_event_notifications_muted — room_id-scoped upsert
-- =================================================================
create or replace function public.set_event_notifications_muted(
  p_event_id uuid,
  p_muted boolean
)
returns void
language plpgsql
security definer
volatile
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
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

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  insert into public.event_rsvps (event_id, room_id, member_id, state, notifications_muted)
  values (p_event_id, v_room_id, v_caller, 'unclaimed', p_muted)
  on conflict (event_id, member_id) do update set
    notifications_muted = excluded.notifications_muted;
end;
$$;
