-- 082: V0.84 C3 — no-show tax as host prompt + room settings.
--
-- The no-show tax stops auto-firing. At session start the HOST sees
-- a mascot-voiced prompt per claimed-but-absent member with three
-- choices: Apply / Skip (texted) / Skip (away). The host always
-- decides; the system never decides alone. The forfeited chip moves
-- into the NEXT POT (public next-pot money), never against the
-- absent member's social standing. Drowning stays private. The
-- prompt is the only moment the no-show touches the room.
--
-- Substrate line (Carnegie 3.1 — don't argue; 4.5 — save face):
-- substrate never decides alone. The host decides what the room
-- does with the forfeited chip.
--
-- Changes:
--   1. rooms gains four settings columns mirroring migration 081's
--      shape: no_show_tax_amount integer (default 200, 0..1000),
--      no_show_tax_trigger text (default 'prompt', in
--      auto|prompt|manual), no_show_tax_grace_minutes integer
--      (default 10, 0..120), no_show_tax_destination text
--      (default 'next_pot', in next_pot|host_charity_pot|split).
--   2. update_room_settings — 17-arg signature (the four new
--      params). Drop the 13-arg overload first (repo convention,
--      migrations 061/081). Returns the four new columns.
--   3. get_my_rooms — returns the four new columns so the rooms
--      list carries the setting on first load.
--   4. RPC list_no_show_candidates(p_event_id) — host-only
--      (r.created_by = current_user_id()), SECURITY DEFINER,
--      search_path=public. Returns one row per claimed RSVP whose
--      owner has no transactions row for the event: user_id,
--      display_name, tax_amount (rooms.no_show_tax_amount),
--      within_grace boolean (now() < played_at + grace minutes).
--      No writes. Read-only prompt source.
--   5. RPC apply_no_show_tax(p_event_id, p_user_id, p_reason) —
--      host-only. Forfeits exactly one held seat deposit of the
--      room's no_show_tax_amount (uses the deposit row from 043
--      if present — inserts a transactions row kind='no_show_tax'
--      amount = tax with meta {reason, deposit_id}). Destination
--      honoured: next_pot → bank to next event's pot (meta flag);
--      host_charity_pot → meta destination='host_charity_pot';
--      split → meta destination='split'. Idempotent per
--      (event, user): if a no_show_tax transaction already exists
--      for the pair, return success without double-tax. Apply is
--      trigger-agnostic (manual mode allows the prompt too).
--   6. RPC skip_no_show_tax(p_event_id, p_user_id, p_reason) —
--      host-only. Inserts transactions row kind='no_show_tax_waiver',
--      amount 0, meta {reason: 'texted'|'away'}. Idempotent per
--      (event, user).
--   7. comment on function for each new RPC; grants to authenticated.
--   8. notify pgrst 'reload schema'.
--
-- Destination semantics (locked): the tax chips are RECORDED as a
-- public ledger row (kind='no_show_tax', member_id = the no-shower,
-- amount = tax) and applied to the next event's pot at its creation
-- — the client reads them via the existing ledger surfaces. No
-- membership balance changes for the no-shower at apply time when a
-- seat deposit was held (the deposit already debited the balance at
-- claim per 043). When NO deposit row exists (claim without
-- deposit), the apply RPC debits membership points_balance by tax
-- amount (the tax stands alone) and records the transaction.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/082_no_show_tax_settings.sql
--
-- Post-apply verification:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='rooms'
--     and column_name like 'no_show_tax_%';
--   select pg_get_function_arguments('public.list_no_show_candidates(uuid)'::regprocedure);
--   select pg_get_function_arguments('public.apply_no_show_tax(uuid,uuid,text)'::regprocedure);
--   select pg_get_function_arguments('public.skip_no_show_tax(uuid,uuid,text)'::regprocedure);

-- 1. Four settings columns + bounds. idempotent so a re-run is safe.
alter table public.rooms
  add column if not exists no_show_tax_amount integer not null default 200;
alter table public.rooms
  add column if not exists no_show_tax_trigger text not null default 'prompt';
alter table public.rooms
  add column if not exists no_show_tax_grace_minutes integer not null default 10;
