-- 089: pack-toggle fix — rewrite room_packs to match the live schema.
--
-- Live `public.room_packs` is from migration 013 (presence-based:
-- row exists = pack installed; row absent = pack not in room).
-- There is no `enabled` column.
--
-- Migrations 041 and 061 added `enabled boolean not null default true`
-- and rewrote `update_room_packs`/`get_room_packs` to use it,
-- but those migrations were never applied to the live DB.
-- The on-disk RPC bodies reference the missing `enabled` column —
-- `update_room_packs` errors on insert and the iOS toggle's catch
-- block silently reverts, leaving the host convinced the toggle
-- "doesn't work" (verified on Felt Faction 2026-08-24).
--
-- This migration does NOT add the `enabled` column (that would be
-- a wider schema change with implications for the rest of the
-- pack pipeline). Instead it rewrites the two RPCs to use the
-- live, presence-based model:
--   - `get_room_packs` returns the slugs of present rows (already
--     correct on live; no functional delta needed here).
--   - `update_room_packs`:
--     1. validates every slug exists in the global catalog
--     2. inserts slugs not already present
--     3. DELETEs rows whose slug is no longer in the input set
--        (instead of marking them disabled, since there is no
--        enabled flag)
--     4. emits `pack_removed` system events so the briefing
--        banner surfaces the change
--     (the original migration 041 also tried to settle in-flight
--      casino withdrawals; that path is dropped here because the
--      live casino_withdrawals schema has neither `event_id` nor
--      `settled_at` columns — separate reconciliation pending)
--
-- Idempotent: DROP IF EXISTS + CREATE. The bodies are SECURITY
-- DEFINER with search_path pinned, matching the originals.

-- =================================================================
-- 1. update_room_packs — rewrite as DELETE-based
-- =================================================================
drop function if exists public.update_room_packs(uuid, text[]);
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

    -- Compute the set of slugs being uninstalled so we can
    -- emit system events.
    --
    -- Note: migration 041 originally tried to settle in-flight
    -- casino_withdrawals here (`cw.settled_at = now()`), but the
    -- live schema has neither an `event_id` column nor a
    -- `settled_at` column on casino_withdrawals (per migration
    -- 014 it uses `session_id`). That side-effect was already
    -- broken on live — leaving it out here; a separate
    -- reconciliation migration can address casino-withdrawal
    -- settle semantics.
    for v_removed_slug in
        select rp.pack_slug
        from public.room_packs rp
        where rp.room_id = p_room_id
          and rp.pack_slug <> all(p_slugs)
    loop
        -- Emit the system event for the briefing banner.
        insert into public.room_system_events (room_id, kind, payload)
        values (
            p_room_id,
            'pack_removed',
            jsonb_build_object('pack_slug', v_removed_slug)
        );
    end loop;

    -- Insert slugs not already present (idempotent on the
    -- presence-based model).
    insert into public.room_packs (room_id, pack_slug, added_by)
    select p_room_id, slug, v_caller
    from unnest(p_slugs) as s(slug)
    on conflict (room_id, pack_slug) do nothing;

    -- DELETE any prior rows not in the new set. Replaces the
    -- original UPDATE ... SET enabled = false, since there is no
    -- enabled flag on the live schema.
    delete from public.room_packs rp
    where rp.room_id = p_room_id
      and rp.pack_slug <> all(p_slugs);
end;
$$;

grant execute on function public.update_room_packs(uuid, text[]) to authenticated;

comment on function public.update_room_packs(uuid, text[]) is
  'V0.93 — host writes the room''s pack roster. Replaces migration 041''s enabled-toggle version, which referenced an `enabled` column that does not exist on live (presence-based model from migration 013). Inserts missing slugs, deletes absent ones, emits `pack_removed` system events. Casino-withdrawal settle side-effect from migration 041 dropped because the live schema has neither `event_id` nor `settled_at` columns on casino_withdrawals (migration 014 used `session_id`); see notes for reconciliation.';

-- =================================================================
-- 2. get_room_packs — already returns present-row slugs, no change
-- =================================================================
-- The current body on live is:
--   select pack_slug from public.room_packs where room_id = p_room_id
--   order by added_at;
-- which is exactly what the iOS client expects (an array of slugs
-- for the room's present packs). No functional change required.
-- Left untouched so we don't add a noisy migration rewrite to
-- the audit trail.