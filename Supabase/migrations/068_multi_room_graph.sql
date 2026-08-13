-- 068: V0.55 multi-room-as-social-object — referrer graph + invite tiers + overlap badge.
--
-- Pins the build decisions from
--   docs/loop-artifacts/V0.55_MULTI_ROOM_SPEC.md
-- (committed f91c360). Makes the room graph real: records who
-- vouched for whom (`invited_by`), scopes invite codes to the
-- person they were meant for (`join_codes.invitee_user_id`), and
-- surfaces each room as a social object the user belongs to
-- (cross-room overlap computed in `get_my_rooms`).
--
-- NOTE: numbered 068, not 067 as the spec pinned. 067 is taken by
-- the ledger-as-social-surface build (t_06cba0cd, migration
-- 067_ledger_social_awards.sql). The number is a sequencing
-- artifact, not design; the spec chose 067 only because 066 was
-- taken by V0.54. Renumbered to 068 to avoid a collision. All
-- SQL is verbatim from spec §1a–1d.
--
--   1. `room_memberships.invited_by` (uuid, null)
--      The member who vouched for this user. null for the host
--      (no one vouched) and for anyone admitted by a host code
--      (tier 1). on delete set null keeps the referrer soft when
--      a member leaves, so the graph does not cascade-delete
--      history.
--
--   2. `room_memberships.invite_tier` (int, default 3)
--      The tier that admitted this member: 1 host direct, 2
--      member + referral proof, 3 open code by invitee. Existing
--      rows keep the default 3 (additive migration).
--
--   3. `join_codes.invitee_user_id` (uuid, null)
--      null = open to any redeemer (tier 1 or 2). Non-null =
--      tier 3, usable only by that user.
--
--   4. `redeem_join_code` redefined to record the tier + referrer
--      and reject tier-3 redemption by anyone other than the
--      invitee (same P0002 as a typo, no information leak).
--
--   5. `get_my_rooms` redefined to append the overlap signal
--      (count + up to 5 names) computed fresh via a lateral
--      subquery. Keeps the V0.54 `notifications_enabled` column.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/068_multi_room_graph.sql

-- =================================================================
-- 1. room_memberships referrer columns
-- =================================================================
alter table public.room_memberships
  add column if not exists invited_by uuid references public.users(id) on delete set null,
  add column if not exists invite_tier int not null default 3
    check (invite_tier in (1, 2, 3));

create index if not exists room_memberships_invited_by_idx
  on public.room_memberships (invited_by);

comment on column public.room_memberships.invited_by is
  'The member who vouched for this user (the referrer). null for the '
  'host and for anyone admitted by a host-generated code (tier 1). '
  'on delete set null keeps the referrer soft when a member leaves, '
  'so the room graph does not cascade-delete history.';
comment on column public.room_memberships.invite_tier is
  'The tier that admitted this member: 1 host direct, 2 member + '
  'referral proof, 3 open code by invitee. Existing rows default 3.';

-- =================================================================
-- 2. join_codes invitee scope
-- =================================================================
alter table public.join_codes
  add column if not exists invitee_user_id uuid references public.users(id) on delete set null;

comment on column public.join_codes.invitee_user_id is
  'null = open to any redeemer (tier 1 or 2). Non-null = tier 3, '
  'usable only by that user. A stranger redeeming a tier-3 code gets '
  'the same P0002 as a typo, so no information leak.';

