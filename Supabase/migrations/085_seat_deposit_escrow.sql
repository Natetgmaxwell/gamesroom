-- 085: V0.85 — seat deposit as real escrow (reframes 082's no-show tax).
--
-- A tax needs enforcement; a deposit needs only a reclaim. The
-- reclaim tap IS the attendance check-in: the member wants their
-- chips back, so attendance records itself without the host
-- marking anyone. The host's only decision is the forfeit at
-- session start (locked C3: the host always decides; the system
-- never decides alone).
--
-- Workflow: claim → deposit leaves balance into escrow; arrive →
-- "I'm here" returns it; no-show → host forfeits / skips; proof-
-- fallback → a settle transaction auto-returns any held deposit.
--
-- Changes:
--   1. rooms: no_show_tax_* → seat_deposit_* (amount default 200,
--      trigger 'escrow'|'off' — the old auto/prompt/manual
--      collapse into 'escrow' + host forfeit-confirm; grace
--      minutes default 10; destination next_pot|host_charity_pot|
--      split). The dormant 043 rooms.seat_deposit_amount column
--      (never live — no RPC call site since V0.8) is dropped so
--      the name is free for the renamed no_show_tax_amount.
--   2. seat_deposits (043) extended: status gains 'returned' and
--      'waived' ('refunded' mapped to 'returned' — 043 never
--      shipped a live caller, so the mapping is cosmetic), plus
--      returned_at / forfeited_at / forfeited_by columns.
--   3. Superseded RPCs dropped: hold_seat_deposit, settle_seat_
--      deposits, get_my_seat_deposit (043, dormant), list_no_show_
--      candidates, apply_no_show_tax, skip_no_show_tax (082).
--   4. New RPCs (idempotent, guarded):
--      claim_seat_with_deposit(p_event_id) — member; RSVP claim +
--      deposit into escrow; 42501 when balance < amount.
--      claim_seat_waived(p_event_id, p_member_id) — host-waiver
--      for broke members: RSVP claim + zero-amount held row so
--      the arrival card still tracks the seat.
--      check_in_seat(p_event_id) — member; "I'm here"; deposit
--      returns instantly. Idempotent.
--      list_arrival_candidates(p_event_id) — host; held deposits
--      with no check-in and no play transaction.
--      forfeit_seat_deposit(p_event_id, p_member_id) — host-only.
--      waive_seat_deposit(p_event_id, p_member_id) — host-only.
--      auto_return_on_settle() — INSERT trigger on transactions:
--      any play-kind row returns that member+event's held
--      deposit. Played = present, no forfeit.
--   5. Ledger kinds: seat_deposit / seat_deposit_return /
--      seat_deposit_forfeit / seat_deposit_waive (replaces
--      no_show_tax / no_show_tax_waiver). The play-detection set
--      excludes the deposit kinds themselves so the escrow rows
--      never masquerade as attendance.
--   6. update_room_settings rebuilt (17-arg, renamed params);
--      get_my_rooms rebuilt (returns the renamed columns).
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/085_seat_deposit_escrow.sql
--
-- Post-apply verification:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='rooms'
--     and column_name like 'seat_deposit_%';
--   select pg_get_function_arguments('public.claim_seat_with_deposit(uuid)'::regprocedure);
--   select pg_get_function_arguments('public.list_arrival_candidates(uuid)'::regprocedure);
--   select tgname from pg_trigger
--     where tgrelid='public.transactions'::regclass and tgname='transactions_auto_return_deposit';

-- 1. Column renames. Idempotent per-column guards so a re-run is
--    safe (rename fails hard when the target already exists).
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rooms'
      and column_name = 'no_show_tax_amount'
  ) then
    alter table public.rooms drop column if exists seat_deposit_amount;
    alter table public.rooms rename column no_show_tax_amount to seat_deposit_amount;
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rooms'
      and column_name = 'no_show_tax_trigger'
  ) then
    alter table public.rooms rename column no_show_tax_trigger to seat_deposit_trigger;
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rooms'
      and column_name = 'no_show_tax_grace_minutes'
  ) then
    alter table public.rooms rename column no_show_tax_grace_minutes to seat_deposit_grace_minutes;
  end if;
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'rooms'
      and column_name = 'no_show_tax_destination'
  ) then
    alter table public.rooms rename column no_show_tax_destination to seat_deposit_destination;
  end if;