alter table public.rooms
  add column if not exists no_show_tax_destination text not null default 'next_pot';

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'rooms_no_show_tax_amount_range'
      and conrelid = 'public.rooms'::regclass
  ) then
    alter table public.rooms
      add constraint rooms_no_show_tax_amount_range
      check (no_show_tax_amount between 0 and 1000);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'rooms_no_show_tax_trigger_check'
      and conrelid = 'public.rooms'::regclass
  ) then
    alter table public.rooms
      add constraint rooms_no_show_tax_trigger_check
      check (no_show_tax_trigger in ('auto', 'prompt', 'manual'));
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'rooms_no_show_tax_grace_range'
      and conrelid = 'public.rooms'::regclass
  ) then
    alter table public.rooms
      add constraint rooms_no_show_tax_grace_range
      check (no_show_tax_grace_minutes between 0 and 120);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conname = 'rooms_no_show_tax_destination_check'
      and conrelid = 'public.rooms'::regclass
  ) then
    alter table public.rooms
      add constraint rooms_no_show_tax_destination_check
      check (no_show_tax_destination in ('next_pot', 'host_charity_pot', 'split'));
  end if;
end $$;

-- 2. update_room_settings — drop the 13-arg overload first (repo
-- convention, migrations 061/081) and recreate with the four new
-- params. Returns the four new columns so the Swift layer's Room
-- mirror stays canonical.
drop function if exists public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer
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
    p_no_show_tax_amount integer,
    p_no_show_tax_trigger text,
    p_no_show_tax_grace_minutes integer,
    p_no_show_tax_destination text
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
    no_show_tax_amount integer,
    no_show_tax_trigger text,
    no_show_tax_grace_minutes integer,
    no_show_tax_destination text
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
      no_show_tax_amount = p_no_show_tax_amount,
      no_show_tax_trigger = p_no_show_tax_trigger,
      no_show_tax_grace_minutes = p_no_show_tax_grace_minutes,
      no_show_tax_destination = p_no_show_tax_destination,
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
      r.no_show_tax_amount,
      r.no_show_tax_trigger,
      r.no_show_tax_grace_minutes,
      r.no_show_tax_destination
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
) is 'V0.84 C3 — host-only room settings update. 17-arg signature carries the V0.83 auto-close window + the V0.84 C3 no-show-tax settings (amount, trigger, grace, destination). Returns the full Room row.';

-- 3. get_my_rooms — re-create so it returns the four new columns
-- alongside the existing room-list surface. The first-load decode
-- in the Swift layer mirrors these onto the Room struct.
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
  user_role text,
  member_drowning_opt_in boolean,
  notifications_enabled boolean,
  overlap_count bigint,
  overlap_names text[],
  auto_close_hours integer,
  no_show_tax_amount integer,
  no_show_tax_trigger text,
  no_show_tax_grace_minutes integer,
  no_show_tax_destination text
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
    r.seat_deposit_amount,
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in,
    coalesce(m.notifications_enabled, false) as notifications_enabled,
    ov.overlap_count,
    ov.overlap_names,
    r.auto_close_hours,
    r.no_show_tax_amount,
    r.no_show_tax_trigger,
    r.no_show_tax_grace_minutes,
    r.no_show_tax_destination
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

-- 4. list_no_show_candidates(p_event_id) — host-only. Returns one
-- row per claimed RSVP whose owner has no transactions row for the
-- event (i.e. they were absent). Read-only prompt source.
create or replace function public.list_no_show_candidates(p_event_id uuid)
returns table (
  user_id uuid,
  display_name text,
  tax_amount integer,
  within_grace boolean
)
language sql
security definer
stable
set search_path = public
as $$
  with event_row as (
    select e.id, e.room_id, e.played_at, r.created_by, r.no_show_tax_amount,
           r.no_show_tax_grace_minutes
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.id = p_event_id
  ),
  claimed_absent as (
    select er.member_id
    from public.event_rsvps er
    where er.event_id = p_event_id
      and er.state = 'claimed'
      and not exists (
        select 1 from public.transactions t
        where t.session_id = p_event_id
          and t.member_id = er.member_id
      )
  )
  select
    ca.member_id as user_id,
    coalesce(u.display_name, 'Member') as display_name,
    event_row.no_show_tax_amount as tax_amount,
    (now() < event_row.played_at + make_interval(mins => event_row.no_show_tax_grace_minutes)) as within_grace
  from claimed_absent ca
  cross join event_row
  left join public.users u on u.id = ca.member_id
  where event_row.created_by = public.current_user_id();
$$;

grant execute on function public.list_no_show_candidates(uuid) to authenticated;