-- =================================================================
-- 2b. scope_join_code RPC — scopes an existing join code to one
--     invitee (tier 3). The code is minted by generate_join_code
--     (tier 1/2), then scoped here so only the named invitee can
--     redeem it. The generator must be the caller (a member of the
--     room); the invitee must be a member of one of the caller's
--     OTHER rooms (the invite-chain bridge, substrate 1.2).
-- =================================================================
create or replace function public.scope_join_code(
  p_code text,
  p_invitee_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select jc.room_id into v_room_id
  from public.join_codes jc
  where jc.code = upper(p_code)
    and jc.redeemed_at is null
    and jc.generated_by = v_caller
  for update;

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- The invitee must be a member of one of the caller's OTHER rooms
  -- (the invite-chain bridge). This keeps tier-3 codes from being
  -- scoped to a stranger.
  if not exists (
    select 1
    from public.room_memberships mine
    join public.room_memberships theirs
      on theirs.room_id = mine.room_id
     and theirs.user_id = p_invitee_user_id
    where mine.user_id = v_caller
      and mine.room_id <> v_room_id
  ) then
    raise exception 'Invitee is not a member of your other rooms' using errcode = 'P0002';
  end if;

  update public.join_codes
    set invitee_user_id = p_invitee_user_id
    where code = upper(p_code);
end;
$$;

grant execute on function public.scope_join_code(text, uuid) to authenticated;

comment on function public.scope_join_code(text, uuid) is
  'Scopes an existing join code (minted by the caller) to one '
  'invitee, making it tier 3. The invitee must be a member of one of '
  'the caller''s other rooms (the invite-chain bridge). A stranger '
  'redeeming the code gets the same P0002 as a typo.';

-- =================================================================
-- 2c. approve_tier_two_join RPC — host-only. Because tier-2 joins
--     are live immediately (low friction, substrate 1.3), the
--     "approval" is a host one-tap remove from the roster. The host
--     is the single approver (no co-host role exists). `p_remove`
--     true deletes the membership row; false is a no-op that leaves
--     it (the host chose to keep the join).
-- =================================================================
create or replace function public.approve_tier_two_join(
  p_room_id uuid,
  p_user_id uuid,
  p_remove boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Host-only: the caller must be the room's host.
  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can approve tier-2 joins' using errcode = '42501';
  end if;

  if p_remove then
    delete from public.room_memberships
    where room_id = p_room_id
      and user_id = p_user_id
      and invite_tier = 2;
  end if;
end;
$$;

grant execute on function public.approve_tier_two_join(uuid, uuid, boolean) to authenticated;

comment on function public.approve_tier_two_join(uuid, uuid, boolean) is
  'Host-only. Removes (p_remove true) or keeps (false) a tier-2 join '
  'on the roster. Tier-2 joins are live immediately; this is the '
  'host''s one-tap gate. The host is the single approver (no co-host '
  'role exists).';

-- =================================================================
-- 3. redeem_join_code — records the tier + referrer, rejects
--    tier-3 redemption by anyone other than the invitee.
-- =================================================================
drop function if exists public.redeem_join_code(text);
create function public.redeem_join_code(p_code text)
returns table (
  room_id uuid,
  room_name text,
  status text,
  tier int,
  invited_by uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_room_id uuid;
  v_room_name text;
  v_user_id uuid := auth.uid();
  v_invitee uuid;
  v_generator uuid;
  v_tier int;
  v_status text;
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select jc.room_id, jc.invitee_user_id, jc.generated_by
    into v_room_id, v_invitee, v_generator
  from public.join_codes jc
  where jc.code = upper(p_code)
    and jc.redeemed_at is null
  for update;

  if v_room_id is null then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Tier 3: the code is scoped to one invitee. Anyone else is rejected.
  if v_invitee is not null and v_invitee <> v_user_id then
    raise exception 'Code not found or already redeemed' using errcode = 'P0002';
  end if;

  -- Derive the tier from how the code was made.
  --   host-generated code  -> tier 1
  --   member-generated     -> tier 2
  --   invitee-scoped code  -> tier 3
  if v_invitee is not null then
    v_tier := 3;
  elsif v_generator is null
     or v_generator = (select created_by from public.rooms where id = v_room_id) then
    v_tier := 1;
  else
    v_tier := 2;
  end if;

  -- Idempotent: already a member, return the room without re-inserting.
  if exists (
    select 1 from public.room_memberships m
    where m.room_id = v_room_id and m.user_id = v_user_id
  ) then
    v_status := 'already_member';
  else
    insert into public.room_memberships (room_id, user_id, role, invited_by, invite_tier)
    values (v_room_id, v_user_id, 'member', v_generator, v_tier);
    v_status := 'joined';
  end if;

  update public.join_codes jc
  set redeemed_at = now(), redeemed_by = v_user_id
  where jc.code = upper(p_code);

  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name, v_status, v_tier, v_generator;
end;
$$;

grant execute on function public.redeem_join_code(text) to authenticated;

comment on function public.redeem_join_code(text) is
  'Redeems a join code, recording the referrer (invited_by) and the '
  'tier (1 host direct, 2 member + referral, 3 invitee-scoped). A '
  'tier-3 code scoped to one invitee is rejected for anyone else '
  'with the same P0002 as a typo. Idempotent for existing members.';

-- =================================================================
-- 4. get_my_rooms — append the overlap signal (count + up to 5
--    names), computed fresh via a lateral subquery. Keeps the
--    V0.54 notifications_enabled column.
-- =================================================================
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
  overlap_names text[]
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
    ov.overlap_names
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

comment on function public.get_my_rooms() is
  'Returns the caller''s rooms with the cross-room overlap signal: '
  'for each room, the count of co-members the caller also sits with '
  'in at least one other room, plus up to 5 overlapping display '
  'names. Computed fresh at read time (never stored, never drifts). '
  'Keeps the V0.54 notifications_enabled column.';
