-- 113_seat_flows.sql
-- Lane S3 — seat flows: releasing a seat gives the deposit back,
-- re-claiming really claims, a full night says so, and the arrival
-- list only shows people who are actually coming.
--
-- Bodies start from the LIVE definitions pulled 2026-11-08
-- (docs/audit/2026-11-08/live-functions.sql). The live shape is the
-- spec. This lane writes migrations, it never applies them: TARS
-- pushes this file.
--
-- 1. release_seat(p_event_id, p_state) — NEW. Sets the caller's
--    RSVP to 'unclaimed' or 'declined' and, when the caller holds a
--    deposit for that night, returns it exactly the way
--    check_in_seat returns one: status 'returned', returned_at set,
--    the balance credited, a seat_deposit_return row on the ledger.
--    One transaction, so releasing never costs a member their
--    deposit.
-- 2. claim_seat_with_deposit — recreated. The early-return guard
--    now skips the deposit only while one is still 'held', and the
--    RSVP is ALWAYS upserted to claimed. Capacity: P0001
--    'night_full' when the claimed count has reached the room's
--    max_seats and the caller does not already hold a seat.
-- 3. upsert_event_rsvp — recreated with the same capacity guard.
-- 4. list_arrival_candidates — recreated: only members whose RSVP
--    is claimed can sit on the arrival card, so releasing politely
--    keeps a member off the host's forfeit list.
--
-- 012a's release_seat(uuid) (the dormant event_seats delete) is left
-- alone: the new signature does not collide with it.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/113_seat_flows.sql
--
-- Post-apply verification:
--   select pg_get_function_arguments('public.release_seat(uuid, text)'::regprocedure);
--   select pg_get_functiondef('public.claim_seat_with_deposit(uuid)'::regprocedure);
--   select pg_get_functiondef('public.list_arrival_candidates(uuid)'::regprocedure);

begin;

-- ---------------------------------------------------------------------------
-- 1. release_seat(p_event_id, p_state)
--
-- The member's own way out of a night. Releasing or declining a seat
-- used to write the RSVP only, which left the deposit sitting in
-- escrow until the host forfeited it: the considerate member got
-- fined for changing their mind. This returns the deposit in the
-- same shape check_in_seat returns one, in one transaction.
-- ---------------------------------------------------------------------------
create or replace function public.release_seat(p_event_id uuid, p_state text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_state is null or p_state not in ('unclaimed', 'declined') then
    raise exception 'bad_release_state' using errcode = '22023';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Member gate: only an active member releases their own seat.
  if not exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id
      and m.user_id = v_caller
      and m.membership_status = 'active'
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- The RSVP moves first: this is the member's own seat.
  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
  values (p_event_id, v_room_id, v_caller, p_state::public.event_rsvp_state, now())
  on conflict (event_id, member_id) do update set
    state = excluded.state,
    responded_at = excluded.responded_at;

  -- A held deposit returns exactly the way check_in_seat returns one.
  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is not null then
    update public.seat_deposits
      set status = 'returned', returned_at = now(), settled_at = now()
      where id = v_deposit.id;

    if v_deposit.amount > 0 then
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_room_id and user_id = v_caller;

      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_room_id, p_event_id, v_caller, 'seat_deposit_return', v_deposit.amount,
        jsonb_build_object('via', 'release', 'deposit_id', v_deposit.id),
        v_caller
      );
    end if;
  end if;

  return true;
end;
$$;

revoke all on function public.release_seat(uuid, text) from public, anon;
grant execute on function public.release_seat(uuid, text) to authenticated;

comment on function public.release_seat(uuid, text) is
  'S3.1 — member releases or declines their own seat: the RSVP moves to the given state and a held seat deposit returns to the balance in the same transaction (the check_in_seat return path). Idempotent.';

