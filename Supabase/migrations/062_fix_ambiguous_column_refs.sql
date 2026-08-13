-- 062: Fix ambiguous column references in upsert_event_rsvp + set_room_pack_config.
--
-- ROOT CAUSE: plpgsql RETURNS TABLE creates output column variables that shadow
-- table columns of the same name inside the function body. No amount of table
-- alias qualification fully resolves this — the variable is still in scope.
--
-- FIX: Change both functions to return void. The iOS client re-fetches the
-- data (RSVPs, briefing, pack configs) after mutation via the V0.39 refresh
-- fix, so the server doesn't need to echo the row back. This eliminates the
-- RETURNS TABLE declaration entirely, removing the variable shadowing.

-- 1. upsert_event_rsvp — returns void
drop function if exists public.upsert_event_rsvp(uuid, text, uuid);
create function public.upsert_event_rsvp(
    p_event_id uuid,
    p_state text,
    p_target_member_id uuid default null
)
returns void
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
        select e.room_id into v_room
        from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = p_event_id and r.created_by = v_caller;
        if v_room is null then
            raise exception 'Only the host can update another member''s RSVP'
                using errcode = '42501';
        end if;
    else
        select e.room_id into v_room
        from public.events e
        where e.id = p_event_id;
    end if;

    if v_room is null then
        raise exception 'Event not found' using errcode = 'P0002';
    end if;

    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room, v_target, p_state::event_rsvp_state, now())
    on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
end;
$$;

grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated;

-- 2. set_room_pack_config — returns void
drop function if exists public.set_room_pack_config(uuid, text, integer);
create function public.set_room_pack_config(
    p_room_id uuid,
    p_pack_slug text,
    p_win_points integer
)
returns void
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
end;
$$;

grant execute on function public.set_room_pack_config(uuid, text, integer) to authenticated;

notify pgrst, 'reload schema';
