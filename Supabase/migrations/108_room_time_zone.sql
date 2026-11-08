-- 108: rooms gain a time zone.
--
-- Lane S2B step 1. The server-side push work (briefing push, anchor nudge,
-- question box) has to say "Friday" and "at 7:30pm" in the room's own clock,
-- and it has to know when a person is awake. Until now the only clock on the
-- server was the audit finding 01-notifications #13: the anchor push
-- hardcoded Australia/Brisbane in the edge function regardless of where the
-- room actually is.
--
-- What this migration adds
--   1. rooms.time_zone text not null default 'Australia/Brisbane'.
--      IANA name. Brisbane is the default because it is where the first
--      rooms live; a host moves their room to their own zone.
--   2. public.set_room_time_zone(p_room_id uuid, p_tz text) returns void.
--      Host only (is_room_host, migration 095: active host-role membership,
--      never rooms.created_by). Rejects a zone that is not in
--      pg_timezone_names (22023) so a typo cannot silently park a room in
--      a zone that does not exist and shift every reminder.
--
-- Rooms are soft-deleted (migration 052), so a dead room cannot be moved
-- and reads keep working.
--
-- NOT applied to live. Written and gated here; the orchestrator applies it
-- after Nathan's sign-off, before 109-112 (they read this column):
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/108_room_time_zone.sql
--
-- Idempotent: add-column-if-not-exists, create-or-replace.
-- Rollback: drop function public.set_room_time_zone(uuid, text);
-- alter table public.rooms drop column time_zone;
begin;

-- =================================================================
-- 1. Column
-- =================================================================
alter table public.rooms
  add column if not exists time_zone text not null default 'Australia/Brisbane';

comment on column public.rooms.time_zone is
  'S2B: IANA time zone for this room. Server-side pushes (briefing, anchor nudge, question box) read it to compute local times, weekdays and waking hours. Set by the host via set_room_time_zone.';

-- =================================================================
-- 2. Host-only setter
-- =================================================================
create or replace function public.set_room_time_zone(
  p_room_id uuid,
  p_tz text
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $body$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Host check on the live room row. is_room_host is the canonical guard
  -- (095): active host-role membership, not rooms.created_by.
  if not exists (
    select 1 from public.rooms
    where id = p_room_id
      and deleted_at is null
      and public.is_room_host(id, v_caller)
  ) then
    raise exception 'Only the host can set the room time zone' using errcode = '42501';
  end if;

  -- The zone has to exist. Postgres resolves an unknown zone at runtime
  -- with the server default, which would quietly move every reminder.
  if not exists (
    select 1 from pg_catalog.pg_timezone_names where name = p_tz
  ) then
    raise exception 'Unknown time zone: %', p_tz using errcode = '22023';
  end if;

  update public.rooms
    set time_zone = p_tz,
        updated_at = now()
    where id = p_room_id
      and deleted_at is null;

  if not found then
    raise exception 'Room not found' using errcode = 'P0002';
  end if;
end;
$body$;

revoke all on function public.set_room_time_zone(uuid, text) from public, anon;
grant execute on function public.set_room_time_zone(uuid, text) to authenticated;

comment on function public.set_room_time_zone(uuid, text) is
  'S2B: host-only. Sets rooms.time_zone. The zone must exist in pg_timezone_names. Server-side push scheduling (109/110/111) reads this column.';

notify pgrst, 'reload schema';

commit;
