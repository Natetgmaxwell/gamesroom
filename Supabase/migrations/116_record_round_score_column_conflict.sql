-- 116_record_round_score_column_conflict.sql
-- Live bug found in the Felt Faction walkthrough (2026-11-10): scoring a
-- Monopoly Deal round failed with 'column reference "id" is ambiguous'.
-- record_round_score RETURNS TABLE(id, room_id, event_id, ...), so its
-- OUT columns shadow the table columns in every unqualified reference
-- (rooms.id, events.id/room_id, the on-conflict target, returning id).
-- 095's generated guard (`public.is_room_host(id, v_caller)`) is where it
-- first surfaced. Fix: the body is the LIVE body, unchanged, plus
-- `#variable_conflict use_column`, so table columns win and the OUT
-- columns are only ever set by the final `return query`.
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

revoke all on function public.record_round_score(uuid, uuid, text, integer, jsonb, uuid) from public, anon;
grant execute on function public.record_round_score(uuid, uuid, text, integer, jsonb, uuid) to authenticated;

-- Same class, latent: redeem_join_code's rejoin branch (`where room_id = v_room_id`)
-- collides with its RETURNS TABLE(room_id, ...). A kicked member re-joining with a
-- fresh code would fail. Live body + the same pragma.
CREATE OR REPLACE FUNCTION public.redeem_join_code(p_code text)
 RETURNS TABLE(room_id uuid, room_name text, status text, tier integer, invited_by uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
#variable_conflict use_column
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
  v_bonus integer;
  v_existing_status text;
  -- 076 lineage (preserved so the invite-reward + tier logic keeps
  -- working — the 093 rewrite must not silently drop it).
  v_invitee uuid;
  v_generator uuid;
  v_tier int;
  v_status text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Find an unredeemed code. 068/076 lineage: pull invitee_user_id
  -- + generated_by so tier derivation and the invite reward survive.
  select jc.room_id, jc.invitee_user_id, jc.generated_by
    into v_room_id, v_invitee, v_generator
  from public.join_codes jc
  where jc.code = upper(p_code)
    and jc.redeemed_at is null
  for update;

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Tier-3 scoping (068): an invitee-scoped code is rejected for
  -- anyone other than the intended invitee.
  if v_invitee is not null and v_invitee <> v_user_id then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Tier derivation (076): invitee-scoped → 3, host/creator or
  -- unattributed → 1, member-generated → 2.
  if v_invitee is not null then
    v_tier := 3;
  elsif v_generator is null
     or v_generator = (select created_by from public.rooms where id = v_room_id) then
    v_tier := 1;
  else
    v_tier := 2;
  end if;

  -- Existing-membership branch (D6 + 018 lineage).
  select m.membership_status into v_existing_status
  from public.room_memberships m
  where m.room_id = v_room_id and m.user_id = v_user_id;

  if v_existing_status = 'active' then
    -- Already an active member: idempotent, return the room.
    select r.name into v_room_name from public.rooms r where r.id = v_room_id;
    v_status := 'already_member';
    return query select v_room_id, v_room_name, v_status, v_tier, v_generator;
    return;
  elsif v_existing_status = 'kicked' then
    -- V0.98 — reactivation. Fresh code = implicit approval (D6).
    -- Status flips to 'active', points_balance resets to the room's
    -- join_starting_bonus. season_score, team, history untouched —
    -- the kicked row is the same row, only the status column moves.
    select r.name, r.join_starting_bonus
      into v_room_name, v_bonus
    from public.rooms r
    where r.id = v_room_id;

    update public.room_memberships
      set membership_status = 'active',
          points_balance = v_bonus
    where room_id = v_room_id
      and user_id = v_user_id;

    v_status := 'joined';

    -- Invite reward (076 lineage): a rejoin counts as a fresh join
    -- through this generator's code, so the inviter is credited
    -- again — same self-invite guard as 076.
    if v_generator is not null and v_generator <> v_user_id then
      update public.room_memberships m
         set points_balance = m.points_balance + 50
       where m.room_id = v_room_id and m.user_id = v_generator;

      insert into public.transactions (
        room_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_room_id, v_generator, 'invite_reward', 50,
        jsonb_build_object('invitee', v_user_id, 'code', upper(p_code)),
        v_user_id
      );
    end if;
  else
    -- No prior row: new member. Look up the per-room join starting
    -- bonus and insert.
    select r.name, r.join_starting_bonus
      into v_room_name, v_bonus
    from public.rooms r
    where r.id = v_room_id;

    insert into public.room_memberships (room_id, user_id, role, points_balance, membership_status, invited_by, invite_tier)
    values (v_room_id, v_user_id, 'member', v_bonus, 'active', v_generator, v_tier);
    v_status := 'joined';

    -- Invite reward (076 lineage), first join only.
    if v_generator is not null and v_generator <> v_user_id then
      update public.room_memberships m
         set points_balance = m.points_balance + 50
       where m.room_id = v_room_id and m.user_id = v_generator;

      insert into public.transactions (
        room_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_room_id, v_generator, 'invite_reward', 50,
        jsonb_build_object('invitee', v_user_id, 'code', upper(p_code)),
        v_user_id
      );
    end if;
  end if;

  update public.join_codes jc
    set redeemed_at = now(), redeemed_by = v_user_id
    where jc.code = upper(p_code);

  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name, v_status, v_tier, v_generator;
end;
$function$;

notify pgrst, 'reload schema';
commit;
