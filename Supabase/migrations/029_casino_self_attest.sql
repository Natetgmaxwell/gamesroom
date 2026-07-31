-- 029: Casino pack — self-attestation layer.
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/029_casino_self_attest.sql
--
-- Why this exists
-- ---------------
-- V0.28 fixed settle_casino_session to update points_balance. But the
-- member has no way to validate the number. This migration adds the
-- validation layer: after the host settles, every member who had a
-- withdrawal gets a row in settlement_attestations with the
-- vision-computed amount. The member's app shows a banner; the member
-- can tap "Looks right" (attest) or "Off by $X" (dispute). If 24h
-- passes without an attestation, the vision value becomes canonical
-- (closed lazily on next read).

-- 1. Table. One row per (session, member). The row is created when the
--    host opens the attestation window after settle; the member's tap
--    either keeps disputed=false or flips it to true with claimed_amount.
create table if not exists public.settlement_attestations (
  id uuid default gen_random_uuid() primary key,
  session_id uuid not null,
  room_id uuid not null references public.rooms(id) on delete cascade,
  member_id uuid not null references public.users(id) on delete cascade,
  vision_amount_points bigint not null,
  claimed_amount_points bigint,
  disputed boolean not null default false,
  dispute_reason text,
  detection_source text not null default 'on_device',
  confidence_avg double precision,
  opened_at timestamptz not null default now(),
  attested_at timestamptz,
  closed_at timestamptz
);

create index settlement_attestations_session_idx
  on public.settlement_attestations using btree (session_id);
create index settlement_attestations_member_open_idx
  on public.settlement_attestations using btree (member_id)
  where closed_at is null;

alter table public.settlement_attestations enable row level security;

-- Members can read their own attestations; the room host can read all
-- in the room; any room member can read for the live board surface
-- (V0.30). For V0.29 we keep the read scope tight: own + host + same-room
-- members when not yet closed. Closed rows are also readable so the
-- historical record is intact.
create policy "members read attestations in their room" on public.settlement_attestations
  for select using (
    member_id = public.current_user_id()
    or exists (select 1 from public.room_memberships rm
               where rm.room_id = settlement_attestations.room_id
                 and rm.user_id = public.current_user_id())
  );

-- Only the system (RPCs marked security definer) inserts attestation rows.
-- Members do not insert directly; the host's open-window call creates them.
create policy "system inserts attestations" on public.settlement_attestations
  for insert with check (false);  -- RPCs run as definer, bypass RLS

-- Members update only their own row's disputed / claimed_amount /
-- dispute_reason. The host's override path uses a separate RPC.
create policy "members update own attestation" on public.settlement_attestations
  for update using (member_id = public.current_user_id())
  with check (member_id = public.current_user_id());

-- 2. open_casino_attestation_window: called by the host immediately after
--    settle_casino_session. Creates one attestation row per member who
--    had a withdrawal in this session, with vision_amount_points set
--    to the amount the host just wrote for that member in the
--    transaction log.
create or replace function public.open_casino_attestation_window(
  p_session_id uuid
)
returns integer
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_inserted integer := 0;
  v_member_id uuid;
  v_amount bigint;
  v_source text;
  v_conf double precision;
  v_existing integer;
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
    raise exception 'Only the room host can open the attestation window' using errcode = '42501';
  end if;

  -- Idempotent: if attestations already exist for this session, return
  -- the count and don't double-insert.
  select count(*) into v_existing
    from public.settlement_attestations
    where session_id = p_session_id;
  if v_existing > 0 then
    return v_existing;
  end if;

  -- For each member who withdrew chips in this session, create an
  -- attestation row seeded with the transaction amount (which is the
  -- net delta: chip_value - withdrawn). Vision source + confidence
  -- are read from the latest transaction's meta.vision_snapshot.
  for v_member_id in
    select distinct member_id
    from public.casino_withdrawals
    where session_id = p_session_id
  loop
    -- Find the settlement transaction for this member in this session.
    -- The transaction's amount_points IS the net delta (per V0.28).
    select amount_points, meta->'vision_snapshot'->>'source',
           (meta->'vision_snapshot'->>'confidence_avg')::double precision
      into v_amount, v_source, v_conf
      from public.transactions
      where session_id = p_session_id
        and member_id = v_member_id
        and kind = 'casino_settlement'
      limit 1;

    -- If no settlement transaction exists for this member, skip. This
    -- happens if the host settled some but not all members.
    if v_amount is null then
      continue;
    end if;

    insert into public.settlement_attestations (
      session_id, room_id, member_id,
      vision_amount_points, detection_source, confidence_avg
    )
    values (
      p_session_id, v_room_id, v_member_id,
      v_amount, coalesce(v_source, 'on_device'), v_conf
    );
    v_inserted := v_inserted + 1;
  end loop;

  return v_inserted;
