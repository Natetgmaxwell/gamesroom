-- 076: Invite-a-friend reward.
--
-- Product decision (2026-08-16): when a member joins a room via a
-- join code, the code's generator (the inviter) earns +50 points,
-- additive to points_balance (never taken away, consistent with 074).
-- The reward fires once per unique new member (only on first join),
-- is blocked for self-invite, and is written to the transactions
-- ledger as kind 'invite_reward' so it is auditable and excluded
-- from season standings (matches how the 200 starting bonus works).
--
-- Also adds get_my_invite_rewards(room_id) so the client can show
-- a reward banner when a friend's join has paid off.

-- 1. redeem_join_code: credit the inviter on a new-member join.
create or replace function public.redeem_join_code(p_code text)
returns table(room_id uuid, room_name text, status text, tier integer, invited_by uuid)
language plpgsql
security definer
set search_path = public
as $function$
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

    -- V0.76 — invite reward. Credit the inviter +50 when a NEW member
    -- joins via their code. Blocked for self-invite (generator is the
    -- redeemer). Fires only on first join (v_status = 'joined'), so it
    -- is idempotent-safe and never double-credits.
    if v_generator is not null and v_generator <> v_user_id then
      update public.room_memberships m
         set points_balance = m.points_balance + 50
       where m.room_id = v_room_id and m.user_id = v_generator;

      insert into public.transactions (
        room_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_room_id, v_generator, 'invite_reward', 50,
        jsonb_build_object('invitee', v_user_id, 'code', upper(p_code)),
        v_user_id
      );
    end if;
  end if;

  update public.join_codes jc
  set redeemed_at = now(), redeemed_by = v_user_id
  where jc.code = upper(p_code);

  select r.name into v_room_name from public.rooms r where r.id = v_room_id;
  return query select v_room_id, v_room_name, v_status, v_tier, v_generator;
end;
$function$;

-- 2. get_my_invite_rewards: rewards earned by the caller in a room.
-- Returns the count of friends who joined via the caller's codes and
-- the total points earned, so the client can show a reward banner.
create or replace function public.get_my_invite_rewards(p_room_id uuid)
returns table(friends_joined integer, total_reward bigint)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  return query
  select
    count(*)::integer as friends_joined,
    coalesce(sum(t.amount_points), 0)::bigint as total_reward
  from public.transactions t
  where t.room_id = p_room_id
    and t.member_id = v_user_id
    and t.kind = 'invite_reward';
end;
$function$;
