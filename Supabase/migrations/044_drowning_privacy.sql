-- 044: F-MVP-11 / V0.9 — Drowning privacy opt-in (Wave 1 Slice 1.1).
--
-- Adds a per-membership opt-in for sharing the recipient's Drowning
-- season-end award with the room. Without this column, drowning rows
-- are private to the recipient only (migration 039 RLS).
--
-- The opt-in default is `false` (privacy-respecting per Q-DROWNING-OPT-IN-DEFAULT).
-- A member who wants their Drowning row visible to opted-in members + the
-- host flips this flag on for their own membership row. RLS in migration
-- 045 enforces the read-side boundary.
--
-- The column lives on room_memberships (not on users) because the
-- decision is per-room — a member who opts in to sharing in one room
-- should not be opted-in to sharing in every room.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/044_drowning_privacy.sql

alter table public.room_memberships
  add column if not exists member_drowning_opt_in boolean not null default false;

comment on column public.room_memberships.member_drowning_opt_in is
  'When true, this member consents to have their own Drowning season-end '
  'award row readable by other opted-in members + the host. Default false '
  '(privacy-respecting). Per-room decision; a member may opt in here and '
  'not in another room.';
