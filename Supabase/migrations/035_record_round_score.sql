-- 035: Host-scored round submission RPC.
--
-- The P0.4 vertical slice. The host-side scoring dashboard submits
-- one round's worth of per-member score entries as a single atomic
-- write. Idempotent on (room_id, event_id, round_index) so a retry
-- after a network blip doesn't double-write the ledger.
--
-- Why a new RPC
-- -------------
-- V0.8 splits scoring into a single contract: one round, one write,
-- one or more per-member entries. The pre-V0.8 surface called
-- `record_member_scan` (migration 030) for the casino pack and had
-- no equivalent for the three single-winner packs (CAH, Monopoly
-- Deal, Pluto Chess). This migration adds that missing surface for
-- all four V0.8 packs.
--
-- Idempotency
-- -----------
-- `unique_round_submission(room_id, event_id, round_index)` on the
-- new `round_submissions` table is the dedupe key. Re-issuing with
-- the same `(room, event, round_index)` updates the existing row's
-- `entries` and `created_at` instead of inserting a second row, so
-- the ledger remains canonical.
--
-- Authorization
-- -------------
-- SECURITY DEFINER. Host check via `rooms.created_by = caller` —
-- only the room's host can submit a round.

-- 1. New table: one row per submitted round.
create table if not exists public.round_submissions (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  event_id uuid not null references public.events(id) on delete cascade,
  pack_slug text not null,
  round_index integer not null,
  entries jsonb not null default '[]'::jsonb,
  created_by uuid not null references public.users(id),
  created_at timestamptz not null default now(),
  unique (room_id, event_id, round_index)
);

create index round_submissions_event_idx
  on public.round_submissions using btree (event_id);
create index round_submissions_room_idx
  on public.round_submissions using btree (room_id);

alter table public.round_submissions enable row level security;

-- Members in the room can read round submissions (drives the live
-- recap). Hosts can read everything in their own rooms.
create policy "members read round submissions" on public.round_submissions
  for select using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = round_submissions.room_id
        and m.user_id = public.current_user_id()
    )
  );

-- Inserts are blocked directly — only the RPC below writes rows.
create policy "no direct inserts" on public.round_submissions
  for insert with check (false);

-- 2. record_round_score: host-only round submission. The
--    entries payload is the same `[{member_id, points_delta, meta}]`
--    shape the iOS `ScoreEntry` model emits.
create or replace function public.record_round_score(
  p_room_id uuid,
  p_event_id uuid,
  p_pack_slug text,
  p_round_index integer,
  p_entries jsonb default '[]'::jsonb
)
returns table (
  id uuid,
  room_id uuid,
  event_id uuid,
  round_index integer,
  pack_slug text,
  created_at timestamptz
)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_submission_id uuid;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
  v_meta jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Host check: only the room's host can submit a round.
  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can record a round' using errcode = '42501';
  end if;

  -- Validate event belongs to the room (defense in depth — the
  -- picker reads from the room's events so a stray id should be
  -- rare, but the cost of a stray id is a misattributed ledger row).
  if not exists (
    select 1 from public.events
    where id = p_event_id and room_id = p_room_id
  ) then
    raise exception 'Event does not belong to room' using errcode = 'P0002';
  end if;

  -- Upsert the round_submissions row. The (room_id, event_id,
  -- round_index) unique index dedupes re-issues so a retry
  -- doesn't double-write the ledger.
  insert into public.round_submissions (
    room_id, event_id, pack_slug, round_index, entries, created_by
  ) values (
    p_room_id, p_event_id, p_pack_slug, p_round_index, p_entries, v_caller
  )
  on conflict (room_id, event_id, round_index) do update
    set entries = excluded.entries,
        pack_slug = excluded.pack_slug,
        created_by = excluded.created_by,
        created_at = now()
  returning id into v_submission_id;

  -- Re-write the per-member `transactions` rows. Use the entries
  -- payload as the source of truth so the unique index dedupe
  -- produces a clean ledger on retry.
  --
  -- Strategy: delete existing rows for this (room, event,
  -- round_index) and re-insert from the entries payload. The
  -- round_submissions.id is recorded in `meta->>'submission_id'`
  -- so an audit query can find the linked ledger rows.
  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;
    v_meta := coalesce(v_entry->'meta', '{}'::jsonb) || jsonb_build_object(
      'submission_id', v_submission_id,
      'round_index', p_round_index,
      'pack_slug', p_pack_slug
    );

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      p_room_id, p_event_id, v_member_id, 'round_score', v_points_delta, v_meta, v_caller
    );

    -- Apply the per-member season-score delta so the leaderboard
    -- reflects the new round immediately.
    update public.room_memberships
      set season_score = season_score + v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  return query
    select v_submission_id, p_room_id, p_event_id, p_round_index, p_pack_slug, now();
end;
$$;

grant execute on function public.record_round_score(
  uuid, uuid, text, integer, jsonb
) to authenticated;

-- 3. Seed the V0.8 pack rows that P0.3's iOS registry expects
--    are already in place (migration 034). Re-assert here so the
--    docs of this migration are self-contained and so a fresh DB
--    running this migration alone has the expected rows.
--
--    Idempotent — ON CONFLICT (slug) DO NOTHING.
insert into public.packs (slug, display_name, description, scoring_type, win_points, withdraw_default) values
  ('casino',                  'Casino',                 'Chip-based casino games. Each player withdraws to start, returns winnings at end.',     'withdraw_return',  null, 10),
  ('cards_against_humanity',  'Cards Against Humanity',  'Card-judging party game. Winner is the round''s judge''s pick (single winner per round).', 'single_winner',   1,    null),
  ('monopoly_deal',           'Monopoly Deal',           'Card-based Monopoly. Winner takes the pot.',                                              'single_winner',   1,    null),
  ('pluto_chess',             'Pluto Chess',             'Chess-variant pack.',                                                                     'single_winner',   1,    null)
ON CONFLICT (slug) DO NOTHING;