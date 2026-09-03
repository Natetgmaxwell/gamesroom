-- 092: Multi-pack event creation + pack-aware active-event reads (V0.95 G).
--
-- Product direction (Nathan, 2026-09-02): event creation picks MULTIPLE
-- packs; in-play surfaces (CAH card counting, host score entry for
-- single-winner card games, casino withdraw) may only appear for packs
-- actually selected on the event. Room-level pack enablement stays as the
-- offer list; the event's selection is the gate.
--
-- The junction table (event_packs, migration 020) and the multi-pack RPC
-- (add_event_with_packs, 020) already exist but the app never adopted
-- them: iOS creates events via create_event (058/090, single p_pack_slug).
--
-- This migration:
--   1. Redefines create_event to take p_pack_slugs text[] (plus the
--      V0.94 hidden-members list), validate against the catalog, write
--      event + junction rows in one statement. pack_slug (legacy single
--      column) keeps the FIRST slug so every existing single-pack read
--      (WitnessSlot isCAH etc.) stays meaningful.
--   2. Redefines get_active_event to also return pack_slugs — the app's
--      Event decoder gains packSlugs and gates surfaces per event
--      instead of per room.
--
-- Apply via:
--   supabase db push  (or psql -f against the pooler)
--
-- Post-apply verification:
--   select proname, pg_get_function_arguments(oid) from pg_proc
--     where proname in ('create_event','get_active_event');

-- =================================================================
-- 1. create_event — multi-pack + hidden members.
-- =================================================================
drop function if exists public.create_event(uuid, text, timestamp with time zone, text);
drop function if exists public.create_event(uuid, text, timestamp with time zone, text, uuid[]);

create or replace function public.create_event(
    p_room_id uuid,
    p_name text,
    p_played_at timestamp with time zone,
    p_pack_slugs text[],
    p_hidden_from_user_ids uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_event_id uuid;
    v_caller uuid := public.current_user_id();
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.rooms
        where id = p_room_id and created_by = v_caller
    ) then
        raise exception 'Only the host can create events' using errcode = '42501';
    end if;
    if p_pack_slugs is null or array_length(p_pack_slugs, 1) = 0 then
        raise exception 'At least one pack required' using errcode = '22023';
    end if;
    if exists (
        select 1 from unnest(p_pack_slugs) as s(slug)
        where not exists (select 1 from public.packs where slug = s.slug)
    ) then
        raise exception 'Unknown pack in p_pack_slugs' using errcode = 'P0002';
    end if;

    insert into public.events (room_id, name, played_at, pack_slug, created_by)
    values (p_room_id, p_name, p_played_at, p_pack_slugs[1], v_caller)
    returning id into v_event_id;

    insert into public.event_packs (event_id, pack_slug)
    select v_event_id, unnest(p_pack_slugs);

    -- V0.94 hidden members ride along unchanged.
    update public.events
    set hidden_from_user_ids = p_hidden_from_user_ids
    where id = v_event_id;

    return v_event_id;
end;
$$;

grant execute on function public.create_event(uuid, text, timestamptz, text[], uuid[]) to authenticated;

-- =================================================================
-- 2. get_active_event — add pack_slugs to the return shape.
--    (Dropped + recreated: the RETURNS TABLE column list changed, 42P13.)
-- =================================================================
drop function if exists public.get_active_event(uuid);

create or replace function public.get_active_event(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamptz,
    created_at timestamptz,
    host_note text,
    pack_slug text,
    settled_at timestamptz,
    max_seats int,
    pack_slugs text[]
)
language sql
stable
security definer
set search_path = public
as $$
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at > now()
    order by e.played_at asc
    limit 1;
$$;

grant execute on function public.get_active_event(uuid) to authenticated;

-- =================================================================
-- 3. Refresh the PostgREST schema cache.
-- =================================================================
notify pgrst, 'reload schema';
