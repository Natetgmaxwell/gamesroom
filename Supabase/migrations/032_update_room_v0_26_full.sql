-- 032: Round-trip the V0.26 room-level feature toggles through update_room.
--
-- Why this exists
-- ---------------
-- Migration 026 added the briefing_48h_enabled, calendar_auto_add_host,
-- social_preferences_enabled, and social_narration_enabled columns to
-- public.rooms, and the iOS app (RoomService.updateRoom, RoomSettingsSheet)
-- already passes them in the Encodable payload. But update_room itself was
-- never extended, so PostgREST returns:
--   Could not find the function public.update_room(p_briefing_48h_enabled, p_calendar_auto_add_host, ...)
-- because no overload matches the full 13-parameter shape. The hosts cannot
-- edit any of these settings until update_room writes them.
--
-- Pattern (matches 021_mascot_api_key.sql): drop + create because CREATE OR
-- REPLACE refuses when the parameter shape changes. New overload appends the
-- four toggles as default 'true' / 'false' so existing call sites keep
-- working — but the canonical 13-param signature is the new shape.

drop function if exists public.update_room(
  uuid, text, text, public.mascot_personality, int, int, text, integer, text
);

create function public.update_room(
  p_room_id                    uuid,
  p_name                       text,
  p_mascot_name                text,
  p_mascot_personality         public.mascot_personality,
  p_member_invite_quota        int,
  p_max_seats                  int,
  p_mascot_political_ideology  text              default 'centrist',
  p_join_starting_bonus        integer           default 200,
  p_mascot_api_key             text              default null,
  p_briefing_48h_enabled       boolean           default true,
  p_calendar_auto_add_host     boolean           default false,
  p_social_preferences_enabled boolean           default true,
  p_social_narration_enabled   boolean           default true
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can edit the room' using errcode = '42501';
  end if;

  if p_join_starting_bonus < 0 then
    raise exception 'join_starting_bonus must be >= 0' using errcode = '23514';
  end if;

  update public.rooms
  set name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality,
      member_invite_quota = p_member_invite_quota,
      max_seats = p_max_seats,
      mascot_political_ideology = p_mascot_political_ideology,
      join_starting_bonus = p_join_starting_bonus,
      mascot_api_key = p_mascot_api_key,
      briefing_48h_enabled = p_briefing_48h_enabled,
      calendar_auto_add_host = p_calendar_auto_add_host,
      social_preferences_enabled = p_social_preferences_enabled,
      social_narration_enabled = p_social_narration_enabled,
      updated_at = now()
  where id = p_room_id;

  return true;
end;
$$;

grant execute on function public.update_room(
  uuid, text, text, public.mascot_personality, int, int,
  text, integer, text, boolean, boolean, boolean, boolean
) to authenticated;

-- Verify probe. Run as the host user; ROLLBACK so no persistent state.
-- Imports a probe via /dev/stdin-friendly file at the end if needed.
