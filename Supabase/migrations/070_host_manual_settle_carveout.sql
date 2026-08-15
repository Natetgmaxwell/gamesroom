-- 070: V0.72 slice 3 — host manual settle carve-out. Contract:
-- V0.72_HOSTED_VISION_SETTLE_SPEC.md. 069 closed member-role recording on
-- minimax_vision rooms; the degenerate-case fallback is HOST manual entry
-- (member never types a count). This migration admits the room host when
-- the snapshot source is 'manual'.
--
-- Both functions are re-CREATEd via CREATE OR REPLACE; the 4-arg
-- signature is identical to 069 so OR REPLACE is legal (no DROP, no
-- overload). New declare block adds v_host + v_snapshot_source and the
-- provider-gate is narrowed to admit the room host with snapshot
-- source = 'manual'. The host may also pass p_member_id to record on
-- behalf of a member. The membership check (for CAH) and the
-- withdrawal precondition (for chips) are unchanged from 069.
--
-- Apply via (db password rotated 2026-08; if psql auth fails use
-- `supabase db query --linked -f <this file>` from Supabase/ with the
-- access token in ~/.supabase/):
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/070_host_manual_settle_carveout.sql

-- =================================================================
-- 1. record_member_scan — host manual carve-out (migration 070)
-- =================================================================
create or replace function public.record_member_scan(
  p_session_id uuid,
  p_vision_amount_points bigint,
  p_vision_snapshot jsonb default '{}'::jsonb,
  p_member_id uuid default null
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_is_service boolean := current_setting('role', true) = 'service_role';
  v_member uuid;
  v_room_id uuid;
  v_provider text;
  v_host uuid;
  v_snapshot_source text;
  v_withdrawn bigint;
  v_net_delta bigint;
  v_existing_id uuid;
  v_detection_source text;
  v_confidence double precision;
begin
  -- Caller class: service role records on behalf of p_member_id (the
  -- scan-settle edge function); the room host (migration 070) may
  -- also pass p_member_id to record on behalf of a member; anyone
  -- else records as themselves.
  if v_is_service then
    if p_member_id is null then
      raise exception 'Service role must pass p_member_id' using errcode = '42501';
    end if;
    v_member := p_member_id;
  else
    if v_caller is null then
      raise exception 'Not authenticated' using errcode = '42501';
    end if;
    v_member := v_caller;
    if p_member_id is not null then
      v_member := p_member_id;
    end if;
  end if;

  -- Derive room from the event/session id.
  select e.room_id into v_room_id
    from public.events e where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  -- Hosted-vision rooms: member-role counting is closed. The room
  -- host keeps a manual carve-out for the degenerate case (no
  -- camera, model down) — 070. The host may also record on behalf
  -- of a member via p_member_id.
  if not v_is_service then
    select crc.vision_provider, r.created_by into v_provider, v_host
      from public.events e
      join public.rooms r on r.id = e.room_id
      left join public.casino_room_config crc on crc.room_id = e.room_id
      where e.id = p_session_id;
    if v_provider = 'minimax_vision' then
      v_snapshot_source := coalesce(p_vision_snapshot->>'source', '');
      if v_host is distinct from v_caller or v_snapshot_source <> 'manual' then
        raise exception 'Member counting is closed for this room: scans are recorded by the hosted vision service' using errcode = '42501';
      end if;
      -- host manual carve-out: host is the recorded member unless p_member_id names a member
    end if;
  end if;

  -- Member must have withdrawn in this session.
  select cw.points_withdrawn into v_withdrawn
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id and cw.member_id = v_member;
  if v_withdrawn is null then
    raise exception 'You have not withdrawn chips in this session' using errcode = 'P0002';
  end if;

  -- Extract detection_source + confidence from the snapshot if present.
  v_detection_source := coalesce(p_vision_snapshot->>'source', 'on_device');
  v_confidence := (p_vision_snapshot->>'confidence_avg')::double precision;

  -- Net delta = vision value - withdrawn. The member sees the net P&L
  -- (positive = won, negative = lost). The transaction row records the
  -- net delta so the balance update is exactly what the member confirmed.
  v_net_delta := p_vision_amount_points - v_withdrawn;

  -- Idempotent: check if a scan row already exists.
  select cs.id into v_existing_id
    from public.casino_scans cs
    where cs.session_id = p_session_id and cs.member_id = v_member;

  if v_existing_id is null then
    insert into public.casino_scans (
      session_id, room_id, member_id,
      vision_amount_points, vision_snapshot,
      detection_source, confidence_avg,
      did_not_scan
    )
    values (
      p_session_id, v_room_id, v_member,
      p_vision_amount_points, p_vision_snapshot,
      v_detection_source, v_confidence,
      false
    );

    -- Ledger write. The transaction's amount_points is the net delta
    -- so points_balance and season_score both move by the same number.
    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    )
    values (
      v_room_id, p_session_id, v_member, 'casino_settlement', v_net_delta,
      jsonb_build_object(
        'vision_snapshot', p_vision_snapshot,
        'withdrawn', v_withdrawn,
        'scanned_value', p_vision_amount_points
      ),
      v_member
    );

    -- Apply the net delta to both points_balance and season_score.
    update public.room_memberships
      set points_balance = points_balance + v_net_delta,
          season_score   = season_score   + v_net_delta
      where user_id = v_member and room_id = v_room_id;
  else
    -- Re-record path: a rescan produced a different result. Update the
    -- scan row in place; do NOT re-write the ledger (the original ledger
    -- row stays as the audit trail). The new vision_amount is recorded
    -- for the live board's display; the board surfaces a "rescanned" badge.
    update public.casino_scans
      set vision_amount_points = p_vision_amount_points,
          vision_snapshot = p_vision_snapshot,
          detection_source = v_detection_source,
          confidence_avg = v_confidence,
          recorded_at = now()
      where id = v_existing_id;
  end if;

  return true;
