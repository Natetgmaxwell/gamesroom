-- 072: V0.72 — surface member scan state in get_event_working_hands.
--
-- Problem: after a member scans their chips (the V0.72 hosted-vision
-- settle), the WitnessSlot badge still reads "Working hand: 100 pts"
-- until the HOST runs finalize_casino_session. The working-hand SQL
-- (migration 065) only treats a withdrawal as closed when a scan row
-- exists with finalized_at IS NOT NULL — and finalized_at is stamped
-- only by finalize_casino_session. So the member's badge lies for the
-- entire member-scanned → host-finalize window (often hours).
--
-- Fix: extend the RPC with has_scanned + scanned_value columns (the
-- member's own casino_scans row for this session, if any). The iOS
-- badge can then flip from "Working hand: N" to "Counted: X · awaiting
-- host" the moment the member's scan lands. working_hand semantics are
-- UNCHANGED — the host's outstanding-exposure view stays open until
-- finalize (host hasn't reconciled chips back to the bank yet).
--
-- Also: drop the migration-065 definition's reliance on finalized_at
-- for the member-facing scan state — the scan's existence (any
-- recorded_at) is the truth for the member. finalized_at keeps its
-- host-side meaning in get_my_open_withdrawal (040) and
-- finalize_casino_session (030).

drop function if exists public.get_event_working_hands(uuid);
create function public.get_event_working_hands(p_event_id uuid)
returns table (
  member_id uuid,
  display_name text,
  working_hand bigint,
  points_balance bigint,
  has_scanned boolean,
  scanned_value bigint
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
    m.points_balance as points_balance,
    exists (
      select 1 from public.casino_scans cs
      where cs.session_id = p_event_id
        and cs.member_id = m.user_id
    ) as has_scanned,
    (
      select cs.vision_amount_points
      from public.casino_scans cs
      where cs.session_id = p_event_id
        and cs.member_id = m.user_id
      order by cs.recorded_at desc
      limit 1
    ) as scanned_value
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
