-- 065: V0.51 per-member working-hand readout for active casino play.
--
-- `get_event_working_hands(p_event_id)` returns one row per room
-- member of the event's room: their display name, the sum of their
-- un-finalized casino_withdrawals (the "working hand"), and their
-- current `points_balance` (the bank).
--
-- Background: the V0.47 host-only dispense surface renders pending
-- withdrawals as a tap-to-dismiss list, but the only per-member
-- working-hand badge on the Witness Slot today is the caller's own
-- `casinoWithdrawn` (`WitnessSlot.workingHand: Int?`). V0.51 widens
-- this so the host can see every member's working hand + bank
-- balance at a glance, and every member can see every other
-- member's working hand (balances stay host-only by being
-- filtered through the UI gate, not the SQL — `get_event_working_hands`
-- itself returns balances for room members; the iOS view hides
-- the column when `!isHost`).
--
-- Security: `security definer` + the `exists ( ... public.current_user_id() )`
-- room-membership check enforces that only authenticated room
-- members can read the readout. The function follows the
-- migration 061 style (`language sql` where possible,
-- `set search_path = public`, `grant execute ... to authenticated`,
-- `notify pgrst, 'reload schema'` at the end).
--
-- "Open" working-hand logic mirrors `get_my_open_withdrawal`
-- (migration 040): sum every `casino_withdrawals` row for the
-- session whose `(session_id, member_id)` pair has no matching
-- finalized `casino_scans` row. This matches the M3.1
-- "single open withdrawal per member per session" invariant.

drop function if exists public.get_event_working_hands(uuid);
create function public.get_event_working_hands(p_event_id uuid)
returns table (
  member_id uuid,
  display_name text,
  working_hand bigint,
  points_balance bigint
)
language sql
stable
security definer
set search_path = public
as $$
  select
    m.user_id as member_id,
    u.display_name as display_name,
    coalesce((
      select sum(cw.points_withdrawn)
      from public.casino_withdrawals cw
      where cw.session_id = p_event_id
        and cw.member_id = m.user_id
        and not exists (
          select 1 from public.casino_scans cs
          where cs.session_id = cw.session_id
            and cs.member_id = cw.member_id
            and cs.finalized_at is not null
        )
    ), 0)::bigint as working_hand,
    m.points_balance as points_balance
  from public.room_memberships m
  join public.events e on e.id = p_event_id
  join public.users u on u.id = m.user_id
  where m.room_id = e.room_id
    and exists (
      select 1 from public.room_memberships rm
      where rm.room_id = e.room_id
        and rm.user_id = public.current_user_id()
    )
  order by
    case when m.role = 'host' then 0 else 1 end,
    u.display_name;
$$;

grant execute on function public.get_event_working_hands(uuid) to authenticated;

notify pgrst, 'reload schema';
