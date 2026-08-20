-- 086: V0.85 amend — forfeited deposits are BURNED (2026-08-20).
--
-- The seat deposit forfeit destination is removed. A forfeited
-- deposit leaves the ledger as a public seat_deposit_forfeit
-- record and is NOT redistributed. No one gains from a no-show;
-- the room never profits from absence. User directive: "what is
-- the forfeit destination for? I think it should just get lost."
--
-- Changes:
--   1. rooms: DROP the CHECK constraint
--      rooms_seat_deposit_destination_check (085 created it) and
--      DROP COLUMN seat_deposit_destination.
--   2. update_room_settings: DROP the 17-arg (085) version, then
--      recreate as 16-arg (no p_seat_deposit_destination).
--      Postgres cannot CREATE OR REPLACE across an argument-count
--      change — DROP first (42P13 pattern).
--   3. get_my_rooms: drop seat_deposit_destination from the
--      return shape.
--   4. forfeit_seat_deposit: keep the ledger row (kind
--      'seat_deposit_forfeit') as the PUBLIC RECORD of the burn.
--      The destination meta is gone — the chips are burned, not
--      routed. The 'next-pot crediting slice' comment is obsolete.
--   5. No redistribution logic. Burned = gone.
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/086_seat_deposit_burn.sql
--
-- Post-apply verification:
--   select column_name from information_schema.columns
--     where table_schema='public' and table_name='rooms'
--     and column_name like 'seat_deposit_%';
--   select pg_get_function_arguments('public.update_room_settings(uuid,text,text,text,text,integer,integer,integer,boolean,boolean,boolean,boolean,integer,integer,text,integer)'::regprocedure);

-- 1. Drop the destination column + its CHECK constraint.
alter table public.rooms drop constraint if exists rooms_seat_deposit_destination_check;
alter table public.rooms drop column if exists seat_deposit_destination;

-- 2. update_room_settings — 16-arg signature (no destination).
--    DROP the 085 17-arg overload first (42P13: cannot CREATE OR
--    REPLACE across an argument-count change).
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
    p_seat_deposit_grace_minutes integer
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
    seat_deposit_grace_minutes integer
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
      r.seat_deposit_grace_minutes
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where r.id = p_room_id and m.user_id = v_caller;
end;
$$;

grant execute on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer,
    integer, text, integer
) to authenticated;

comment on function public.update_room_settings(
    uuid, text, text, text, text, integer, integer, integer,
    boolean, boolean, boolean, boolean, integer,
    integer, text, integer
) is 'V0.85 amend — host-only room settings update. 16-arg signature carries the V0.83 auto-close window + the V0.85 seat-deposit escrow settings (amount, trigger escrow|off, grace). The forfeit destination is gone: forfeited deposits are burned. Returns the full Room row.';

-- 3. get_my_rooms — drop seat_deposit_destination from the shape.
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
  seat_deposit_grace_minutes integer
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
    r.seat_deposit_grace_minutes
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

-- 4. forfeit_seat_deposit — the ledger row stays as the PUBLIC
--    RECORD of the burn. The destination meta is gone: the chips
--    are burned, not routed. No redistribution logic — burned =
--    gone.
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
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$$;

grant execute on function public.forfeit_seat_deposit(uuid, uuid) to authenticated;

comment on function public.forfeit_seat_deposit(uuid, uuid) is 'V0.85 amend — host-only confirmed no-show. Held deposit → forfeited (the chips stay out of the member''s balance; they left at claim). The ledger row is the PUBLIC RECORD of the burn: the deposit is gone, not routed anywhere. No one gains from a no-show. Idempotent.';

-- 5. Refresh the PostgREST schema cache so the new return shapes
--    are immediately visible to the iOS app.
notify pgrst, 'reload schema';
