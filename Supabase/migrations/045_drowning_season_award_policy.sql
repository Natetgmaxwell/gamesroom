-- 045: F-MVP-11 / V0.9 — Drowning award RLS rewrite (Wave 1 Slice 1.1).
--
-- Migration 039 set the drowning RLS as "recipient only." Migration 045
-- broadens the read set to:
--   1. The recipient (always — their own award).
--   2. The host of the room (always — host oversight of the season).
--   3. Any room member who has set member_drowning_opt_in = true
--      (consent-based opt-in to the broader share).
--
-- The opt-in column lives on room_memberships (migration 044). The
-- existing 039 policy is dropped before the new one is created to
-- avoid duplicate policy warnings.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/045_drowning_season_award_policy.sql

-- Drop the migration-039 recipient-only policy.
drop policy if exists "recipients can read their drowning awards"
  on public.season_awards;

-- New policy: drowning rows are readable by the recipient, the host,
-- and any member of the room who has opted in to the drowning share.
-- Note: this is a SELECT policy. INSERT/UPDATE/DELETE on drowning rows
-- still follows the existing migration-039 host-write policy.
create policy "drowning award readers: recipient, host, opted-in members"
  on public.season_awards for select
  using (
    award_type = 'drowning'
    and (
      -- Recipient can always see their own.
      recipient_user_id = public.current_user_id()
      or
      -- Host of the room can always see (host oversight).
      exists (
        select 1 from public.rooms r
        where r.id = season_awards.room_id
          and r.created_by = public.current_user_id()
      )
      or
      -- Opted-in members can see other drowning rows in their room.
      exists (
        select 1 from public.room_memberships rm
        where rm.room_id = season_awards.room_id
          and rm.user_id = public.current_user_id()
          and rm.member_drowning_opt_in = true
      )
    )
  );

-- The 045 policy covers the drowning subset. Migration 039's non-drowning
-- read policy remains in place. The host-write policy remains in place.

-- get_season_awards(p_season_id) — already RLS-aware (it selects from
-- season_awards, so the policies above apply). No function change needed.

-- Opt-in toggle RPC. Lets a member set their own drowning opt-in for
-- their room membership. RLS already lets the member update their
-- own room_memberships row (per migration 004), but a dedicated RPC
-- keeps the contract explicit and avoids over-granting column access.
create or replace function public.set_drowning_opt_in(
  p_room_id uuid,
  p_opt_in boolean
)
returns void
language sql
security definer
stable
as $$
  update public.room_memberships
    set member_drowning_opt_in = p_opt_in
    where room_id = p_room_id
      and user_id = public.current_user_id();
$$;

grant execute on function public.set_drowning_opt_in(uuid, boolean) to authenticated;

-- Surface the per-room opt-in flag through get_my_rooms so the iOS
-- awards card can render the toggle (recipient only — non-recipients
-- see the flag in their own settings). Redefined here because
-- migration 043 shipped get_my_rooms without the column; the column
-- is added in 044, this is the read-side wiring.
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
  member_drowning_opt_in boolean
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
    m.role::text as user_role,
    coalesce(m.member_drowning_opt_in, false) as member_drowning_opt_in
  from public.rooms r
  join public.room_memberships m on m.room_id = r.id
  where m.user_id = public.current_user_id()
  order by r.updated_at desc;
$$;

grant execute on function public.get_my_rooms() to authenticated;
