-- 036: Host observation journal column + RPC.
--
-- The P1.5 host-operations polish. A single bounded free-text
-- field on the room row, host-editable only, surfaced off the main
-- path on Room Settings. Bounded to 280 chars (same as the V0.26
-- events.host_note cap) so the host can't ship a multi-page essay
-- into a field that the iOS form renders in a 2-line vertical
-- text field.
--
-- Why a new RPC
-- -------------
-- The existing `update_room(...)` RPC (migration 032) takes 13
-- parameters; threading a 14th through it would force every other
-- caller to pass a value (or accept a default that nulls the
-- column). A focused RPC keeps the journal write path minimal and
-- makes future per-field edits cheap.

-- 1. New column. Nullable so legacy rows render with no journal.
alter table public.rooms
  add column if not exists host_journal text
  check (host_journal is null or char_length(host_journal) <= 280);

-- 2. update_host_journal: host-only write of the journal field.
--    Reads back the room row so the iOS wrapper can mirror the
--    persisted value without a follow-up read.
create or replace function public.update_host_journal(
  p_room_id uuid,
  p_journal text
)
returns table (
  id uuid,
  name text,
  mascot_name text,
  mascot_personality public.mascot_personality,
  mascot_political_ideology text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  is_live boolean,
  next_event_description text,
  join_starting_bonus integer,
  user_role text,
  briefing_48h_enabled boolean,
  calendar_auto_add_host boolean,
  social_preferences_enabled boolean,
  social_narration_enabled boolean,
  max_seats integer,
  member_invite_quota integer,
  host_journal text
)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_normalised_journal text;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (select 1 from public.rooms
                 where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can edit the room journal' using errcode = '42501';
  end if;

  -- Empty / whitespace-only journal → NULL. Lets the host clear
  -- the field by submitting a blank value without forcing a
  -- server-side "non-empty" rejection.
  v_normalised_journal := case
    when p_journal is null then null
    when btrim(p_journal) = '' then null
    else btrim(p_journal)
  end;

  if v_normalised_journal is not null
     and char_length(v_normalised_journal) > 280 then
    raise exception 'host_journal must be <= 280 characters' using errcode = '22023';
  end if;

  update public.rooms
    set host_journal = v_normalised_journal,
        updated_at = now()
    where id = p_room_id;

  return query
    select
      r.id, r.name, r.mascot_name, r.mascot_personality,
      r.mascot_political_ideology,
      r.created_by, r.created_at, r.updated_at, r.is_live,
      r.next_event_description,
      r.join_starting_bonus,
      m.role::text as user_role,
      r.briefing_48h_enabled,
      r.calendar_auto_add_host,
      r.social_preferences_enabled,
      r.social_narration_enabled,
      r.max_seats,
      r.member_invite_quota,
      r.host_journal
    from public.rooms r
    join public.room_memberships m on m.room_id = r.id
    where r.id = p_room_id and m.user_id = v_caller;
end;
$$;

grant execute on function public.update_host_journal(uuid, text) to authenticated;

-- 3. get_my_rooms: extend the RETURNS TABLE with host_journal so
--    the iOS Room decoder finds the column. DROP + CREATE because
--    Postgres refuses CREATE OR REPLACE when the row shape
--    differs (same constraint as migrations 018 + 020).
drop function if exists public.get_my_rooms();
create function public.get_my_rooms()
returns table (
  id uuid,
  name text,
  mascot_name text,
  mascot_personality public.mascot_personality,
  mascot_political_ideology text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  is_live boolean,
  next_event_description text,
  join_starting_bonus integer,
  user_role text,
  briefing_48h_enabled boolean,
  calendar_auto_add_host boolean,
  social_preferences_enabled boolean,
  social_narration_enabled boolean,
  max_seats integer,
  member_invite_quota integer,
  host_journal text
)
language sql
security definer
stable
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live,
    r.next_event_description,
    r.join_starting_bonus,
    m.role::text as user_role,
    r.briefing_48h_enabled,
    r.calendar_auto_add_host,
    r.social_preferences_enabled,
    r.social_narration_enabled,
    r.max_seats,
    r.member_invite_quota,
    r.host_journal
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;