end $$;

-- Trigger domain collapse: auto/prompt/manual → escrow. Constraint
-- swap first (old CHECK would reject nothing here, but the new
-- domain is narrower so replace it atomically with the update).
alter table public.rooms drop constraint if exists rooms_no_show_tax_trigger_check;
alter table public.rooms drop constraint if exists rooms_seat_deposit_trigger_check;
update public.rooms
  set seat_deposit_trigger = 'escrow'
  where seat_deposit_trigger not in ('escrow', 'off');
alter table public.rooms
  add constraint rooms_seat_deposit_trigger_check
  check (seat_deposit_trigger in ('escrow', 'off'));

-- Rename the surviving bounds constraints so the catalog reads
-- consistently (values unchanged).
alter table public.rooms drop constraint if exists rooms_no_show_tax_amount_range;
alter table public.rooms
  add constraint rooms_seat_deposit_amount_range
  check (seat_deposit_amount between 0 and 1000);
alter table public.rooms drop constraint if exists rooms_no_show_tax_grace_range;
alter table public.rooms
  add constraint rooms_seat_deposit_grace_range
  check (seat_deposit_grace_minutes between 0 and 120);
alter table public.rooms drop constraint if exists rooms_no_show_tax_destination_check;
alter table public.rooms
  add constraint rooms_seat_deposit_destination_check
  check (seat_deposit_destination in ('next_pot', 'host_charity_pot', 'split'));

-- 2. seat_deposits extension. 043's status CHECK gains returned /
--    waived; legacy 'refunded' rows (none in prod — the 043 path
--    never shipped a caller) map forward.
alter table public.seat_deposits
  add column if not exists returned_at timestamptz;
alter table public.seat_deposits
  add column if not exists forfeited_at timestamptz;
alter table public.seat_deposits
  add column if not exists forfeited_by uuid references public.users(id) on delete set null;

alter table public.seat_deposits drop constraint if exists seat_deposits_status_check;
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'seat_deposits_status_check'
      and conrelid = 'public.seat_deposits'::regclass
  ) then
    execute $con$
      alter table public.seat_deposits
        add constraint seat_deposits_status_check
        check (status in ('held', 'returned', 'forfeited', 'waived', 'refunded'))
    $con$;
  end if;
end $$;
update public.seat_deposits set status = 'returned' where status = 'refunded';

-- 3. Superseded RPCs out. 043's trio was dormant (no iOS call
--    site since V0.8); 082's trio is reframed by the RPCs below.
drop function if exists public.hold_seat_deposit(uuid, uuid);
drop function if exists public.settle_seat_deposits(uuid);
drop function if exists public.get_my_seat_deposit(uuid);
drop function if exists public.list_no_show_candidates(uuid);
drop function if exists public.apply_no_show_tax(uuid, uuid, text);
drop function if exists public.skip_no_show_tax(uuid, uuid, text);

-- 4a. claim_seat_with_deposit(p_event_id) — member. Charges the
--     room's seat_deposit_amount from points_balance into escrow,
--     inserts the held seat_deposits row, and writes the RSVP
--     claim (same upsert shape as migration 061's
--     upsert_event_rsvp). Idempotent per (event, member): an
--     existing deposit row of any status short-circuits before
--     the debit. Fails 42501 when balance < amount (broke members
--     take the host-waiver path: claim_seat_waived).
create or replace function public.claim_seat_with_deposit(
  p_event_id uuid
)
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
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_amount, r.seat_deposit_trigger
    into v_room_id, v_amount, v_trigger
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Membership gate: only a room member can claim.
  select m.points_balance into v_balance
  from public.room_memberships m
  where m.room_id = v_room_id and m.user_id = v_caller;

  if v_balance is null then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Idempotent: an existing deposit row of any status means the
  -- claim already happened. No second debit, ever.
  if exists (
    select 1 from public.seat_deposits
    where event_id = p_event_id and user_id = v_caller
  ) then
    return true;
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

  if v_balance < v_amount then
    raise exception 'Balance too low for the seat deposit (% CC needed)', v_amount
      using errcode = '42501';
  end if;

  update public.room_memberships
    set points_balance = points_balance - v_amount
    where room_id = v_room_id and user_id = v_caller;

  insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
    values (p_event_id, v_room_id, v_caller, v_amount, 'held');

  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, v_caller, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, v_caller, 'seat_deposit', v_amount,
    jsonb_build_object('direction', 'escrow'),
    v_caller
  );

  return true;
