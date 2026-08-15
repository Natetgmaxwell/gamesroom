-- 073: fix settings-save 42702 + persist host chip dispensing.
--
-- Background:
--   * update_room_settings / update_host_journal declare RETURNS TABLE
--     columns (id, name, ...) that shadow the rooms table columns inside
--     PL/pgSQL, so `update ... where id = p_room_id` fails with
--     42702 "column reference id is ambiguous" for EVERY caller. Settings
--     have been un-saveable since 061 rewrote these functions into the
--     RETURNS TABLE shape. Fix: alias every table reference (r.id etc.)
--     so PL/pgSQL variables never shadow columns.
--   * Host "Chips to dispense" acknowledgement was client-only @State.
--     Persist it: mark_withdrawal_dispensed stamps the withdrawal's meta
--     with {dispensed: true}; get_event_transactions keeps returning the
--     rows (ledger unchanged) and the client filters on meta.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/073_fix_settings_save_and_dispense.sql

-- =====================================================================
-- 1. update_room_settings — de-shadowed UPDATE ... WHERE
-- =====================================================================
create or replace function public.update_room_settings(
    p_room_id uuid,
    p_name text,
    p_mascot_name text,
    p_mascot_personality text,
    p_mascot_political_ideology text,
    p_max_seats integer,
    p_member_invite_quota integer,
    p_join_starting_bonus integer,
    p_social_narration_enabled boolean,
    p_briefing_48h_enabled boolean,
    p_calendar_auto_add_host boolean,
    p_social_preferences_enabled boolean
) returns table (
    id uuid,
    name text,
    mascot_name text,
    mascot_personality mascot_personality,
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
) language plpgsql
security definer
set search_path = 'public'
as $$
declare
    v_caller uuid := public.current_user_id();
    v_updated boolean := false;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    update public.rooms as r set
        name = p_name,
        mascot_name = p_mascot_name,
        mascot_personality = p_mascot_personality::mascot_personality,
        mascot_political_ideology = p_mascot_political_ideology,
        max_seats = p_max_seats,
        member_invite_quota = p_member_invite_quota,
        join_starting_bonus = p_join_starting_bonus,
        social_narration_enabled = p_social_narration_enabled,
        briefing_48h_enabled = p_briefing_48h_enabled,
        calendar_auto_add_host = p_calendar_auto_add_host,
        social_preferences_enabled = p_social_preferences_enabled,
        updated_at = now()
    where r.id = p_room_id and r.created_by = v_caller
    returning true into v_updated;

    if v_updated is not true then
        raise exception 'Room not found or caller is not the host' using errcode = '42501';
    end if;

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

grant execute on function public.update_room_settings(uuid, text, text, text, text, integer, integer, integer, boolean, boolean, boolean, boolean) to authenticated;

-- =====================================================================
-- 2. update_host_journal — same de-shadowing
-- =====================================================================
create or replace function public.update_host_journal(
    p_room_id uuid,
    p_journal text
) returns table (
    id uuid,
    name text,
    mascot_name text,
    mascot_personality mascot_personality,
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
) language plpgsql
security definer
set search_path = 'public'
as $$
declare
    v_caller uuid := public.current_user_id();
    v_normalised_journal text;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if not exists (select 1 from public.rooms r
                   where r.id = p_room_id and r.created_by = v_caller) then
        raise exception 'Only the host can edit the room journal' using errcode = '42501';
    end if;

    v_normalised_journal := case
        when p_journal is null then null
        when btrim(p_journal) = '' then null
        else btrim(p_journal)
    end;

    if v_normalised_journal is not null
       and char_length(v_normalised_journal) > 280 then
        raise exception 'host_journal must be <= 280 characters' using errcode = '22023';
    end if;

    update public.rooms as r
    set host_journal = v_normalised_journal,
        updated_at = now()
    where r.id = p_room_id;

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

-- =====================================================================
-- 3. mark_withdrawal_dispensed — persistent host acknowledgement
-- =====================================================================

-- Returns the updated transactions rows for the event so the caller can
-- refresh its list in one round-trip. Host-only: the caller must be the
-- host of the room that owns the event the transaction belongs to.
create or replace function public.mark_withdrawal_dispensed(
    p_transaction_id uuid
) returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare
    v_caller uuid := public.current_user_id();
    v_event_id uuid;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    select t.session_id into v_event_id
    from public.transactions t
    where t.id = p_transaction_id
      and t.kind = 'casino_withdrawal';

    if v_event_id is null then
        raise exception 'Withdrawal not found' using errcode = '42501';
    end if;

    if not exists (
        select 1
        from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = v_event_id
          and r.created_by = v_caller
    ) then
        raise exception 'Only the host can mark chips dispensed' using errcode = '42501';
    end if;

    update public.transactions as t
    set meta = coalesce(t.meta, '{}'::jsonb)
             || jsonb_build_object('dispensed', true, 'dispensed_at', now())
    where t.id = p_transaction_id;
end;
$$;

grant execute on function public.mark_withdrawal_dispensed(uuid) to authenticated;
