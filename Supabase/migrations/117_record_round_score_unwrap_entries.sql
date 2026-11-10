-- 117_record_round_score_unwrap_entries.sql
-- Live bug found in the Felt Faction walkthrough (2026-11-10), right after 116:
-- saving a round failed with 'cannot extract elements from a scalar'. The app
-- (ScoringService.recordRoundInput) sends p_entries as a JSON-encoded String, which
-- PostgREST hands to jsonb as a scalar string. No host round had ever saved on live
-- (round_submissions was empty). Fix: the live 116 body plus an unwrap of a string
-- p_entries (and of any string-typed stored entries read back for the reversal).
-- Applied live 2026-11-10 and verified in a rolled-back call.
begin;
CREATE OR REPLACE FUNCTION public.record_round_score(p_room_id uuid, p_event_id uuid, p_pack_slug text, p_round_index integer, p_entries jsonb DEFAULT '[]'::jsonb, p_correction_of uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, room_id uuid, event_id uuid, round_index integer, pack_slug text, created_at timestamp with time zone, correction_of uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
#variable_conflict use_column
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

  -- The app sends p_entries as a JSON-encoded string (PostgREST hands a
  -- Swift String to jsonb as a scalar). Unwrap it so the loops below
  -- always see an array.
  if jsonb_typeof(p_entries) = 'string' then
    p_entries := (p_entries #>> '{}')::jsonb;
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
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
  if jsonb_typeof(v_old_entries) = 'string' then
    v_old_entries := (v_old_entries #>> '{}')::jsonb;
  end if;

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
$function$;

notify pgrst, 'reload schema';
commit;
