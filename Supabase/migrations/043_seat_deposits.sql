-- 043: F-MVP-04 — Seat deposits with refund / forfeit.
--
-- When a member claims a seat, a configurable number of virtual points
-- is held as a deposit. If the member attends (checked in by the host),
-- the deposit is refunded. If they no-show, the deposit is forfeited
-- and redistributed to the attending members.
--
-- The deposit amount is per-room (column on rooms). Zero means
-- "deposits disabled" — the seat-claim flow skips the hold entirely.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/043_seat_deposits.sql

-- 1. Per-room deposit configuration.
alter table public.rooms
  add column if not exists seat_deposit_amount integer not null default 0;

-- 2. Seat deposits table — one row per (event, user) that has a
--    deposit held. Status transitions: held → refunded | forfeited.
create table if not exists public.seat_deposits (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  amount integer not null,
  status text not null default 'held'
    check (status in ('held', 'refunded', 'forfeited')),
  held_at timestamptz not null default now(),
  settled_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

create index if not exists seat_deposits_event_idx
  on public.seat_deposits using btree (event_id);
create index if not exists seat_deposits_room_user_idx
  on public.seat_deposits using btree (room_id, user_id);
create index if not exists seat_deposits_status_idx
  on public.seat_deposits using btree (status)
  where status = 'held';

alter table public.seat_deposits enable row level security;

create policy "members read deposits in their rooms" on public.seat_deposits
  for select using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = seat_deposits.room_id
        and m.user_id = public.current_user_id()
    )
  );

create policy "no direct deposit writes" on public.seat_deposits
  for insert with check (false);

-- 3. hold_seat_deposit — called when a member claims a seat and the
--    room has a non-zero deposit amount. Deducts from points_balance,
--    inserts a seat_deposits row. Idempotent on (event_id, user_id).
create or replace function public.hold_seat_deposit(
  p_event_id uuid,
  p_user_id uuid default null
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := coalesce(p_user_id, public.current_user_id());
  v_room_id uuid;
  v_amount integer;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_amount
    into v_room_id, v_amount
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_amount is null or v_amount = 0 then
    return true; -- deposits disabled for this room
  end if;

  -- Only hold if not already held.
  if exists (
    select 1 from public.seat_deposits
    where event_id = p_event_id and user_id = v_caller
  ) then
    return true;
  end if;

  -- Deduct from the member's balance.
  update public.room_memberships
    set points_balance = points_balance - v_amount
    where room_id = v_room_id and user_id = v_caller;

  insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
  values (p_event_id, v_room_id, v_caller, v_amount, 'held');

  return true;
end;
$$;

grant execute on function public.hold_seat_deposit(uuid, uuid) to authenticated;

-- 4. settle_seat_deposits — called by the host after the event.
--    Members who have an event_seats row AND attended (checked in)
--    get refunded. Members who claimed but did not attend get
--    forfeited, and the forfeited pool is redistributed evenly to
--    those who did attend.
--
--    Attendance is proxied by: the member has a seat AND either
--    (a) they have a casino settlement transaction for this event,
--    or (b) they have a round_score transaction for this event.
create or replace function public.settle_seat_deposits(
  p_event_id uuid
)
returns table (
  refunded_count integer,
  forfeited_count integer,
  redistributed_total integer
)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_attended_count integer;
  v_forfeited_pool integer;
  v_redistribution integer;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id and r.created_by = v_caller;

  if v_room_id is null then
    raise exception 'Only the host can settle deposits' using errcode = '42501';
  end if;

  -- Determine attendance for each held deposit.
  for v_deposit in
    select sd.id, sd.user_id, sd.amount
    from public.seat_deposits sd
    where sd.event_id = p_event_id and sd.status = 'held'
  loop
    -- Attended = has a transaction for this event.
    if exists (
      select 1 from public.transactions t
      where t.session_id = p_event_id
        and t.member_id = v_deposit.user_id
        and t.room_id = v_room_id
    ) then
      -- Refund: return the deposit to the member's balance.
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_room_id and user_id = v_deposit.user_id;

      update public.seat_deposits
        set status = 'refunded', settled_at = now()
        where id = v_deposit.id;
    else
      -- Forfeit: the deposit stays in the pool for redistribution.
      update public.seat_deposits
        set status = 'forfeited', settled_at = now()
        where id = v_deposit.id;
    end if;
  end loop;

  -- Count results and redistribute the forfeited pool.
  select count(*) into v_attended_count
  from public.seat_deposits
  where event_id = p_event_id and status = 'refunded';

  select coalesce(sum(amount), 0) into v_forfeited_pool
  from public.seat_deposits
  where event_id = p_event_id and status = 'forfeited';

  if v_attended_count > 0 and v_forfeited_pool > 0 then
    v_redistribution := v_forfeited_pool / v_attended_count;
    update public.room_memberships
      set points_balance = points_balance + v_redistribution
      where room_id = v_room_id
        and user_id in (
          select user_id from public.seat_deposits
          where event_id = p_event_id and status = 'refunded'
        );
  else
    v_redistribution := 0;
  end if;

  return query
    select
      v_attended_count,
      (select count(*) from public.seat_deposits
       where event_id = p_event_id and status = 'forfeited')::integer,
      v_redistribution;
end;
$$;

grant execute on function public.settle_seat_deposits(uuid) to authenticated;

-- 5. get_my_seat_deposit — returns the calling member's deposit for
--    an event, if any. Used by the iOS seat-claim UI to show the
--    held amount.
create or replace function public.get_my_seat_deposit(
  p_event_id uuid
)
returns table (
  id uuid,
  amount integer,
  status text,
  held_at timestamptz
)
language sql
security definer
stable
as $$
  select id, amount, status, held_at
  from public.seat_deposits
  where event_id = p_event_id
    and user_id = public.current_user_id();
$$;

grant execute on function public.get_my_seat_deposit(uuid) to authenticated;

-- 6. Include seat_deposit_amount in get_my_rooms.
drop function if exists public.get_my_rooms();
create function public.get_my_rooms()
returns table (
  id uuid,
  name text,
  mascot_name text,
  mascot_personality public.mascot_personality,
  mascot_political_ideology text,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  is_live boolean,
  next_event_description text,
  join_starting_bonus integer,
  mascot_api_key text,
  seat_deposit_amount integer,
  user_role text
)
language sql
security definer
stable
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    r.join_starting_bonus,
    r.mascot_api_key,
    r.seat_deposit_amount,
    m.role::text as user_role
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;
