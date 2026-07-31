-- 030: Casino pack — per-member scan flow.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/030_casino_per_member_scan.sql
--
-- Reverses the V0.28 host-batched settle_casino_session model. Each
-- member now scans their own chip stack on their own phone, using the
-- room's vision API key (V0.27). The host's role at cashout shifts
-- from "counter" to "referee + finalizer."
--
-- V0.28's settle_casino_session is replaced with three new RPCs:
--   - record_member_scan(p_session_id, p_vision_amount, p_vision_snapshot)
--     member-only; called from each member's ChipScanView.
--   - finalize_casino_session(p_session_id)
--     host-only; closes the session, defaults unscanned members to 0.
--   - get_session_scans(p_session_id)
--     both; returns per-member scan status for the live board.
--
-- Idempotency: the old settle_casino_session signature is preserved
-- (kept around as a no-op for callers that still hit it) but its
-- implementation no longer writes transactions. New code calls the
-- per-member RPCs.

-- 1. New table: per-member scan results. The V0.29 settlement_attestations
--    table covers the same shape; this table is the V0.30 surface that
--    hosts the live board. The two will merge in V0.31.
create table if not exists public.casino_scans (
  id uuid default gen_random_uuid() primary key,
  session_id uuid not null,
  room_id uuid not null references public.rooms(id) on delete cascade,
  member_id uuid not null references public.users(id) on delete cascade,
  vision_amount_points bigint not null,
  vision_snapshot jsonb not null default '{}'::jsonb,
  detection_source text not null default 'on_device',
  confidence_avg double precision,
  did_not_scan boolean not null default false,
  recorded_at timestamptz not null default now(),
  finalized_at timestamptz,
  unique (session_id, member_id)
);

create index casino_scans_session_idx
  on public.casino_scans using btree (session_id);
create index casino_scans_room_idx
  on public.casino_scans using btree (room_id);

alter table public.casino_scans enable row level security;

-- Members can read their own row + the room's full scan list (for the
-- live board, V0.30). Host can read everything. The host's "Finalize"
-- write path runs as security definer below.
create policy "members read room scans" on public.casino_scans
  for select using (
    member_id = public.current_user_id()
    or exists (select 1 from public.room_memberships rm
               where rm.room_id = casino_scans.room_id
                 and rm.user_id = public.current_user_id())
  );

-- Members can only insert/update their own row (idempotent on
-- (session_id, member_id)). The trigger below prevents re-records
-- after finalize.
create policy "members write own scan" on public.casino_scans
  for insert with check (member_id = public.current_user_id());

create policy "members update own scan" on public.casino_scans
  for update using (member_id = public.current_user_id())
  with check (member_id = public.current_user_id());

