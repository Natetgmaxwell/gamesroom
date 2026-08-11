-- 054: W3.6 — round delete + correction double-count fix.
--
-- Three changes:
--
--   1. record_round_score no longer double-counts on a re-submission.
--      The upsert on (room_id, event_id, round_index) replaces the row,
--      but the deltas from the previous entries were never reversed
--      from room_memberships.season_score — the new deltas were added
--      on top, inflating totals. The fix reads the existing entries
--      before the upsert, then subtracts each old delta before applying
--      the new ones. Signature unchanged → CREATE OR REPLACE (the
--      granted permission survives).
--
--   2. New delete_round_score(p_room_id, p_event_id, p_round_index)
--      RPC. Host-only (same room-owner check as record_round_score),
--      idempotent (no row → return without error). Reverses the
--      round's deltas, deletes the round's transactions, and removes
--      the round_submissions row. Grant execute to authenticated.
--
--   3. get_event_rounds gains a correction_of column so the iOS
--      SessionRoundTimeline can render the "corrected" chip. DROP +
--      CREATE because the RETURNS TABLE column list changes (Postgres
--      error 42P13 will reject CREATE OR REPLACE). Grant execute.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/054_round_delete_and_correction_fix.sql

-- =================================================================
-- 1. record_round_score — reverse old deltas before applying new.
-- =================================================================
create or replace function public.record_round_score(
  p_room_id uuid,
  p_event_id uuid,
  p_pack_slug text,
  p_round_index integer,
  p_entries jsonb default '[]'::jsonb,
  p_correction_of uuid default null
)
returns table (
  id uuid,
  room_id uuid,
  event_id uuid,
  round_index integer,
  pack_slug text,
  created_at timestamptz,
  correction_of uuid
)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_submission_id uuid;
  v_old_entries jsonb;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
  v_meta jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can record a round' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.events
    where id = p_event_id and room_id = p_room_id
  ) then
    raise exception 'Event does not belong to room' using errcode = 'P0002';
  end if;

  -- Capture the existing entries BEFORE the upsert replaces the row.
  -- Null for a fresh round; the reverse loop is a no-op in that case.
  select rs.entries into v_old_entries
  from public.round_submissions rs
  where rs.room_id = p_room_id
    and rs.event_id = p_event_id
    and rs.round_index = p_round_index;

  insert into public.round_submissions (
    room_id, event_id, pack_slug, round_index, entries, created_by, correction_of
  ) values (
    p_room_id, p_event_id, p_pack_slug, p_round_index, p_entries, v_caller, p_correction_of
  )
  on conflict (room_id, event_id, round_index) do update
    set entries = excluded.entries,
        pack_slug = excluded.pack_slug,
        created_by = excluded.created_by,
        correction_of = excluded.correction_of,
        created_at = now()
  returning id into v_submission_id;

  -- Reverse the old deltas first so the new deltas land on a clean
  -- season_score. Reverse + delete ordering matches migration 035's
  -- "delete then apply" flow inverted: here we replace, so we must
  -- subtract before we add.
  for v_entry in select * from jsonb_array_elements(coalesce(v_old_entries, '[]'::jsonb))
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;

    update public.room_memberships
      set season_score = season_score - v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;
    v_meta := coalesce(v_entry->'meta', '{}'::jsonb) || jsonb_build_object(
      'submission_id', v_submission_id,
      'round_index', p_round_index,
      'pack_slug', p_pack_slug,
      'correction_of', p_correction_of
    );

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      p_room_id, p_event_id, v_member_id, 'round_score', v_points_delta, v_meta, v_caller
    );

    update public.room_memberships
      set season_score = season_score + v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  return query
    select v_submission_id, p_room_id, p_event_id, p_round_index,
           p_pack_slug, now(), p_correction_of;
end;
$$;

grant execute on function public.record_round_score(
  uuid, uuid, text, integer, jsonb, uuid
) to authenticated;

-- =================================================================
-- 2. delete_round_score — void, host-only, idempotent.
-- =================================================================
create or replace function public.delete_round_score(
  p_room_id uuid,
  p_event_id uuid,
  p_round_index integer
)
returns void
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_old_entries jsonb;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can delete a round' using errcode = '42501';
  end if;

  -- Idempotent: no row for the round → return without error.
  select rs.entries into v_old_entries
  from public.round_submissions rs
  where rs.room_id = p_room_id
    and rs.event_id = p_event_id
    and rs.round_index = p_round_index;

  if v_old_entries is null then
    return;
  end if;

  for v_entry in select * from jsonb_array_elements(v_old_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;

    update public.room_memberships
      set season_score = season_score - v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  delete from public.round_submissions
    where room_id = p_room_id
      and event_id = p_event_id
      and round_index = p_round_index;
end;
$$;

grant execute on function public.delete_round_score(
  uuid, uuid, integer
) to authenticated;

comment on function public.delete_round_score(uuid, uuid, integer) is
  'Host-only. Reverses the round''s deltas, deletes the round''s transactions, and removes the round_submissions row. Idempotent: a missing round exits without error.';

-- =================================================================
-- 3. get_event_rounds — surface correction_of.
-- =================================================================
drop function if exists public.get_event_rounds(uuid);
create function public.get_event_rounds(p_event_id uuid)
returns table (
  id uuid,
  event_id uuid,
  room_id uuid,
  pack_slug text,
  round_index integer,
  entries jsonb,
  created_by uuid,
  created_at timestamptz,
  correction_of uuid
)
language sql
stable
security definer
set search_path = public
as $$
  select rs.id, rs.event_id, rs.room_id, rs.pack_slug,
         rs.round_index, rs.entries, rs.created_by, rs.created_at,
         rs.correction_of
  from public.round_submissions rs
  where rs.event_id = p_event_id
    and exists (
      select 1 from public.events e
      join public.room_memberships rm
        on rm.room_id = e.room_id
      where e.id = p_event_id
        and rm.user_id = public.current_user_id()
    )
  order by rs.round_index asc, rs.created_at asc;
$$;

grant execute on function public.get_event_rounds(uuid) to authenticated;

comment on function public.get_event_rounds(uuid) is
  'Returns the per-round submissions for one event, oldest round first. Room scope derives from the event (F-IDENT-01); members of the event''s room can read. correction_of is non-null when the row is a re-submission correcting a prior round.';