end;
$$;

grant execute on function public.claim_seat_with_deposit(uuid) to authenticated;

comment on function public.claim_seat_with_deposit(uuid) is 'V0.85 — member claims a seat; the room''s seat deposit leaves points_balance into escrow (seat_deposits row, status held) and the RSVP flips to claimed. Idempotent per (event, member). Fails 42501 when balance < amount — broke members take claim_seat_waived.';

-- 4b. claim_seat_waived(p_event_id, p_member_id) — host-only.
--     The broke-member path: the host waives the deposit at claim
--     time. A zero-amount held row keeps the seat tracked on the
--     arrival card; every resolution path is chip-neutral.
create or replace function public.claim_seat_waived(
  p_event_id uuid,
  p_member_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id and r.created_by = v_caller;

  if v_room_id is null then
    raise exception 'Only the host can waive a seat deposit at claim' using errcode = '42501';
  end if;

  if exists (
    select 1 from public.seat_deposits
    where event_id = p_event_id and user_id = p_member_id
  ) then
    return true;
  end if;

  insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
    values (p_event_id, v_room_id, p_member_id, 0, 'held');

  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, p_member_id, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, p_member_id, 'seat_deposit_waive', 0,
    jsonb_build_object('at_claim', true),
    v_caller
  );

  return true;
end;
$$;

grant execute on function public.claim_seat_waived(uuid, uuid) to authenticated;

comment on function public.claim_seat_waived(uuid, uuid) is 'V0.85 — host-only broke-member path. Claims the seat with a zero-amount held deposit row (chip-neutral at every resolution) and records the waiver on the public ledger. Idempotent per (event, member).';

-- 4c. check_in_seat(p_event_id) — member. The "I'm here" tap:
--     the held deposit returns instantly. This is the reclaim
--     AND the attendance check-in. Idempotent: already returned /
--     no held row → no-op success.
create or replace function public.check_in_seat(
  p_event_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select sd.id, sd.room_id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- nothing held: already checked in, waived, or no deposit
  end if;

  update public.seat_deposits
    set status = 'returned', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_deposit.room_id and user_id = v_caller;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_deposit.room_id, p_event_id, v_caller, 'seat_deposit_return', v_deposit.amount,
      jsonb_build_object('via', 'check_in'),
      v_caller
    );
  end if;

  return true;
end;
$$;

grant execute on function public.check_in_seat(uuid) to authenticated;

comment on function public.check_in_seat(uuid) is 'V0.85 — member''s "I''m here" tap. Returns the held deposit to points_balance and stamps the row returned. The reclaim is the check-in: attendance records itself. Idempotent.';

-- 4d. list_arrival_candidates(p_event_id) — host-only. One row
--     per held deposit (claimed, never checked in) whose member
--     has no PLAY transaction for the event. The deposit kinds
--     and the legacy 082 no-show kinds are excluded from the
--     play-detection set — the escrow ledger rows are not
--     attendance.
create or replace function public.list_arrival_candidates(p_event_id uuid)
returns table (
  user_id uuid,
  display_name text,
  deposit_amount integer,
  status text,
  within_grace boolean
)
language sql
security definer
stable
set search_path = public
as $$
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
  where event_row.created_by = public.current_user_id();
$$;

grant execute on function public.list_arrival_candidates(uuid) to authenticated;

comment on function public.list_arrival_candidates(uuid) is 'V0.85 — host-only arrival card source. One row per held seat deposit (claimed, no check-in, no play transaction) at session start. Read-only; the host decides forfeit vs skip per row.';

