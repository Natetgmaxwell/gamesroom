-- 074: V0.74 — entitlement-based casino economy.
--
-- Live-data confirmed defect (2026-08-16): withdraw_casino_chips
-- debited points_balance AND record_member_scan applied
-- scanned - withdrawn, double-counting the principal. The rescan
-- branch was display-only; working_hand stacked stale withdrawals.
--
-- New model — "chips stay on the table all night":
--   * points_balance = TOTAL wealth (bank + table).
--   * Withdraw = RESERVATION (memo row only, no debit).
--   * Entitlement E = last scan value + withdrawals after it
--     (or sum of all withdrawals if never scanned).
--   * Every scan settles delta = scanned - E:
--     balance += delta, season_score += delta, E := scanned.
--   * Withdrawal gate: p_points <= balance - open E.
--   * finalize: non-scanner forfeits open E; scanner already
--     settled, finalize only stamps finalized_at.

-- =====================================================================
-- 1. withdraw_casino_chips — reservation semantics (signature kept)
-- =====================================================================
create or replace function public.withdraw_casino_chips(
  p_session_id uuid,
  p_member_id uuid,
  p_points integer
)
returns table(
  id uuid, session_id uuid, member_id uuid,
  points_withdrawn bigint, withdrawn_at timestamptz, withdrawn_by uuid
)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_available bigint;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_points is null or p_points <= 0 then
    raise exception 'Points must be positive' using errcode = '23514';
  end if;

  select e.room_id into v_room_id
    from public.events e
    where e.id = p_session_id;
  if v_room_id is null then
    raise exception 'Session not found' using errcode = 'P0002';
  end if;

  if v_caller <> p_member_id
     and not exists (
       select 1 from public.rooms r
       where r.id = v_room_id and r.created_by = v_caller
     ) then
    raise exception 'Not authorized to withdraw for this member' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = p_member_id
  ) then
    raise exception 'Member is not in the event room' using errcode = 'P0002';
  end if;

  -- Reservation gate: p_points <= unreserved wealth. Open
  -- entitlement E = last scan value + withdrawals after that scan
  -- (or Σ all session withdrawals when the member never scanned).
  -- finalized_at is a host bookkeeping stamp only — a scan settles
  -- at record time (074), so the E formula keys off the scan row,
  -- not finalized_at.
  select m.points_balance - (
    coalesce((
      select cs.vision_amount_points
      from public.casino_scans cs
      where cs.session_id = p_session_id
        and cs.member_id = p_member_id
      order by cs.recorded_at desc
      limit 1
    ), 0)
    +
    coalesce((
      select sum(cw.points_withdrawn)
      from public.casino_withdrawals cw
      where cw.session_id = p_session_id
        and cw.member_id = p_member_id
        and not exists (
          select 1 from public.casino_scans cs
          where cs.session_id = p_session_id
            and cs.member_id = p_member_id
            and cs.recorded_at >= cw.withdrawn_at
        )
    ), 0)
  )
  into v_available
  from public.room_memberships m
  where m.user_id = p_member_id and m.room_id = v_room_id;

  if v_available is null or v_available < p_points then
    raise exception 'Insufficient unreserved points balance' using errcode = '23514';
  end if;

  -- RESERVATION ONLY: no balance/score mutation. The memo row keeps
  -- amount = −p_points for display (host dispense list, night
  -- recap); the principal returns via scan-delta settlement, and an
  -- open withdrawal at finalize is forfeited for non-scanners.
  insert into public.transactions (room_id, session_id, member_id, kind, amount_points, created_by)
  values (v_room_id, p_session_id, p_member_id, 'casino_withdrawal', -p_points, v_caller);

  insert into public.casino_withdrawals (session_id, member_id, points_withdrawn, withdrawn_by)
  values (p_session_id, p_member_id, p_points, v_caller);

  return query
    select cw.id, cw.session_id, cw.member_id, cw.points_withdrawn, cw.withdrawn_at, cw.withdrawn_by
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id and cw.member_id = p_member_id
    order by cw.withdrawn_at desc
    limit 1;
end;
$function$;

