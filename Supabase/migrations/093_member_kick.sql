-- 093: V0.98 — Members & host tools (kick, visible host controls, team-input removal)
--
-- Background:
--   Games Room has always let a host create the room and that was the
--   end of host tools. V0.91 added promote/demote (multi-host) but the
--   flip side — removing a member who is actively hostile to the room
--   — was missing. Per the V0.53 product frame, "the host is the
--   customer" and "the ledger is the durable social": kicking must
--   give the host control without ever vaporising a person's nights
--   (season score, points balance, arcs, awards all preserved).
--
--   This migration:
--     1. Adds `room_memberships.membership_status` (active | kicked).
--        Existing rows default 'active' — zero behaviour change for
--        rooms with no kicks. Kick is a STATUS change, not a row
--        delete (D1). The kicked row stays so the ledger, season
--        score, points balance, arcs and awards are preserved; the
--        member is excluded from every roster + visibility path.
--     2. `remove_room_member(p_room_id, p_target_user_id)` — host
--        kicks a member. Five guards: caller must be a host role
--        (not rooms.created_by — multi-host), target must exist in
--        the room, target must not be a host, target must not be the
--        caller, and the target must not have a held seat deposit on
--        a live event (played_at <= now() and no settlement tx).
--     3. `redeem_join_code` reactivation branch — when a previously
--        kicked member redeems a fresh invite code, the existing
--        row flips back to 'active' and points_balance resets to the
--        room's join_starting_bonus. Season score + team + history
--        untouched (D6).
--     4. `leave_room` — D7 fold-in. The pre-multi-host `created_by`
--        check is replaced with a role-based check matching 091's
--        "at least one other active host must remain" semantics.
--     5. Visibility touchpoints — every read path that could surface
--        a kicked room or member gains `membership_status = 'active'`
--        (or equivalent) so the kicked row silently disappears from
--        the member's own list, the host's roster, and any RLS-gated
--        room SELECT (D2 — the kicked member sees nothing).
--
--   Member model invariant: the iOS `Member` model gains NO status
--   field on any rendered surface (invariant 3). Roster queries
--   simply never return kicked rows.
--
-- Authorisation:
--   Every state change goes through a SECURITY DEFINER RPC with the
--   guard checks inside the function. RLS is defence in depth (the
--   visibility touchpoints add the active filter), not the primary
--   gate (invariant 4).
--
-- Idempotent: every DDL uses IF NOT EXISTS / CREATE OR REPLACE.
-- Apply via psql (see header below) — house style per 018/091.
--
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/093_member_kick.sql

-- =================================================================
-- 1. membership_status column
-- =================================================================
alter table public.room_memberships
  add column if not exists membership_status text not null default 'active'
    check (membership_status in ('active', 'kicked'));

comment on column public.room_memberships.membership_status is
  'V0.98 — Option A kick (D1). kicked = row preserved (ledger/season/history intact), excluded from all roster + visibility paths. Never surfaced to the member (D2).';

-- Backfill safety: any row missing the new column gets 'active' via
-- the column default above. No explicit UPDATE needed; the default
-- fires for added columns on existing rows in Postgres.

-- =================================================================
-- 2. remove_room_member(p_room_id, p_target_user_id)
--    Returns the active-only roster so iOS rebuilds the cache in
--    one round-trip, mirroring transfer_host_role (091).
-- =================================================================
create or replace function public.remove_room_member(
  p_room_id uuid,
  p_target_user_id uuid
)
returns setof public.room_memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_target_status text;
  v_target_role text;