-- 4e. forfeit_seat_deposit(p_event_id, p_member_id) — host-only.
--     The host's confirmed no-show call. Deposit → forfeited;
--     the chips never return (they left at claim). The public
--     ledger row carries the destination for the next-pot slice.
--     Idempotent per (event, member).
create or replace function public.forfeit_seat_deposit(
  p_event_id uuid,
  p_member_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_destination text;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_destination into v_room_id, v_destination
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can forfeit a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'forfeited', forfeited_at = now(), forfeited_by = v_caller, settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_forfeit', v_deposit.amount,
      jsonb_build_object('destination', v_destination, 'deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$$;

grant execute on function public.forfeit_seat_deposit(uuid, uuid) to authenticated;

comment on function public.forfeit_seat_deposit(uuid, uuid) is 'V0.85 — host-only confirmed no-show. Held deposit → forfeited (the chips stay out of the member''s balance; they left at claim). Ledger row carries the destination meta for the next-pot crediting slice. Idempotent.';

-- 4f. waive_seat_deposit(p_event_id, p_member_id) — host-only.
--     Returns a held deposit without requiring the tap: the
--     host's face-saving call (member texted / away / arrived
--     without tapping). Idempotent.
create or replace function public.waive_seat_deposit(
  p_event_id uuid,
  p_member_id uuid
)
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

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can waive a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'waived', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_room_id and user_id = p_member_id;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_waive', v_deposit.amount,
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$$;

grant execute on function public.waive_seat_deposit(uuid, uuid) to authenticated;

comment on function public.waive_seat_deposit(uuid, uuid) is 'V0.85 — host-only. Returns a held deposit without the member''s tap (texted / away / arrived-unscanned). Balance restored, ledger row records the host''s call. Idempotent.';

-- 4g. auto_return_on_settle() — the proof-fallback. Any PLAY
--     transaction (settle, round score, withdrawal — anything
--     outside the deposit + legacy no-show kinds) returns the
--     member+event's held deposit automatically. Played =
--     present, no forfeit.
create or replace function public.auto_return_on_settle()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deposit record;
begin
  if new.kind in (
    'seat_deposit', 'seat_deposit_return',
    'seat_deposit_forfeit', 'seat_deposit_waive',
    'no_show_tax', 'no_show_tax_waiver'
  ) then
    return new;
  end if;

  for v_deposit in
    select sd.id, sd.room_id, sd.amount
    from public.seat_deposits sd
    where sd.event_id = new.session_id
      and sd.user_id = new.member_id
      and sd.status = 'held'
  loop
    update public.seat_deposits
      set status = 'returned', returned_at = now(), settled_at = now()
      where id = v_deposit.id;

    if v_deposit.amount > 0 then
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_deposit.room_id and user_id = new.member_id;

      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_deposit.room_id, new.session_id, new.member_id,
        'seat_deposit_return', v_deposit.amount,
        jsonb_build_object('via', 'settle_proof', 'deposit_id', v_deposit.id),
        new.created_by
      );
    end if;
  end loop;

  return new;
end;
$$;

drop trigger if exists transactions_auto_return_deposit on public.transactions;
create trigger transactions_auto_return_deposit
  after insert on public.transactions
  for each row execute function public.auto_return_on_settle();