-- =====================================================================
-- 2. record_member_scan — every scan settles the marginal delta
-- =====================================================================
-- E = last scan value + withdrawals after that scan (ΣW when never
-- scanned). delta = scanned − E → applied to balance + score, with
-- a settlement ledger row when ≠ 0. The rescan path now settles too
-- (was display-only — the root of "can't resettle after re-withdraw").
create or replace function public.record_member_scan(
  p_session_id uuid,
  p_vision_amount_points bigint,
  p_vision_snapshot jsonb default '{}'::jsonb,
  p_member_id uuid default null
)
returns boolean
language plpgsql
security definer
as $function$
declare
  v_caller uuid := public.current_user_id();
  v_is_service boolean := current_setting('role', true) = 'service_role';
  v_member uuid;
  v_room_id uuid;
  v_provider text;
  v_host uuid;
  v_snapshot_source text;
  v_entitlement bigint;
  v_delta bigint;
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
    end if;
  end if;

  -- Member must have withdrawn in this session.
  if not exists (
    select 1 from public.casino_withdrawals cw
    where cw.session_id = p_session_id and cw.member_id = v_member
  ) then
    raise exception 'You have not withdrawn chips in this session' using errcode = 'P0002';
  end if;

  -- Detection metadata from the snapshot.
  v_detection_source := coalesce(p_vision_snapshot->>'source', 'on_device');
  v_confidence := (p_vision_snapshot->>'confidence_avg')::double precision;

  -- Entitlement E: chips the member should have on the table right
  -- now = their last scan value + withdrawals recorded after that
  -- scan (all withdrawals when they never scanned).
  select
    coalesce((
      select cs.vision_amount_points
      from public.casino_scans cs
      where cs.session_id = p_session_id and cs.member_id = v_member
      order by cs.recorded_at desc
      limit 1
    ), 0)
    +
    coalesce((
      select sum(cw.points_withdrawn)
      from public.casino_withdrawals cw
      where cw.session_id = p_session_id and cw.member_id = v_member
        and not exists (
          select 1 from public.casino_scans cs2
          where cs2.session_id = p_session_id
            and cs2.member_id = v_member
            and cs2.recorded_at >= cw.withdrawn_at
        )
    ), 0)
  into v_entitlement;

  -- Marginal settle: delta vs entitlement.
  v_delta := p_vision_amount_points - v_entitlement;

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
  else
    update public.casino_scans
      set vision_amount_points = p_vision_amount_points,
          vision_snapshot = p_vision_snapshot,
          detection_source = v_detection_source,
          confidence_avg = v_confidence,
          recorded_at = now()
      where id = v_existing_id;
  end if;

  -- Settle the delta: balance + score move by exactly the marginal
  -- change; a ledger row records it when money moved. A rescan that
  -- matches E moves nothing.
  if v_delta <> 0 then
    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    )
    values (
      v_room_id, p_session_id, v_member, 'casino_settlement', v_delta,
      jsonb_build_object(
        'vision_snapshot', p_vision_snapshot,
        'entitlement', v_entitlement,
        'scanned_value', p_vision_amount_points
      ),
      v_member
    );

    update public.room_memberships
      set points_balance = points_balance + v_delta,
          season_score   = season_score   + v_delta
      where user_id = v_member and room_id = v_room_id;
  end if;

  return true;
end;
$function$;

-- =====================================================================
-- 3. get_event_working_hands — working_hand = true table stack (E)
-- =====================================================================
drop function if exists public.get_event_working_hands(uuid);
create function public.get_event_working_hands(p_event_id uuid)
returns table (
  member_id uuid,
  display_name text,
  working_hand bigint,
  points_balance bigint,
  has_scanned boolean,
  scanned_value bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    m.user_id as member_id,
    u.display_name as display_name,
    (
      coalesce((
        select cs.vision_amount_points
        from public.casino_scans cs
        where cs.session_id = p_event_id
          and cs.member_id = m.user_id
        order by cs.recorded_at desc
        limit 1
      ), 0)
      +
      coalesce((
        select sum(cw.points_withdrawn)
        from public.casino_withdrawals cw
        where cw.session_id = p_event_id
          and cw.member_id = m.user_id
          and not exists (
            select 1 from public.casino_scans cs2
            where cs2.session_id = p_event_id
              and cs2.member_id = m.user_id
              and cs2.recorded_at >= cw.withdrawn_at
          )
      ), 0)
    )::bigint as working_hand,
    m.points_balance as points_balance,
    exists (
      select 1 from public.casino_scans cs
      where cs.session_id = p_event_id
        and cs.member_id = m.user_id
    ) as has_scanned,
    (
      select cs.vision_amount_points
      from public.casino_scans cs
      where cs.session_id = p_event_id
        and cs.member_id = m.user_id
      order by cs.recorded_at desc
      limit 1
    ) as scanned_value
  from public.room_memberships m
  join public.events e on e.id = p_event_id
  join public.users u on u.id = m.user_id
  where m.room_id = e.room_id
    and exists (
      select 1 from public.room_memberships rm
      where rm.room_id = e.room_id
        and rm.user_id = public.current_user_id()
    )
  order by
    case when m.role = 'host' then 0 else 1 end,
    u.display_name;
$$;

grant execute on function public.get_event_working_hands(uuid) to authenticated;

-- =====================================================================
-- 4. finalize_casino_session — forfeit non-scanners' open entitlement
-- =====================================================================
create or replace function public.finalize_casino_session(p_session_id uuid)
returns integer
language plpgsql
security definer
as $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_forfeited integer := 0;
  v_entitlement bigint;
  v_member uuid;
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

  -- Non-scanners: forfeit their open entitlement (they walked with
  -- the chips and never settled). One did_not_scan row per member;
  -- balance + score absorb the loss.
  for v_member, v_entitlement in
    select cw.member_id, sum(cw.points_withdrawn)::bigint
    from public.casino_withdrawals cw
    where cw.session_id = p_session_id
    group by cw.member_id
    having not exists (
      select 1 from public.casino_scans cs
      where cs.session_id = p_session_id
        and cs.member_id = cw.member_id
    )
  loop
    insert into public.casino_scans (
      session_id, room_id, member_id,
      vision_amount_points, vision_snapshot,
      detection_source, confidence_avg,
      did_not_scan, recorded_at, finalized_at
    )
    values (
      p_session_id, v_room_id, v_member,
      0, '{"source":"did_not_scan"}'::jsonb,
      'did_not_scan', 0.0,
      true, now(), now()
    );

    if v_entitlement > 0 then
      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      )
      values (
        v_room_id, p_session_id, v_member, 'casino_settlement', -v_entitlement,
        jsonb_build_object('source', 'did_not_scan', 'forfeited', v_entitlement),
        v_caller
      );

      update public.room_memberships
        set points_balance = points_balance - v_entitlement,
            season_score   = season_score   - v_entitlement
        where user_id = v_member and room_id = v_room_id;
    end if;

    v_forfeited := v_forfeited + 1;
  end loop;

  -- Stamp every scan row in this session.
  update public.casino_scans
    set finalized_at = coalesce(finalized_at, now())
    where session_id = p_session_id;

  return v_forfeited;