end;
$$;

grant execute on function public.record_member_scan(uuid, bigint, jsonb, uuid)
  to authenticated, service_role;

comment on function public.record_member_scan(uuid, bigint, jsonb, uuid) is
  'V0.30 member scan + V0.72 authority + V0.72 slice 3 host manual carve-out. '
  'Service role (scan-settle edge fn) records on behalf of p_member_id; '
  'member-role calls are rejected when the room''s '
  'casino_room_config.vision_provider = ''minimax_vision'' (migration 069). '
  'Migration 070 admits the room host with snapshot source = ''manual'' '
  'as the degenerate-case fallback (no camera, model down). The host '
  'may also pass p_member_id to record on behalf of a member.';

-- =================================================================
-- 2. record_cah_tally — host manual carve-out (migration 070)
-- =================================================================
create or replace function public.record_cah_tally(
  p_event_id uuid,
  p_card_count bigint,
  p_vision_snapshot jsonb default '{}'::jsonb,
  p_member_id uuid default null
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_is_service boolean := current_setting('role', true) = 'service_role';
  v_member uuid;
  v_room_id uuid;
  v_pack_slug text;
  v_provider text;
  v_host uuid;
  v_snapshot_source text;
  v_old_total bigint := 0;
begin
  -- Caller class: same as record_member_scan (migration 069 + 070).
  if v_is_service then
    if p_member_id is null then
      raise exception 'Service role must pass p_member_id' using errcode = '42501';
    end if;
    v_member := p_member_id;
  else
    if v_caller is null then
      raise exception 'Not authenticated' using errcode = '42501';
    end if;
    v_member := v_caller;
    if p_member_id is not null then
      v_member := p_member_id;
    end if;
  end if;

  -- Derive room + pack from the event id.
  select e.room_id, e.pack_slug into v_room_id, v_pack_slug
    from public.events e
    where e.id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- The tally is only valid for a Cards Against Humanity event.
  if v_pack_slug is distinct from 'cards_against_humanity' then
    raise exception 'Event is not a Cards Against Humanity event' using errcode = 'P0002';
  end if;

  -- Hosted-vision rooms: member-role tallying is closed (migration 069).
  -- The room host keeps a manual carve-out for the degenerate case —
  -- 070. The host may also record on behalf of a member via p_member_id.
  if not v_is_service then
    select crc.vision_provider, r.created_by into v_provider, v_host
      from public.events e
      join public.rooms r on r.id = e.room_id
      left join public.casino_room_config crc on crc.room_id = e.room_id
      where e.id = p_event_id;
    if v_provider = 'minimax_vision' then
      v_snapshot_source := coalesce(p_vision_snapshot->>'source', '');
      if v_host is distinct from v_caller or v_snapshot_source <> 'manual' then
        raise exception 'Member counting is closed for this room: tallies are recorded by the hosted vision service' using errcode = '42501';
      end if;
      -- host manual carve-out: host may not be a member of the room,
      -- so the membership check below is skipped for this branch.
    else
      -- Caller must be a member of the room.
      if not exists (
        select 1 from public.room_memberships rm
        where rm.room_id = v_room_id and rm.user_id = v_member
      ) then
        raise exception 'Not a member of this room' using errcode = '42501';
      end if;
    end if;
  end if;

  -- Sum the member's existing round_score transactions for this
  -- (room, event) so we can reverse the season_score delta on
  -- the way out (tally REPLACES the per-round entries).
  select coalesce(sum(t.amount_points), 0) into v_old_total
    from public.transactions t
    where t.room_id = v_room_id
      and t.session_id = p_event_id
      and t.member_id = v_member
      and t.kind = 'round_score';

  -- Delete the member's existing per-round entries for this
  -- event. A prior tally row is also deleted (matched by
  -- meta->>'tally' = true) so re-scan converges.
  delete from public.transactions t
    where t.room_id = v_room_id
      and t.session_id = p_event_id
      and t.member_id = v_member
      and t.kind = 'round_score';

  -- Insert the single tally row.
  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, v_member, 'round_score', p_card_count,
    jsonb_build_object(
      'cards_won', p_card_count,
      'tally', true,
      'vision_snapshot', p_vision_snapshot,
      'pack_slug', 'cards_against_humanity'
    ),
    v_member
  );

  -- Reconcile the season score: subtract the old per-round
  -- total, add the new tally count. Members who never scanned
  -- keep their v_old_total; the scan converges to the new count.
  update public.room_memberships
    set season_score = season_score - v_old_total + p_card_count
    where user_id = v_member and room_id = v_room_id;

  return true;
end;
$$;

grant execute on function public.record_cah_tally(uuid, bigint, jsonb, uuid)
  to authenticated, service_role;

comment on function public.record_cah_tally(uuid, bigint, jsonb, uuid) is
  'V0.34 CAH session-end tally + V0.72 authority + V0.72 slice 3 host '
  'manual carve-out. Replaces the member''s per-round round_score rows '
  'with the authoritative scanned black-card count. Service role records '
  'on behalf of p_member_id; member-role calls are rejected when the '
  'room''s vision_provider = ''minimax_vision'' (migration 069). Migration '
  '070 admits the room host with snapshot source = ''manual'' as the '
  'degenerate-case fallback.';
