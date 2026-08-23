-- 088: Restore the join starting bonus in redeem_join_code.
--
-- 068's rebuild of redeem_join_code (multi-room graph tiers) and
-- 076's rebuild (invite rewards) both dropped 018's bonus: the
-- membership INSERT omitted points_balance, and the column
-- defaults to 0 — so every join since 076 landed at balance 0.
-- First visible victim: Connor in Felt Faction, 2026-08-23
-- ("balance too low to claim a seat" — the V0.85 seat deposit
-- check surfaced the zero balance).
--
-- Same bug family as the 085 default fix: an INSERT that omits a
-- column silently takes the column default. When rebuilding an
-- RPC that INSERTs, diff the old and new column lists.
--
-- Live remediation already applied 2026-08-23 (this file is the
-- permanent record; the backfill below is guarded and idempotent):
--   * redeem_join_code replaced (bonus restored)
--   * Connor backfilled +200 with a join_bonus_backfill ledger row
--
-- Apply via:
--   supabase db query --linked -f Supabase/migrations/088_join_bonus_restore.sql
--
-- Post-apply verification:
--   select m.points_balance, m.joined_at from public.room_memberships m
--     where m.user_id = '644b72fb-b3c3-44c8-bdf7-6c09da5e080a';

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
  v_bonus int;
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
    -- V0.18 — join starting bonus: read the room's configured bonus
    -- and land it in the same insert (restored by 088 after the
    -- 068/076 rebuilds dropped it).
    select r.join_starting_bonus into v_bonus
    from public.rooms r
    where r.id = v_room_id;

    insert into public.room_memberships (room_id, user_id, role, invited_by, invite_tier, points_balance)
    values (v_room_id, v_user_id, 'member', v_generator, v_tier, v_bonus);

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

-- One-off backfill for joins that landed at 0 while 076's broken
-- version was live (2026-08-13 → 2026-08-23). Guards: only members
-- still at balance 0 with NO transactions of any kind (the clean
-- fingerprint of the dropped bonus — anyone who played, deposited,
-- or was already backfilled is excluded). Ledger row first, then
-- the credit, both gated on the same fingerprint. Re-run safe.

insert into public.transactions (room_id, member_id, kind, amount_points, meta, created_by)
select m.room_id, m.user_id, 'join_bonus_backfill', r.join_starting_bonus,
       jsonb_build_object('reason', 'restore 018 join bonus dropped by 068/076 rebuilds',
                          'via', '088_join_bonus_restore'),
       m.user_id
from public.room_memberships m
join public.rooms r on r.id = m.room_id
where m.points_balance = 0
  and r.join_starting_bonus > 0
  and not exists (select 1 from public.transactions t
                  where t.room_id = m.room_id and t.member_id = m.user_id);

update public.room_memberships m
set points_balance = r.join_starting_bonus
from public.rooms r
where r.id = m.room_id
  and m.points_balance = 0
  and r.join_starting_bonus > 0
  and not exists (select 1 from public.transactions t
                  where t.room_id = m.room_id and t.member_id = m.user_id
                    and t.kind <> 'join_bonus_backfill');