end;
$$;

grant execute on function public.open_casino_attestation_window(uuid) to authenticated;

-- 3. attest_casino_settlement: member taps "Looks right" or "Off by $X".
--    Sets disputed, claimed_amount, dispute_reason, attested_at, closed_at.
--    The 24h grace is enforced here: a member can attest at any time
--    while the row is open; an attempt after closed_at raises.
create or replace function public.attest_casino_settlement(
  p_attestation_id uuid,
  p_disputed boolean,
  p_claimed_amount_points bigint default null,
  p_dispute_reason text default null
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_row public.settlement_attestations%rowtype;
  v_window_hours constant integer := 24;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select * into v_row
    from public.settlement_attestations
    where id = p_attestation_id;

  if v_row.id is null then
    raise exception 'Attestation not found' using errcode = 'P0002';
  end if;

  if v_row.member_id <> v_caller then
    raise exception 'You can only attest your own settlement' using errcode = '42501';
  end if;

  if v_row.closed_at is not null then
    raise exception 'Attestation window already closed' using errcode = '23514';
  end if;

  if v_row.attested_at is not null then
    raise exception 'Already attested' using errcode = '23514';
  end if;

  if now() > v_row.opened_at + (v_window_hours || ' hours')::interval then
    update public.settlement_attestations
      set closed_at = coalesce(closed_at, now())
      where id = p_attestation_id;
    raise exception 'Attestation window closed (>% hours)', v_window_hours using errcode = '23514';
  end if;

  if p_disputed and (p_claimed_amount_points is null) then
    raise exception 'Disputed attestations must include a claimed amount' using errcode = '23502';
  end if;

  update public.settlement_attestations
    set disputed = p_disputed,
        claimed_amount_points = case when p_disputed then p_claimed_amount_points else null end,
        dispute_reason = case when p_disputed then p_dispute_reason else null end,
        attested_at = now(),
        closed_at = now()
    where id = p_attestation_id;

  return true;
end;
$$;

grant execute on function public.attest_casino_settlement(uuid, boolean, bigint, text) to authenticated;

-- 4. get_my_open_casino_attestations: member's RoomDetailView calls this
--    on load to know whether to show the banner. Returns all open
--    attestations for the current user (across all rooms — but usually
--    at most one at a time).
create or replace function public.get_my_open_casino_attestations()
returns table (
  attestation_id uuid,
  session_id uuid,
  room_id uuid,
  room_name text,
  vision_amount_points bigint,
  detection_source text,
  confidence_avg double precision,
  opened_at timestamptz,
  session_name text
)
language sql
security definer
stable
as $$
  select
    sa.id, sa.session_id, sa.room_id, r.name, sa.vision_amount_points,
    sa.detection_source, sa.confidence_avg, sa.opened_at, e.name
  from public.settlement_attestations sa
  join public.rooms r on r.id = sa.room_id
  left join public.events e on e.id = sa.session_id
  where sa.member_id = public.current_user_id()
    and sa.closed_at is null
  order by sa.opened_at desc;
$$;

grant execute on function public.get_my_open_casino_attestations() to authenticated;

-- 5. close_stale_attestations: the lazy 24h finalize. Called on any read
--    of open attestations; closes rows that have been open > 24h without
--    an attestation. Idempotent; safe to run on every page load.
create or replace function public.close_stale_attestations()
returns integer
language sql
security definer
as $$
  with closed as (
    update public.settlement_attestations
      set closed_at = now()
      where closed_at is null
        and now() > opened_at + interval '24 hours'
      returning id
  )
  select count(*)::integer from closed;
$$;

grant execute on function public.close_stale_attestations() to authenticated;
