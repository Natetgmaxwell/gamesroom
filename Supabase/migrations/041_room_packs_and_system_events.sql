-- 041: M4 — Pack-as-platform polish.
--
-- Closes vision section 3.2 (two-level install) and section 3.3
-- closing line (pack install/uninstall surfaces in the room's
-- notification stream).
--
-- Adds three things:
--
--   1. room_packs — one row per (room, pack) indicating whether
--      the pack is installed in that room. The room never reaches
--      up to the global catalog; only enabled rows are visible.
--
--   2. update_room_packs(p_room_id, p_slugs text[]) — RPC that
--      replaces the room's pack set in a single call. Validates
--      every slug against public.packs; throws on invalid input.
--      Removes any open casino_withdrawals rows for packs that
--      are being uninstalled (since the room can no longer
--      settle them), and emits one room_system_events row per
--      removed pack so the in-app banner surfaces.
--
--   3. room_system_events — one row per room-scoped system event
--      (pack removed, season closed, etc.). The Briefing slot
--      reads unread rows from this table and renders the
--      appropriate banner. Powers the vision section 3.3 closing
--      line without needing push notifications (push during
--      play is banned per N-16).

-- =================================================================
-- 1. room_packs
-- =================================================================
create table if not exists public.room_packs (
    room_id uuid not null references public.rooms(id) on delete cascade,
    pack_slug text not null,
    enabled boolean not null default true,
    installed_at timestamptz not null default now(),
    primary key (room_id, pack_slug)
);
create index if not exists room_packs_room_id_idx on public.room_packs using btree (room_id);

alter table public.room_packs enable row level security;

-- Members of the room can read which packs are enabled. The
-- privacy boundary is the room itself — pack state is shared
-- knowledge across all members.
create policy "members can read room_packs"
    on public.room_packs for select
    using (
        exists (
            select 1 from public.room_memberships rm
            where rm.room_id = room_packs.room_id
              and rm.user_id = public.current_user_id()
        )
    );

-- Only the host can write room_packs.
create policy "host can write room_packs"
    on public.room_packs for all
    using (
        exists (
            select 1 from public.rooms r
            where r.id = room_packs.room_id
              and r.created_by = public.current_user_id()
        )
    )
    with check (
        exists (
            select 1 from public.rooms r
            where r.id = room_packs.room_id
              and r.created_by = public.current_user_id()
        )
    );

-- =================================================================
-- 2. room_system_events — in-app banner queue
-- =================================================================
create table if not exists public.room_system_events (
    id uuid primary key default gen_random_uuid(),
    room_id uuid not null references public.rooms(id) on delete cascade,
    kind text not null check (kind in ('pack_removed', 'season_closed', 'pack_installed')),
    payload jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    acknowledged_at timestamptz
);
create index if not exists room_system_events_room_idx
    on public.room_system_events using btree (room_id, acknowledged_at);

alter table public.room_system_events enable row level security;

-- Members can read room system events for their rooms.
create policy "members can read room system events"
    on public.room_system_events for select
    using (
        exists (
            select 1 from public.room_memberships rm
            where rm.room_id = room_system_events.room_id
              and rm.user_id = public.current_user_id()
        )
    );

-- Members can mark their own system events as acknowledged
-- (for the unread-counter path). Hosts write new rows via the
-- update_room_packs RPC.
create policy "members can acknowledge system events"
    on public.room_system_events for update
    using (
        exists (
            select 1 from public.room_memberships rm
            where rm.room_id = room_system_events.room_id
              and rm.user_id = public.current_user_id()
        )
    )
    with check (
        exists (
            select 1 from public.room_memberships rm
            where rm.room_id = room_system_events.room_id
              and rm.user_id = public.current_user_id()
        )
    );

-- =================================================================
-- 3. update_room_packs RPC
-- =================================================================
create or replace function public.update_room_packs(
    p_room_id uuid,
    p_slugs text[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_invalid_slug text;
    v_removed_slug text;
    v_caller uuid := public.current_user_id();
begin
    -- Caller must be the room's host.
    if not exists (
        select 1 from public.rooms r
        where r.id = p_room_id and r.created_by = v_caller
    ) then
        raise exception 'Only the host can update room packs' using errcode = '42501';
    end if;

    -- Validate every slug exists in the global packs catalog.
    select p.slug into v_invalid_slug
    from unnest(p_slugs) as p(slug)
    where not exists (select 1 from public.packs pk where pk.slug = p.slug)
    limit 1;
    if v_invalid_slug is not null then
        raise exception 'Unknown pack slug: %', v_invalid_slug using errcode = '22023';
    end if;

    -- Compute the set of slugs being uninstalled so we can clean
    -- up in-flight casino withdrawals and emit system events.
    for v_removed_slug in
        select rp.pack_slug
        from public.room_packs rp
        where rp.room_id = p_room_id
          and rp.enabled = true
          and rp.pack_slug <> all(p_slugs)
    loop
        -- For each removed pack, mark any open casino_withdrawals
        -- as settled_at=now so the SettleCasinoSheet doesn't
        -- surface a stale bracket.
        update public.casino_withdrawals cw
        set settled_at = now()
        where cw.event_id in (
            select id from public.events where room_id = p_room_id
        )
        and cw.settled_at is null
        and v_removed_slug = 'casino';

        -- Emit the system event for the briefing banner.
        insert into public.room_system_events (room_id, kind, payload)
        values (
            p_room_id,
            'pack_removed',
            jsonb_build_object('pack_slug', v_removed_slug)
        );
    end loop;

    -- Upsert the new pack set. Use a single statement so the
    -- enabled flag flips on/off atomically.
    insert into public.room_packs (room_id, pack_slug, enabled)
    select p_room_id, slug, true
    from unnest(p_slugs) as s(slug)
    on conflict (room_id, pack_slug) do update
        set enabled = true, installed_at = now();

    -- Disable any prior rows not in the new set.
    update public.room_packs rp
    set enabled = false
    where rp.room_id = p_room_id
      and rp.pack_slug <> all(p_slugs);
end;
$$;

grant execute on function public.update_room_packs(uuid, text[]) to authenticated;

comment on function public.update_room_packs(uuid, text[]) is
    'Replaces a room''s enabled pack set in a single call. Validates slugs against public.packs; emits one room_system_events row per removed pack so the briefing banner surfaces the change.';