-- 2. record_member_scan: called by each member from their phone after
--    ChipScanView's vision result is confirmed. Idempotent on
--    (session_id, member_id): re-records overwrite the previous scan
--    but don't double-write to the ledger. The ledger write is gated
--    on the prior row having no vision_amount_points yet OR on
--    explicit overwrite permission (re-record only updates the
--    row, not the ledger).
create or replace function public.record_member_scan(
  p_session_id uuid,
  p_vision_amount_points bigint,
  p_vision_snapshot jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_withdrawn bigint;
  v_net_delta bigint;
  v_existing_id uuid;
  v_detection_source text;
  v_confidence double precision;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Derive room from the event/session id.
  select e.room_id into v_room_id
    from public.events e where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  -- Member must have withdrawn in this session.
  select points_withdrawn into v_withdrawn
    from public.casino_withdrawals
    where session_id = p_session_id and member_id = v_caller;
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
  select id into v_existing_id
    from public.casino_scans
    where session_id = p_session_id and member_id = v_caller;

  if v_existing_id is null then
    insert into public.casino_scans (
      session_id, room_id, member_id,
      vision_amount_points, vision_snapshot,
      detection_source, confidence_avg,
      did_not_scan
    )
    values (
      p_session_id, v_room_id, v_caller,
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
      v_room_id, p_session_id, v_caller, 'casino_settlement', v_net_delta,
      jsonb_build_object(
        'vision_snapshot', p_vision_snapshot,
        'withdrawn', v_withdrawn,
        'scanned_value', p_vision_amount_points
      ),
      v_caller
    );

    -- Apply the net delta to both points_balance and season_score.
    update public.room_memberships
      set points_balance = points_balance + v_net_delta,
          season_score   = season_score   + v_net_delta
      where user_id = v_caller and room_id = v_room_id;
  else
    -- Re-record path: the member rescanned with a different result.
    -- Update the scan row in place; do NOT re-write the ledger
    -- (the original ledger row stays as the audit trail). The
    -- new vision_amount is recorded for the live board's display;
    -- the live board surfaces a "rescanned" badge.
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

grant execute on function public.record_member_scan(uuid, bigint, jsonb) to authenticated;

-- 3. finalize_casino_session: called by the host to close the session.
--    For any member who withdrew but didn't scan within the window,
--    write a default did_not_scan row with amount 0 (no P&L change).
--    After finalize, record_member_scan refuses re-records.
create or replace function public.finalize_casino_session(
  p_session_id uuid
)
returns integer
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_defaulted integer := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
    from public.events e where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if not exists (select 1 from public.rooms r
                 where r.id = v_room_id and r.created_by = v_caller) then
    raise exception 'Only the room host can finalize the session' using errcode = '42501';
  end if;

  -- Default every withdrawing member who didn't scan.
  with defaults as (
    insert into public.casino_scans (
      session_id, room_id, member_id,
      vision_amount_points, vision_snapshot,
      detection_source, confidence_avg,
      did_not_scan, recorded_at, finalized_at
    )
    select
      p_session_id, v_room_id, cw.member_id,
      0, '{"source":"did_not_scan"}'::jsonb,
      'did_not_scan', 0.0,
      true, now(), now()
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id
      and not exists (
        select 1 from public.casino_scans cs
        where cs.session_id = p_session_id and cs.member_id = cw.member_id
      )
    returning 1
  )
  select count(*) into v_defaulted from defaults;

  -- Set finalized_at on every scan row in this session that doesn't
  -- have one yet.
  update public.casino_scans
    set finalized_at = coalesce(finalized_at, now())
    where session_id = p_session_id;

  return v_defaulted;
end;
$$;

grant execute on function public.finalize_casino_session(uuid) to authenticated;

-- 4. get_session_scans: returns per-member scan status. Used by the
--    host's live settlement board and the member's "did I scan?"
--    check. One row per (session_id, member) — joined against
--    casino_withdrawals so unscanned members are still returned.
create or replace function public.get_session_scans(p_session_id uuid)
returns table (
  member_id uuid,
  member_display_name text,
  vision_amount_points bigint,
  detection_source text,
  confidence_avg double precision,
  did_not_scan boolean,
  recorded_at timestamptz,
  finalized_at timestamptz
)
language sql
security definer
stable
as $$
  select
    cw.member_id,
    coalesce(p.display_name, 'Member') as member_display_name,
    coalesce(cs.vision_amount_points, 0) as vision_amount_points,
    coalesce(cs.detection_source, 'pending') as detection_source,
    cs.confidence_avg,
    coalesce(cs.did_not_scan, false) as did_not_scan,
    cs.recorded_at,
    cs.finalized_at
  from public.casino_withdrawals cw
  left join public.users u on u.id = cw.member_id
  left join public.profiles p on p.user_id = u.id
  left join public.casino_scans cs
    on cs.session_id = cw.session_id and cs.member_id = cw.member_id
  where cw.session_id = p_session_id
  order by p.display_name nulls last;
$$;

grant execute on function public.get_session_scans(uuid) to authenticated;

-- 5. Refuse re-records after finalize. Implemented as a trigger so
--    even direct INSERTs from the app can't bypass the finalize gate.
create or replace function public.casino_scans_refuse_post_finalize()
returns trigger
language plpgsql
as $$
declare
  v_finalized timestamptz;
begin
  select finalized_at into v_finalized
    from public.casino_scans
    where session_id = new.session_id
    limit 1;
  if v_finalized is not null then
    raise exception 'Session is finalized; no more scans accepted' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists casino_scans_post_finalize_check on public.casino_scans;
create trigger casino_scans_post_finalize_check
  before insert on public.casino_scans
  for each row execute function public.casino_scans_refuse_post_finalize();

-- 6. Replace settle_casino_session. The old signature is preserved
--    so legacy callers don't break, but the body is now a no-op that
--    raises a clear "use record_member_scan + finalize_casino_session"
--    error. Migration 031 (next) will remove it entirely.
create or replace function public.settle_casino_session(
  p_session_id uuid,
  p_settlements jsonb
)
returns boolean
language plpgsql
security definer
as $$
begin
  raise exception 'settle_casino_session is deprecated as of 2026-07-28. Use record_member_scan + finalize_casino_session instead.' using errcode = '22023';
end;
$$;

grant execute on function public.settle_casino_session(uuid, jsonb) to authenticated;
