# STATE S2B

STATE: step 1 of 7 done. Next: step 2 (109 briefing push SQL).

Step 1 (S2B.1: rooms.time_zone + set_room_time_zone) committed as 4187809.
- Supabase/migrations/108_room_time_zone.sql (new): rooms.time_zone text not null default 'Australia/Brisbane' (add column if not exists, comment on column).
- public.set_room_time_zone(p_room_id uuid, p_tz text) returns void, plpgsql, volatile, security definer, set search_path = public. Host only via public.is_room_host(id, current_user_id()) on a live room row (rooms.deleted_at is null); unknown zone rejected with 22023 against pg_catalog.pg_timezone_names; 42501 for a non-host; P0002 if the room row vanished. revoke all from public, anon; grant execute to authenticated.
- Not applied to live. Gate: bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases passed, parse-check pass=64). No function directory touched, so no deno gate this step.
- Deliberate choices: the host guard uses is_room_host only (never rooms.created_by, per 095 and the brief); a soft-deleted room cannot be moved; updated_at is written alongside the column (rooms_set_updated_at trigger exists, so this is belt and braces).

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