-- ---------------------------------------------------------------------------
-- 2. claim_seat_with_deposit(p_event_id)
--
-- Live body, three changes:
--   a. the early-return guard only skips the deposit while one is
--      still 'held'. A released seat re-takes the deposit on the
--      next claim, and the RSVP is ALWAYS upserted to claimed, so
--      "change your mind" tells the server the truth.
--   b. capacity: a table has a fixed number of chairs. When the
--      claimed count has reached the room's max_seats the night is
--      full and the claim fails with P0001 'night_full'. Somebody
--      who already holds a seat is never blocked.
--   c. the event row is locked for the claim so two members cannot
--      both take the last chair.
-- ---------------------------------------------------------------------------
create or replace function public.claim_seat_with_deposit(p_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_amount integer;
  v_trigger text;
  v_balance integer;
  v_max_seats integer;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_amount, r.seat_deposit_trigger, r.max_seats
    into v_room_id, v_amount, v_trigger, v_max_seats
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Membership gate: only an active room member can claim.
  select m.points_balance into v_balance
  from public.room_memberships m
  where m.room_id = v_room_id
    and m.user_id = v_caller
    and m.membership_status = 'active';

  if v_balance is null then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- One claim at a time per night: two members cannot both take the
  -- last chair.
  perform 1 from public.events where id = p_event_id for update;

  -- Capacity. The caller who already holds a seat may always refresh
  -- it; everybody else needs a free chair.
  if v_max_seats is not null and v_max_seats > 0
     and not exists (
       select 1 from public.event_rsvps r
       where r.event_id = p_event_id
         and r.member_id = v_caller
         and r.state = 'claimed'
     )
     and (
       select count(*)
       from public.event_rsvps r
       where r.event_id = p_event_id
         and r.state = 'claimed'
         and exists (
           select 1 from public.room_memberships m
           where m.room_id = r.room_id
             and m.user_id = r.member_id
             and m.membership_status = 'active'
         )
     ) >= v_max_seats then
    raise exception 'night_full' using errcode = 'P0001';
  end if;

  -- Escrow off (or zero amount): plain claim, no deposit row.
  -- The RSVP upsert below is the whole effect.
  if v_amount is null or v_amount = 0 or v_trigger = 'off' then
    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
      values (p_event_id, v_room_id, v_caller, 'claimed', now())
      on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
    return true;
  end if;

  -- A deposit still in escrow means the seat is already paid for:
  -- no second debit, ever. The RSVP is upserted below either way.
  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    if v_balance < v_amount then
      raise exception 'Balance too low for the seat deposit (% CC needed)', v_amount
        using errcode = '42501';
    end if;

    update public.room_memberships
      set points_balance = points_balance - v_amount
      where room_id = v_room_id and user_id = v_caller;

    -- A released seat re-takes the deposit: the row goes back into
    -- escrow. The ledger keeps what happened the first time round.
    insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
      values (p_event_id, v_room_id, v_caller, v_amount, 'held')
      on conflict (event_id, user_id) do update set
        amount = excluded.amount,
        status = 'held',
        held_at = now(),
        returned_at = null,
        forfeited_at = null,
        forfeited_by = null,
        settled_at = null;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, v_caller, 'seat_deposit', v_amount,
      jsonb_build_object('direction', 'escrow'),
      v_caller
    );
  end if;

  -- Always: the seat is claimed, deposit or no deposit.
  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, v_caller, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  return true;
end;
$$;

revoke all on function public.claim_seat_with_deposit(uuid) from public, anon;
grant execute on function public.claim_seat_with_deposit(uuid) to authenticated, service_role;

comment on function public.claim_seat_with_deposit(uuid) is
  'S3.1 — member claims a seat; the room''s seat deposit leaves points_balance into escrow and the RSVP is always upserted to claimed. A released seat re-takes the deposit. P0001 ''night_full'' when the claimed count has reached the room''s max_seats.';

