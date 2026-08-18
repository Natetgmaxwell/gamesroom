-- 080: Auto-close stale events (V0.82).
--
-- Bug class: nothing ever stamps events.settled_at. The host's
-- finalize path (finalize_casino_session) closes attestations but
-- never the event; get_active_event filters settled_at is null, so
-- every event stays "active" forever and the post-play ceremonial
-- card (.justSettled, settledAt within 24h) is unreachable.
--
-- Fix: a lazy, idempotent RPC that stamps settled_at on events
-- whose night has passed (played_at + 24h grace) and were never
-- settled by the host. The client fires it throttled (once per
-- 60s per room) from loadActiveEvent, mirroring the existing
-- close_stale_attestations lazy pattern — there is no pg_cron on
-- this project, so the close rides the app's natural read path.
--
-- Semantics:
--   - settled_at = the "completed/archived" marker. get_active_event
--     drops the event once stamped; the ceremonial card renders for
--     the following 24h; the room then returns to standings.
--   - 24h grace after played_at: the night is over, the morning
--     after arrives, the event closes. Hosts who finalize at the
--     table still get the lazy close the next day (the finalize
--     path itself is a separate follow-up).
--   - Member-gated (any room member may trigger; the write only
--     touches their room's events). Idempotent: re-runs are no-ops.
--
-- Live-verified 2026-08-17 before drafting: events table has
-- settled_at timestamptz nullable; no pg_cron extension; the app
-- calls get_active_event on every room open.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/080_auto_close_stale_events.sql
--
-- Post-apply verification:
--   select proname from pg_proc where proname = 'auto_close_stale_events';

create or replace function public.auto_close_stale_events(p_room_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_closed integer := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Member gate: the caller must belong to the room.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id and user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Close events whose night passed 24h ago and were never settled.
  update public.events
  set settled_at = now()
  where room_id = p_room_id
    and settled_at is null
    and played_at < now() - interval '24 hours';

  get diagnostics v_closed = row_count;
  return v_closed;
end;
$$;

grant execute on function public.auto_close_stale_events(uuid) to authenticated;
