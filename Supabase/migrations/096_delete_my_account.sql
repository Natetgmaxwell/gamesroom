-- 096: In-app account deletion (App Review Guideline 5.1.1(v)).
--
-- Background:
--   Apple rejected Games Room v1 (build 10) on 2026-09-16 under
--   guideline 5.1.1(v): the app supported account creation but
--   offered no in-app path to delete the account. The only path
--   was customer support, which is disallowed outside highly
--   regulated industries. The fix MUST ship in build 11.
--
--   The user-visible flow (Settings → Delete Account → confirm →
--   signed out) lives in iOS; this migration provides the
--   server-side half: a SECURITY DEFINER RPC that atomically
--   deletes the signed-in user's app data AND the auth row.
--
-- Schema analysis (pre-migration-verification, see
-- projects/games-room-app-store-rejection-2026-09-16 for the
-- rejection record and the live-schema FK audit):
--
--   * public.users.id -> auth.users(id) on delete cascade.
--   * Every domain table FKs to public.users(id) (NOT auth.users).
--   * Most FKs already declare on delete cascade / set null:
--       CASCADE: casino_scans, casino_withdrawals (member_id),
--                event_seats, room_member_notes, room_memberships
--                (user_id), rooms (created_by), round_submissions
--                was missing — see #1 below, scan_attempts,
--                season_awards (recipient), season_summaries,
--                seat_deposits (user_id), settlement_attestations,
--                tonight_star_picks, transactions (member_id),
--                scores
--       SET NULL: events.created_by, join_codes.{generated_by,
--                 invitee_user_id, redeemed_by},
--                 room_memberships.invited_by, room_packs.added_by,
--                 casino_withdrawals.withdrawn_by,
--                 seat_deposits.forfeited_by,
--                 transactions.created_by
--   * Three NOT NULL FKs blocked auth.users deletion before this
--     migration:
--       1. round_submissions.created_by — `references public.users(id)`
--          with NO on delete clause (defaults to NO ACTION). When the
--          user hosts rounds in a room they did NOT own (rare but
--          legal — transfer_host_role allows a former host to keep
--          round_submissions behind in the new host's room), the
--          FK blocks the delete. Fix: tighten to on delete cascade.
--       2. events.created_by — already SET NULL but the column is
--          NOT NULL, so the cascade raises 23502 before reaching
--          the FK rule. Fix: drop NOT NULL (the schema migration
--          058 already made the FK SET NULL).
--       3. casino_withdrawals.withdrawn_by — same shape as #2.
--          Fix: drop NOT NULL.
--
-- Why a single RPC instead of a client-side cascade
-- -------------------------------------------------
-- The client could in principle delete rows through PostgREST
-- one-by-one using RLS-scoped permissions, then call auth.signOut
-- and request an admin-side auth.users delete through an Edge
-- Function. Two reasons that's worse:
--   1. Atomicity — the user must not be left with a partially
--      deleted account (rooms half-deleted, transactions half-
--      deleted). One RPC, one transaction, one roll-back on any
--      failure.
--   2. RLS — most domain writes are blocked for the user
--      themselves (no direct inserts on room_memberships,
--      transactions, scores, etc.). The RPC's SECURITY DEFINER
--      context bypasses those gates.
--
-- Why we DON'T use a service-role Edge Function
--   Supabase's auth.admin.deleteUser() is reachable via the
--   service-role key, but shipping that key into the client bundle
--   would be a regression. The RPC approach needs only the user's
--   JWT — auth.uid() inside the SECURITY DEFINER function is
--   sufficient because the function's owner (postgres) can
--   delete from auth.users.
--
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/096_delete_my_account.sql

-- =================================================================
-- 1. round_submissions.created_by: tighten to ON DELETE CASCADE.
-- =================================================================
alter table public.round_submissions
  drop constraint if exists round_submissions_created_by_fkey;
alter table public.round_submissions
  add constraint round_submissions_created_by_fkey
  foreign key (created_by) references public.users(id) on delete cascade;

comment on constraint round_submissions_created_by_fkey on public.round_submissions is
  '096: ON DELETE CASCADE so a user''s account deletion removes their round submissions. The events they belong to are removed via rooms→events→round_submissions in the rooms-delete cascade; this catches the residual case where the user recorded a round in a room they no longer own.';

-- =================================================================
-- 2. events.created_by: drop NOT NULL so SET NULL can fire.
-- =================================================================
alter table public.events
  alter column created_by drop not null;

comment on column public.events.created_by is
  '096: nullable. Account deletion sets this to NULL via the FK ON DELETE SET NULL rule. Existing rows are backfilled to NULL only on the affected account.';

-- =================================================================
-- 3. casino_withdrawals.withdrawn_by: drop NOT NULL so SET NULL
--    can fire.
-- =================================================================
alter table public.casino_withdrawals
  alter column withdrawn_by drop not null;

comment on column public.casino_withdrawals.withdrawn_by is
  '096: nullable. Account deletion sets this to NULL via the FK ON DELETE SET NULL rule.';

-- =================================================================
-- 4. delete_my_account() — the single RPC the iOS app calls.
-- =================================================================
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_count_users integer;
  v_count_auth integer;
begin
  if v_user_id is null then
    raise exception 'Not authenticated'
      using errcode = '42501';
  end if;

  -- Defensive pre-check. If the auth.users row is somehow already
  -- missing (e.g. a previous attempt partially succeeded), the
  -- public.users row is also gone and the function should be a
  -- no-op rather than raising a confusing FK error.
  select count(*) into v_count_users from public.users where id = v_user_id;
  select count(*) into v_count_auth from auth.users where id = v_user_id;

  if v_count_users = 0 and v_count_auth = 0 then
    return;
  end if;

  -- Delete public.users first. The cascade rules then remove
  -- every domain table that references public.users(id) via
  -- ON DELETE CASCADE:
  --   rooms (created_by) — deleting the rooms cascades further
  --     into events, event_seats, event_rsvps, casino_scans,
  --     casino_withdrawals (member_id), transactions (member_id),
  --     scores, season_awards, season_summaries, seat_deposits,
  --     settlement_attestations, tonight_star_picks, chapter_lines,
  --     room_memberships (user_id), room_member_notes, scan_attempts,
  --     event_packs, room_pack_configs, room_packs, room_system_events,
  --     join_codes (no — set null), sent_notifications (via events),
  --     chapter_lines (via rooms/memberships), etc.
  -- The SET NULL FKs (events.created_by, join_codes.*, etc.) leave
  -- the orphaned rows in place with their creator pointer cleared —
  -- acceptable because the row belongs to a room whose host is gone.
  delete from public.users where id = v_user_id;

  -- Delete from auth.users. This invalidates the user's session
  -- on the client. The iOS code calls auth.signOut() immediately
  -- after this RPC returns; signOut may throw (session is already
  -- dead) which the caller tolerates via try? in AuthService.
  delete from auth.users where id = v_user_id;
end;
$$;

revoke all on function public.delete_my_account() from public;
grant execute on function public.delete_my_account() to authenticated;

comment on function public.delete_my_account() is
  '096 (App Review 5.1.1(v)): signed-in user deletes their own account. Removes the public.users row (cascades through every domain table) and the auth.users row in a single transaction. No argument, no return — success is the absence of an exception. The caller (iOS AuthService.deleteAccount) signs out locally and clears the @AppStorage cache after this returns.';