-- ---------------------------------------------------------------------------
-- 3. upsert_event_rsvp(p_event_id, p_state, p_target_member_id)
--
-- Live body plus the same capacity guard: claiming on a full night
-- fails with P0001 'night_full' instead of promising a chair that
-- is not there. Unclaiming and declining are never blocked.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_event_rsvp(p_event_id uuid, p_state text, p_target_member_id uuid DEFAULT NULL::uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
    v_caller uuid := auth.uid();
    v_target uuid := coalesce(p_target_member_id, v_caller);
    v_room uuid;
    v_max_seats integer;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    -- The event decides the room.
    select e.room_id into v_room
    from public.events e
    where e.id = p_event_id;

    if v_room is null then
        raise exception 'Event not found' using errcode = 'P0002';
    end if;

    if v_target <> v_caller then
        -- Host gate: only a host answers for another member.
        if not public.is_room_host(v_room, v_caller) then
            raise exception 'Only the host can update another member''s RSVP'
                using errcode = '42501';
        end if;
    else
        -- Member gate: only an active member answers for themselves.
        if not exists (
            select 1 from public.room_memberships m
            where m.room_id = v_room
              and m.user_id = v_caller
              and m.membership_status = 'active'
        ) then
            raise exception 'Not a member of this room' using errcode = '42501';
        end if;
    end if;

    -- Capacity. Only a claim can hit a full table; the caller who
    -- already holds a seat may always refresh it.
    if p_state = 'claimed' then
        select r.max_seats into v_max_seats
        from public.rooms r
        where r.id = v_room;

        perform 1 from public.events where id = p_event_id for update;

        if v_max_seats is not null and v_max_seats > 0
           and not exists (
               select 1 from public.event_rsvps r
               where r.event_id = p_event_id
                 and r.member_id = v_caller
                 and r.state = 'claimed'
           )
           and (
               select count(*)
               from public.event_rsvps r
               where r.event_id = p_event_id
                 and r.state = 'claimed'
                 and exists (
                   select 1 from public.room_memberships m
                   where m.room_id = r.room_id
                     and m.user_id = r.member_id
                     and m.membership_status = 'active'
                 )
           ) >= v_max_seats then
            raise exception 'night_full' using errcode = 'P0001';
        end if;
    end if;

    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room, v_target, p_state::event_rsvp_state, now())
    on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
end;
$function$;

revoke all on function public.upsert_event_rsvp(uuid, text, uuid) from public, anon;
grant execute on function public.upsert_event_rsvp(uuid, text, uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. list_arrival_candidates(p_event_id)
--
-- Live body plus one filter: only members whose RSVP is claimed can
-- sit on the arrival card. A member who released their seat two days
-- early no longer shows up on the host's arrival list with a
-- Forfeit button waiting for them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_arrival_candidates(p_event_id uuid)
 RETURNS TABLE(user_id uuid, display_name text, deposit_amount integer, status text, within_grace boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with event_row as (
    select e.id, e.room_id, e.played_at, r.created_by,
           r.seat_deposit_grace_minutes
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.id = p_event_id
  ),
  unresolved as (
    select sd.user_id, sd.amount, sd.status::text as status
    from public.seat_deposits sd
    where sd.event_id = p_event_id
      and sd.status = 'held'
      and exists (
        select 1 from public.event_rsvps r
        where r.event_id = p_event_id
          and r.member_id = sd.user_id
          and r.state = 'claimed'
      )
      and not exists (
        select 1 from public.transactions t
        where t.session_id = p_event_id
          and t.member_id = sd.user_id
          and t.kind not in (
            'seat_deposit', 'seat_deposit_return',
            'seat_deposit_forfeit', 'seat_deposit_waive',
            'no_show_tax', 'no_show_tax_waiver'
          )
      )
  )
  select
    u.id as user_id,
    coalesce(u.display_name, 'Member') as display_name,
    un.amount as deposit_amount,
    un.status,
    (now() < event_row.played_at + make_interval(mins => event_row.seat_deposit_grace_minutes)) as within_grace
  from unresolved un
  cross join event_row
  join public.users u on u.id = un.user_id
  where public.is_room_host(event_row.room_id, public.current_user_id());
$function$;

revoke all on function public.list_arrival_candidates(uuid) from public, anon;
grant execute on function public.list_arrival_candidates(uuid) to authenticated, service_role;

comment on function public.list_arrival_candidates(uuid) is
  'S3.1 — host-only arrival list: held deposits with no play transaction, and only for members whose RSVP is still claimed. A released seat is not a no-show.';

commit;
