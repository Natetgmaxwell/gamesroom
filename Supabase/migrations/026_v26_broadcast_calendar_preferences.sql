-- V0.26: Broadcast, Briefing, Calendar, Preferences, Mascot Narration
-- Applied 2026-07-27

-- Room-level feature toggles
alter table public.rooms
    add column if not exists briefing_48h_enabled boolean not null default true,
    add column if not exists calendar_auto_add_host boolean not null default false,
    add column if not exists social_preferences_enabled boolean not null default true,
    add column if not exists social_narration_enabled boolean not null default true;

-- Event columns
alter table public.events
    add column if not exists briefing_message text check (
        briefing_message is null or char_length(briefing_message) <= 140
    ),
    add column if not exists host_note text check (
        host_note is null or char_length(host_note) <= 280
    );

-- Member columns (note: the Felt Faction schema uses `room_memberships`,
-- not `members`. This was an error in the original spec; corrected 2026-07-27
-- when applying the migration to live Supabase.)
alter table public.room_memberships
    add column if not exists calendar_auto_add_member boolean not null default false,
    add column if not exists preferences_social text check (
        preferences_social is null or char_length(preferences_social) <= 140
    ),
    add column if not exists preferences_conversation_prompt text check (
        preferences_conversation_prompt is null or char_length(preferences_conversation_prompt) <= 280
    ),
    add column if not exists preferences_default_set boolean not null default false;

-- Supporting RPCs (used by iOS app for social preferences read/write)
-- These were applied 2026-07-27 in /tmp/026_rpcs.sql alongside this migration.
-- The RPCs are listed here for documentation; re-running this migration
-- on a fresh database would create them.

-- create or replace function public.upsert_member_preferences(
--     p_room_id uuid,
--     p_user_id uuid,
--     p_social text,
--     p_conversation_prompt text,
--     p_default_set boolean
-- ) returns void as $$
-- begin
--     update public.room_memberships
--     set preferences_social = p_social,
--         preferences_conversation_prompt = p_conversation_prompt,
--         preferences_default_set = p_default_set,
--         updated_at = now()
--     where room_id = p_room_id and user_id = p_user_id;
-- end;
-- $$ language plpgsql security definer;

-- create or replace function public.get_member_notes(p_room_id uuid)
-- returns jsonb as $$
--     select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb)
--     from (
--         select rm.user_id, u.display_name, rm.preferences_social, rm.preferences_conversation_prompt
--         from public.room_memberships rm
--         join public.users u on u.id = rm.user_id
--         where rm.room_id = p_room_id
--           and (rm.preferences_social is not null or rm.preferences_conversation_prompt is not null)
--     ) t;
-- $$ language sql stable security definer;

-- grant execute on function public.upsert_member_preferences(uuid, uuid, text, text, boolean) to authenticated;
-- grant execute on function public.get_member_notes(uuid) to authenticated;