end;
$function$;

-- =====================================================================
-- 5. One-time conversion: repair the double-count, then Test Room
--    top-up (owner request 2026-08-16: every member to 200).
-- =====================================================================

-- 5a. Reverse the erroneous withdraw debits. Under the old model
-- every withdrawal debited balance AND score; under the new model
-- the principal is a reservation. Credit both back, one ledger row
-- per member-room so the repair is auditable. (casino_withdrawals
-- has no room_id — derive it from the session's event.)
with w as (
  select e.room_id, cw.member_id,
         sum(cw.points_withdrawn)::bigint as total_withdrawn
  from public.casino_withdrawals cw
  join public.events e on e.id = cw.session_id
  group by e.room_id, cw.member_id
)
update public.room_memberships m
set points_balance = m.points_balance + w.total_withdrawn,
    season_score   = m.season_score   + w.total_withdrawn
from w
where m.room_id = w.room_id
  and m.user_id = w.member_id
  and w.total_withdrawn <> 0;

with w as (
  select e.room_id, cw.member_id,
         sum(cw.points_withdrawn)::bigint as total_withdrawn
  from public.casino_withdrawals cw
  join public.events e on e.id = cw.session_id
  group by e.room_id, cw.member_id
)
insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
select w.room_id, null::uuid, w.member_id, 'bonus_topup', w.total_withdrawn,
       jsonb_build_object('reason', '074 conversion: withdraw principal credited back (reservation model)'),
       w.member_id
from w
where w.total_withdrawn <> 0;

-- 5b. Test Room top-up: floor every member at 200 (bonus semantics
-- are additive — never take points away). The ledger row is written
-- FIRST so it computes the delta from the pre-update balance.
insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
select m.room_id, null::uuid, m.user_id, 'bonus_topup', 200 - m.points_balance,
       jsonb_build_object('reason', 'Test Room starting bonus top-up (owner request)'),
       m.user_id
from public.room_memberships m
where m.room_id = '5815d5bc-05aa-4f2b-9db8-bbc2b5102e1b'
  and m.points_balance < 200;

update public.room_memberships m
set points_balance = 200
where m.room_id = '5815d5bc-05aa-4f2b-9db8-bbc2b5102e1b'
  and m.points_balance < 200;

-- NOTE (client follow-up, not SQL): the app surfaces season standings
-- from season_score; the conversion moved it. Acceptable — Test Room
-- is a sandbox. A future migration can recompute season_score from
-- the ledger if standings need exact repair.

-- =====================================================================
-- 6. get_withdrawal_balance — available = balance − open E
-- =====================================================================
-- Under 074 the raw balance includes chips already committed to the
-- table (open entitlement E). The withdraw sheet must only offer
-- what the reservation gate will accept: balance − E.
create or replace function public.get_withdrawal_balance(p_event_id uuid, p_user_id uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $function$
  select m.points_balance - (
    coalesce((select cs.vision_amount_points
              from public.casino_scans cs
              where cs.session_id = p_event_id
                and cs.member_id = p_user_id
              order by cs.recorded_at desc
              limit 1), 0)
    +
    coalesce((select sum(cw.points_withdrawn)
              from public.casino_withdrawals cw
              where cw.session_id = p_event_id
                and cw.member_id = p_user_id
                and not exists (
                  select 1 from public.casino_scans cs2
                  where cs2.session_id = p_event_id
                    and cs2.member_id = p_user_id
                    and cs2.recorded_at >= cw.withdrawn_at
                )), 0)
  )::bigint
  from public.room_memberships m
  join public.events e on e.id = p_event_id
  where m.room_id = e.room_id and m.user_id = p_user_id
  limit 1;
$function$;

grant execute on function public.get_withdrawal_balance(uuid, uuid) to authenticated;

