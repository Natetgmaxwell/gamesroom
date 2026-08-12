-- 062b: Fix output column names — the out_ prefix from 062 broke client decoding.
-- The iOS client (MemberRSVP, RoomPackConfig) expects specific column names.
-- This restores the original column names and fixes the ambiguity differently:
-- by qualifying the self-write SELECT with table alias, NOT by renaming output columns.

-- 1. upsert_event_rsvp — restore original output names, keep qualified internal refs
drop function if exists public.upsert_event_rsvp(uuid, text, uuid);
create function public.upsert_event_rsvp(
    p_event_id uuid,
    p_state text,
    p_target_member_id uuid default null
)
returns table (
    id uuid,
    event_id uuid,
    room_id uuid,
    member_id uuid,
    state text,
    responded_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_caller uuid := auth.uid();
    v_target uuid := coalesce(p_target_member_id, v_caller);
    v_room uuid;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if v_target <> v_caller then
        -- Host writing another member's RSVP
        select e.room_id into v_room
        from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = p_event_id and r.created_by = v_caller;
        if v_room is null then
            raise exception 'Only the host can update another member''s RSVP'
                using errcode = '42501';
        end if;
    else
        -- Self-write: use table alias to avoid RETURNS TABLE column ambiguity
        select e.room_id into v_room
        from public.events e
        where e.id = p_event_id;
    end if;

    if v_room is null then
        raise exception 'Event not found' using errcode = 'P0002';
    end if;

    if p_state not in ('claimed', 'tentative', 'declined', 'unclaimed') then
        raise exception 'Invalid RSVP state: %', p_state using errcode = '22000';
    end if;

    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room, v_target, p_state, now())
    on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;

    return query
        select er.id, er.event_id, er.room_id, er.member_id, er.state::text, er.responded_at
        from public.event_rsvps er
        where er.event_id = p_event_id and er.member_id = v_target;
end;
$$;

grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated;


-- 2. set_room_pack_config — restore original output names
drop function if exists public.set_room_pack_config(uuid, text, integer);
create function public.set_room_pack_config(
    p_room_id uuid,
    p_pack_slug text,
    p_win_points integer
)
returns table (
    room_id uuid,
    pack_slug text,
    win_points integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_caller uuid := public.current_user_id();
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.rooms r
        where r.id = p_room_id and r.created_by = v_caller
    ) then
        raise exception 'Only the host can configure pack payouts' using errcode = '42501';
    end if;

    if not exists (
        select 1 from public.packs p where p.slug = p_pack_slug
    ) then
        raise exception 'Unknown pack: %', p_pack_slug using errcode = 'P0002';
    end if;

    if p_win_points < 0 then
        raise exception 'win_points must be >= 0' using errcode = '22000';
    end if;

    insert into public.room_pack_configs (room_id, pack_slug, win_points)
    values (p_room_id, p_pack_slug, p_win_points)
    on conflict (room_id, pack_slug) do update set
        win_points = excluded.win_points,
        updated_at = now();

    return query
        select rpc.room_id, rpc.pack_slug, rpc.win_points
        from public.room_pack_configs rpc
        where rpc.room_id = p_room_id and rpc.pack_slug = p_pack_slug;
end;
$$;

grant execute on function public.set_room_pack_config(uuid, text, integer) to authenticated;

notify pgrst, 'reload schema';