begin
  -- 2a. Auth check (cheap, first).
  if v_caller is null then
    raise exception 'not_authenticated: caller is not signed in'
      using errcode = '42501';
  end if;

  -- 2b. Caller must be a host role in this room. Uses the table
  -- directly (NOT rooms.created_by) so multi-host is inherited
  -- naturally — the second promoted host can also kick.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller
      and role = 'host'
      and membership_status = 'active'
  ) then
    raise exception 'not_authorized: caller is not a host in this room'
      using errcode = '42501';
  end if;

  -- 2c. Target must be a member of this room (any status — kicked
  -- is a no-op below, but the row must exist).
  select role, membership_status
    into v_target_role, v_target_status
  from public.room_memberships
  where room_id = p_room_id
    and user_id = p_target_user_id;
  if not found then
    raise exception 'not_found: target is not a member of this room'
      using errcode = 'P0002';
  end if;

  -- 2d. Idempotent: kicking an already-kicked member returns the
  -- roster unchanged. The roster is always active-only.
  if v_target_status = 'kicked' then
    return query
      select * from public.room_memberships
      where room_id = p_room_id
        and membership_status = 'active';
    return;
  end if;

  -- 2e. Target must not be a host — demote first. One tool per row
  -- prevents host-lockout accidents.
  if v_target_role = 'host' then
    raise exception 'is_host: demote the target to member before removing them'
      using errcode = '42501';
  end if;

  -- 2f. Target must not be the caller.
  if v_target_user_id = v_caller then
    raise exception 'is_self: you cannot remove yourself; use leave_room instead'
      using errcode = '42501';
  end if;

  -- 2g. Live-event guard: a held seat deposit on a LIVE event must
  -- be settled before the host can kick. "Live" = played_at <= now()
  -- AND no settlement transaction exists for the event yet (the
  -- night is in play or stalled, escrow money is mid-flight). For
  -- future events (played_at > now()), the deposit is auto-refunded
  -- below.
  if exists (
    select 1
    from public.seat_deposits sd
    join public.events e on e.id = sd.event_id
    where sd.room_id = p_room_id
      and sd.user_id = p_target_user_id
      and sd.status = 'held'
      and e.played_at <= now()
      and not exists (
        select 1 from public.transactions t
        where t.session_id = sd.event_id
          and t.room_id = sd.room_id
      )
  ) then
    raise exception 'active_deposit: settle the night before removing this member'
      using errcode = '42501';
  end if;

  -- 2h. Refund path: held deposits on FUTURE events are auto-
  -- refunded (escrow integrity, D5). The deposit is non-refundable
  -- only for past/live events where the host still owes a settle.
  update public.seat_deposits sd
    set status = 'returned',
        returned_at = now(),
        settled_at = now()
  from public.events e
  where sd.event_id = e.id
    and sd.room_id = p_room_id
    and sd.user_id = p_target_user_id
    and sd.status = 'held'
    and e.played_at > now();

  -- 2i. Refund the points: the points_balance was debited when the
  -- deposit was held. Returning the deposit to status='returned'
  -- without re-crediting would leak the member's points. Credit
  -- only the rows we just flipped.
  update public.room_memberships m
    set points_balance = m.points_balance + sub.total
  from (
    select sd.event_id, sd.amount as total
    from public.seat_deposits sd
    join public.events e on e.id = sd.event_id
    where sd.room_id = p_room_id
      and sd.user_id = p_target_user_id
      and sd.status = 'returned'
      and e.played_at > now()
  ) sub
  where m.room_id = p_room_id
    and m.user_id = p_target_user_id;

  -- 2j. Apply the kick — status change, not a row delete (D1,
  -- invariant 1). The kicked row is preserved so the ledger, season
  -- score, points balance, arcs and awards all survive.
  update public.room_memberships
    set membership_status = 'kicked'
  where room_id = p_room_id
    and user_id = p_target_user_id;

  -- 2k. Return the active-only roster so iOS can rebuild from one
  -- call (mirrors transfer_host_role, 091).
  return query
    select * from public.room_memberships
    where room_id = p_room_id
      and membership_status = 'active';
end;
$$;

revoke all on function public.remove_room_member(uuid, uuid) from public;
grant execute on function public.remove_room_member(uuid, uuid) to authenticated;

comment on function public.remove_room_member(uuid, uuid) is
  'V0.98 — host removes a member from the room (D1, D2). Status change, never row delete: ledger/season/history preserved. Caller must be an active host role (not rooms.created_by — multi-host). Five guards: not_authorized, not_found, is_host, is_self, active_deposit. Held deposits on future events are auto-refunded; past/live events block the kick until the host settles.';