-- 4h. get_my_seat_deposit_status(p_event_id) — replaces 043's
--     dropped get_my_seat_deposit. The caller's deposit row for
--     the event (held/returned/forfeited/waived), or no row.
--     Drives the iOS chair card's held state.
create or replace function public.get_my_seat_deposit_status(
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
set search_path = public
as $$
  select sd.id, sd.amount, sd.status, sd.held_at
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = public.current_user_id();
$$;

grant execute on function public.get_my_seat_deposit_status(uuid) to authenticated;

comment on function public.get_my_seat_deposit_status(uuid) is 'V0.85 — the calling member''s seat deposit for an event, or no row. Read-only; drives the chair card''s held/reclaim state.';

-- 5. update_room_settings — 17-arg signature, the four renamed
--    params. Drop the 082 overload first (repo convention).
drop function if exists public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer,
    integer, text, integer, text
);
create function public.update_room_settings(
    p_room_id uuid,
    p_name text,
    p_mascot_name text,
    p_mascot_personality text,
    p_mascot_political_ideology text,
    p_max_seats integer,
    p_member_invite_quota integer,
    p_join_starting_bonus integer,
    p_social_narration_enabled boolean,
    p_briefing_48h_enabled boolean,
    p_calendar_auto_add_host boolean,
    p_social_preferences_enabled boolean,
    p_auto_close_hours integer,
    p_seat_deposit_amount integer,
    p_seat_deposit_trigger text,
    p_seat_deposit_grace_minutes integer,
    p_seat_deposit_destination text
)
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
    user_role text,
    briefing_48h_enabled boolean,
    calendar_auto_add_host boolean,
    social_preferences_enabled boolean,
    social_narration_enabled boolean,
    max_seats integer,
    member_invite_quota integer,
    host_journal text,
    auto_close_hours integer,
    seat_deposit_amount integer,
    seat_deposit_trigger text,
    seat_deposit_grace_minutes integer,
    seat_deposit_destination text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_updated boolean := false;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  update public.rooms as r set
      name = p_name,
      mascot_name = p_mascot_name,
      mascot_personality = p_mascot_personality::mascot_personality,
      mascot_political_ideology = p_mascot_political_ideology,
      max_seats = p_max_seats,
      member_invite_quota = p_member_invite_quota,
      join_starting_bonus = p_join_starting_bonus,
      social_narration_enabled = p_social_narration_enabled,
      briefing_48h_enabled = p_briefing_48h_enabled,
      calendar_auto_add_host = p_calendar_auto_add_host,
      social_preferences_enabled = p_social_preferences_enabled,
      auto_close_hours = p_auto_close_hours,
      seat_deposit_amount = p_seat_deposit_amount,
      seat_deposit_trigger = p_seat_deposit_trigger,
      seat_deposit_grace_minutes = p_seat_deposit_grace_minutes,
      seat_deposit_destination = p_seat_deposit_destination,
      updated_at = now()
  where r.id = p_room_id and r.created_by = v_caller
  returning true into v_updated;

  if v_updated is not true then
    raise exception 'Room not found or caller is not the host' using errcode = '42501';
  end if;

  return query
  select
      r.id, r.name, r.mascot_name, r.mascot_personality,
      r.mascot_political_ideology,
      r.created_by, r.created_at, r.updated_at, r.is_live,
      r.next_event_description,
      r.join_starting_bonus,
      m.role::text as user_role,
      r.briefing_48h_enabled,
      r.calendar_auto_add_host,
      r.social_preferences_enabled,
      r.social_narration_enabled,
      r.max_seats,
      r.member_invite_quota,
      r.host_journal,
      r.auto_close_hours,
      r.seat_deposit_amount,
      r.seat_deposit_trigger,
      r.seat_deposit_grace_minutes,
      r.seat_deposit_destination
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id and m.user_id = v_caller;
end;
$$;

grant execute on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer,
    integer, text, integer, text
) to authenticated;

comment on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer,
    integer, text, integer, text
) is 'V0.85 — host-only room settings update. 17-arg signature carries the V0.83 auto-close window + the V0.85 seat-deposit escrow settings (amount, trigger escrow|off, grace, destination). Returns the full Room row.';

-- 6. get_my_rooms — rebuilt so the rooms list carries the renamed
--    columns on first load.
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
  user_role text,
  member_drowning_opt_in boolean,
  notifications_enabled boolean,
  overlap_count bigint,
  overlap_names text[],
  auto_close_hours integer,
  seat_deposit_amount integer,
  seat_deposit_trigger text,
  seat_deposit_grace_minutes integer,
  seat_deposit_destination text
)
language sql
security definer
stable
set search_path = public
as $$
  select
    r.id, r.name, r.mascot_name, r.mascot_personality,
    r.mascot_political_ideology,
    r.created_by, r.created_at, r.updated_at, r.is_live, r.next_event_description,
    r.join_starting_bonus,
    r.mascot_api_key,
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in,
    coalesce(m.notifications_enabled, false) as notifications_enabled,
    ov.overlap_count,
    ov.overlap_names,
    r.auto_close_hours,
    r.seat_deposit_amount,
    r.seat_deposit_trigger,
    r.seat_deposit_grace_minutes,
    r.seat_deposit_destination
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  left join lateral (
    select
      count(distinct other.user_id) as overlap_count,
      array_agg(distinct u.display_name) filter (where u.display_name is not null) as overlap_names
    from public.room_memberships other
    join public.room_memberships shared
      on shared.user_id = other.user_id
     and shared.room_id <> r.id
    join public.users u on u.id = other.user_id
    where other.room_id = r.id
      and other.user_id <> m.user_id
      and exists (
        select 1 from public.room_memberships mine
        where mine.user_id = m.user_id
          and mine.room_id = shared.room_id
      )
  ) ov on true
  where m.user_id = public.current_user_id()
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

-- 7. Refresh the PostgREST schema cache so the new return shapes
--    are immediately visible to the iOS app.
notify pgrst, 'reload schema';