comment on function public.list_no_show_candidates(uuid) is 'V0.84 C3 — host-only prompt source. Returns one row per claimed-but-absent member (claimed RSVP, no transactions row for the event). Read-only; the host decides apply vs skip from the Swift client.';

-- 5. apply_no_show_tax(p_event_id, p_user_id, p_reason) — host-only.
-- Forfeits exactly one held seat deposit of the room's
-- no_show_tax_amount. Idempotent per (event, user). Destination is
-- recorded in meta; the next-pot crediting is a downstream slice.
-- When no deposit row exists (claim without deposit), the apply
-- debits membership points_balance by tax amount so the tax stands
-- alone and the public ledger row carries it.
create or replace function public.apply_no_show_tax(
  p_event_id uuid,
  p_user_id uuid,
  p_reason text default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_tax_amount integer;
  v_destination text;
  v_already_taxed boolean;
  v_deposit_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.no_show_tax_amount, r.no_show_tax_destination
    into v_room_id, v_tax_amount, v_destination
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Host gate: the caller must be the host of the room the event
  -- belongs to.
  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can apply the no-show tax' using errcode = '42501';
  end if;

  -- Idempotent: a no_show_tax row already exists for this pair →
  -- return success without double-tax.
  select exists (
    select 1 from public.transactions t
    where t.session_id = p_event_id
      and t.member_id = p_user_id
      and t.kind = 'no_show_tax'
  ) into v_already_taxed;
  if v_already_taxed then
    return true;
  end if;

  -- If a held seat deposit exists for this (event, user), record
  -- its id so the meta stamp carries the deposit_id forward. When
  -- no deposit exists (claim without deposit) the membership debit
  -- path applies — the deposit_id is null and the meta carries
  -- only the reason.
  select sd.id into v_deposit_id
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_user_id
  limit 1;

  if v_deposit_id is null then
    -- No deposit was held: the tax stands alone; debit the
    -- membership points_balance by the tax amount so the social
    -- ledger and the public ledger line up.
    update public.room_memberships
      set points_balance = points_balance - v_tax_amount
      where room_id = v_room_id and user_id = p_user_id;
  end if;

  -- Record the public ledger row. The destination meta tag is the
  -- next-pot crediting signal for the downstream slice.
  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, p_user_id, 'no_show_tax', v_tax_amount,
    jsonb_build_object(
      'destination', v_destination,
      'reason', coalesce(p_reason, ''),
      'deposit_id', v_deposit_id
    ),
    v_caller
  );

  return true;
end;
$$;

grant execute on function public.apply_no_show_tax(uuid, uuid, text) to authenticated;

comment on function public.apply_no_show_tax(uuid, uuid, text) is 'V0.84 C3 — host-only. Forfeits exactly one held seat deposit of rooms.no_show_tax_amount (or debits points_balance when no deposit was held). Idempotent per (event, user); the next-pot crediting consumes the meta {destination, deposit_id, reason} stamp at next-event creation.';

-- 6. skip_no_show_tax(p_event_id, p_user_id, p_reason) — host-only.
-- Inserts a waiver row with reason 'texted' or 'away' so the
-- ledger carries the host's call.
create or replace function public.skip_no_show_tax(
  p_event_id uuid,
  p_user_id uuid,
  p_reason text default 'texted'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_already_skipped boolean;
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

  -- Host gate: the caller must be the host of the room the event
  -- belongs to.
  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can skip the no-show tax' using errcode = '42501';
  end if;

  -- Idempotent: a waiver row already exists for this pair →
  -- return success without stacking.
  select exists (
    select 1 from public.transactions t
    where t.session_id = p_event_id
      and t.member_id = p_user_id
      and t.kind = 'no_show_tax_waiver'
  ) into v_already_skipped;
  if v_already_skipped then
    return true;
  end if;

  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, p_user_id, 'no_show_tax_waiver', 0,
    jsonb_build_object('reason', coalesce(p_reason, 'texted')),
    v_caller
  );

  return true;
end;
$$;

grant execute on function public.skip_no_show_tax(uuid, uuid, text) to authenticated;

comment on function public.skip_no_show_tax(uuid, uuid, text) is 'V0.84 C3 — host-only. Records the host''s skip call with reason ''texted'' or ''away''. Idempotent per (event, user); amount is always 0 so the waiver never moves chips.';

-- 7. Refresh the PostgREST schema cache so the new return shapes
--    are immediately visible to the iOS app.
notify pgrst, 'reload schema';