-- =================================================================
-- 3. redeem_join_code reactivation branch (D6)
--    A kicked member redeems a fresh code → row flips to 'active'
--    and points_balance resets to the room's join_starting_bonus.
--    season_score, team, history untouched.
-- =================================================================
create or replace function public.redeem_join_code(code text)
returns table(room_id uuid, room_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
  v_bonus integer;
  v_existing_status text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Find an unredeemed code.
  select jc.room_id into v_room_id
  from public.join_codes jc
  where jc.code = upper(redeem_join_code.code)
    and jc.redeemed_at is null
  for update;

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Existing-membership branch (D6 + 018 lineage).
  select m.membership_status into v_existing_status
  from public.room_memberships m
  where m.room_id = v_room_id and m.user_id = v_user_id;

  if v_existing_status = 'active' then
    -- Already an active member: idempotent, return the room.
    select r.name into v_room_name from public.rooms r where r.id = v_room_id;
    return query select v_room_id, v_room_name;
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

    -- The redeemed code is consumed as normal — the host must
    -- generate a fresh code per rejoin (single-use unchanged).
    update public.join_codes jc
      set redeemed_at = now(), redeemed_by = v_user_id
      where jc.code = upper(redeem_join_code.code);

    return query select v_room_id, v_room_name;
    return;
  end if;

  -- No prior row: new member. Look up the per-room join starting
  -- bonus and insert.
  select r.name, r.join_starting_bonus
    into v_room_name, v_bonus
  from public.rooms r
  where r.id = v_room_id;

  insert into public.room_memberships (room_id, user_id, role, points_balance, membership_status)
    values (v_room_id, v_user_id, 'member', v_bonus, 'active');

  update public.join_codes jc
    set redeemed_at = now(), redeemed_by = v_user_id
    where jc.code = upper(redeem_join_code.code);

  return query select v_room_id, v_room_name;
end;
$$;

grant execute on function public.redeem_join_code(text) to authenticated;

-- =================================================================
-- 4. leave_room — D7 fold-in.
--    The pre-multi-host `created_by` check is replaced with a
--    role-based check matching 091's "at least one other active
--    host must remain" semantics. Members leave freely.
-- =================================================================
create or replace function public.leave_room(p_room_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller uuid := public.current_user_id();
  v_caller_role text;
  v_remaining_hosts int;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Caller must be an active member of this room. Kicked members
  -- have already "left" in the user-visible sense; leave_room is a
  -- no-op for them (the room doesn't appear in their list anyway).
  select m.role into v_caller_role
  from public.room_memberships m
  where m.room_id = p_room_id
    and m.user_id = v_caller
    and m.membership_status = 'active';

  if v_caller_role is null then
    -- Not a member, or already kicked. Idempotent.
    return true;
  end if;

  -- Last-host guard (matching 091's transfer_host_role).
  if v_caller_role = 'host' then
    select count(*) into v_remaining_hosts
    from public.room_memberships
    where room_id = p_room_id
      and role = 'host'
      and membership_status = 'active'
      and user_id <> v_caller;
    if v_remaining_hosts < 1 then
      raise exception 'last_host: a room must always have at least one host'
        using errcode = 'P0001';
    end if;
  end if;

  -- Members leave freely. Hosts leave only when ≥1 other active host
  -- remains. Invariant 1 still holds: leave_room is the ONLY path
  -- that deletes a row from room_memberships (kick preserves the row).
  delete from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller;

  return true;
end;
$$;

grant execute on function public.leave_room(uuid) to authenticated;

comment on function public.leave_room(uuid) is
  'V0.98 — member leaves a room. Host must demote first OR have ≥1 other active host remaining. Kicked members are already invisible; calling leave_room is a no-op for them. Matches 091 transfer_host_role last-host semantics (D7).';

-- =================================================================
-- 5. Visibility touchpoints — kicked rows must vanish (invariant 2)
-- =================================================================

-- 5a. get_my_rooms — filter active so the kicked room leaves the
--     member's room list. This is THE D2 surface (per audit table):
--     a kicked member must not see the room in their rooms list.
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
set search_path = ''
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
    and m.membership_status = 'active'
    and r.deleted_at is null
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;

-- 5b. get_room_members — filter active (066 lineage). Hosts see only
--     active members; kicked members vanish from the roster.
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid,
  room_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  team text,
  joined_at timestamptz,
  last_seen_at timestamptz,
  preferences_social text,
  preferences_conversation_prompt text,
  preferences_default_set boolean,
  notifications_enabled boolean
)
language sql
security definer
stable
set search_path = ''
as $$
  select m.user_id, m.room_id, u.display_name, m.role::text,
         m.points_balance, m.season_score, m.team,
         m.joined_at, m.last_seen_at,
         m.preferences_social, m.preferences_conversation_prompt,
         m.preferences_default_set,
         coalesce(m.notifications_enabled, false) as notifications_enabled
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
    and m.membership_status = 'active'
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;

-- 5c. RLS on room_memberships — "user sees own memberships" + "host
--     sees room members" both gain the active filter.
drop policy if exists "user sees own memberships" on public.room_memberships;
create policy "user sees own memberships" on public.room_memberships
  for select using (
    auth.uid() = user_id
    and membership_status = 'active'
  );

drop policy if exists "host sees room members" on public.room_memberships;
create policy "host sees room members" on public.room_memberships
  for select using (
    exists (
      select 1 from public.rooms r
      where r.id = room_memberships.room_id
        and r.created_by = auth.uid()
    )
    and membership_status = 'active'
  );

-- 5d. RLS on rooms — "member sees room" adds the active filter
--     inside the exists() so a kicked member can't SELECT the room
--     via RLS. Without this, even with get_my_rooms filtered, a
--     kicked member with a cached room id could still fetch the row
--     directly through PostgREST.
drop policy if exists "member sees room" on public.rooms;
create policy "member sees room" on public.rooms
  for select using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = rooms.id
        and m.user_id = auth.uid()
        and m.membership_status = 'active'
    )
  );
