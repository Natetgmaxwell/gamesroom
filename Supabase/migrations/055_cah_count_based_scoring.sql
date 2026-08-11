-- 055: CAH count-based scoring (V0.34).
--
-- The V0.8 Cards Against Humanity pack was scored as
-- `single_winner` with one win-point per round. The real
-- game's score is the COUNT of black cards held at session
-- end — the judge's pick wins the round and keeps the black
-- card. This migration switches CAH to a new `count_based`
-- scoring type and adds the `record_cah_tally` RPC the
-- iOS `CAHCardScanSheet` (migration-055 surface) calls.
--
-- Score model
-- ------------
--   1. The host records per-round entries via the existing
--      `record_round_score` RPC. The `PackScoringResolver`
--      emits a single `round_score` transaction with
--      `amount_points = cardCount` (default 1) and meta
--      `{cards_won, round_index}`. The ledger rows are kept
--      for audit / per-round breakdown.
--   2. At session end each member scans their stack of won
--      black cards on their own phone. The iOS detector
--      (LOCKED `ChipSegmentationDetector(pxPerUnit: 2)`)
--      produces a rough estimate; the member confirms or
--      adjusts before submitting.
--   3. `record_cah_tally(p_event_id, p_card_count,
--      p_vision_snapshot)` runs. It sums the caller's existing
--      `round_score` transactions for the event into
--      `v_old_total`, deletes them, inserts ONE replacement
--      `round_score` transaction with the scanned count +
--      `meta->>'tally' = true`, and reconciles
--      `room_memberships.season_score` to the new total.
--   4. Re-scan converges: every call deletes the previous
--      tally row (matched by `meta->>'tally' = true`) and
--      inserts a fresh one. The ledger stays canonical.
--
-- Why the tally REPLACES the per-round entries
-- ---------------------------------------------
-- The scan is the authoritative count at session end. A
-- member who never scans has their per-round host entries
-- standing (sum of cards won across the night). A member who
-- scans at session end has those per-round entries replaced
-- by the single tally row. The `round_submissions` table
-- keeps the host's per-round history for audit; the ledger
-- stays in sync with the authoritative count.
--
-- Idempotency
-- -----------
-- The tally delete-then-insert pattern is naturally
-- idempotent on (room, event, member, tally=true). Re-running
-- the same call converges to the same ledger state.

-- 1. Drop the V0.8 CHECK on `packs.scoring_type` and replace
--    it with the V0.34 set that includes `count_based`.
alter table public.packs drop constraint if exists packs_scoring_type_check;
alter table public.packs
  add constraint packs_scoring_type_check
    check (scoring_type in ('single_winner', 'withdraw_return', 'count_based'));

-- 2. Update the CAH pack row to the new scoring type + the
--    V0.34 description. The display name + win_points (1,
--    the default per-round count) are unchanged.
update public.packs
  set scoring_type = 'count_based',
      description = 'Card-judging party game. The judge''s pick wins the round and keeps the black card — score is cards won.'
  where slug = 'cards_against_humanity';

-- 3. record_cah_tally: member-only RPC. Records the
--    authoritative session-end count of black cards the
--    member holds for a CAH event. The tally REPLACES the
--    member's per-round `round_score` entries for the event
--    so the ledger reflects the scanned count, not the
--    host's per-round sum.
create or replace function public.record_cah_tally(
  p_event_id uuid,
  p_card_count bigint,
  p_vision_snapshot jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_pack_slug text;
  v_old_total bigint := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Derive room + pack from the event id.
  select e.room_id, e.pack_slug into v_room_id, v_pack_slug
    from public.events e
    where e.id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- The tally is only valid for a Cards Against Humanity event.
  if v_pack_slug is distinct from 'cards_against_humanity' then
    raise exception 'Event is not a Cards Against Humanity event' using errcode = 'P0002';
  end if;

  -- Caller must be a member of the room.
  if not exists (
    select 1 from public.room_memberships
    where room_id = v_room_id and user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Sum the caller's existing round_score transactions for this
  -- (room, event) so we can reverse the season_score delta on
  -- the way out (tally REPLACES the per-round entries).
  select coalesce(sum(amount_points), 0) into v_old_total
    from public.transactions
    where room_id = v_room_id
      and session_id = p_event_id
      and member_id = v_caller
      and kind = 'round_score';

  -- Delete the caller's existing per-round entries for this
  -- event. A prior tally row is also deleted (matched by
  -- meta->>'tally' = true) so re-scan converges.
  delete from public.transactions
    where room_id = v_room_id
      and session_id = p_event_id
      and member_id = v_caller
      and kind = 'round_score';

  -- Insert the single tally row.
  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, v_caller, 'round_score', p_card_count,
    jsonb_build_object(
      'cards_won', p_card_count,
      'tally', true,
      'vision_snapshot', p_vision_snapshot,
      'pack_slug', 'cards_against_humanity'
    ),
    v_caller
  );

  -- Reconcile the season score: subtract the old per-round
  -- total, add the new tally count. Members who never scanned
  -- keep their v_old_total; the scan converges to the new count.
  update public.room_memberships
    set season_score = season_score - v_old_total + p_card_count
    where user_id = v_caller and room_id = v_room_id;

  return true;
end;
$$;

grant execute on function public.record_cah_tally(uuid, bigint, jsonb) to authenticated;
