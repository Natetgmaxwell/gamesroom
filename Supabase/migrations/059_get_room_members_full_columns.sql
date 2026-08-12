-- 059: get_room_members — restore the full membership column set.
--
-- The RPC drifted across migrations 008→017→019→049 and only
-- returned `user_id`, `display_name`, `role`, `points_balance`,
-- `season_score`, `team`; the iOS `Member` model needs `room_id`,
-- `joined_at`, `last_seen_at` and the social-preference columns.
-- The client now tolerates their absence (the model decodes them
-- with `decodeIfPresent`), but the RPC should return them so the
-- leaderboard, roster card and MemberNotes surface can render
-- from a single round-trip.
--
-- Adds:
--   1. `room_memberships.last_seen_at` — nullable timestamptz; the
--      column does not exist in any prior migration, nothing
--      writes it yet, NULL is fine.
--   2. `get_room_members(p_room_id)` — redefined to return the
--      full membership column set. DROP then CREATE (the RETURNS
--      TABLE column list changed).

-- =================================================================
-- 1. room_memberships.last_seen_at
-- =================================================================
alter table public.room_memberships
  add column if not exists last_seen_at timestamptz;

comment on column public.room_memberships.last_seen_at is
  'Last time the user opened this room''s page. Drives the "still here?" amber wash on quiet state. No writer yet (column added in migration 059 for RPC completeness); NULL is the expected value.';

-- =================================================================
-- 2. get_room_members + full column set
-- =================================================================
drop function if exists public.get_room_members(uuid);
create function public.get_room_members(p_room_id uuid)
returns table (
  user_id uuid,
  room_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  team text,
  joined_at timestamptz,
  last_seen_at timestamptz,
  preferences_social text,
  preferences_conversation_prompt text,
  preferences_default_set boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select m.user_id, m.room_id, u.display_name, m.role::text,
         m.points_balance, m.season_score, m.team,
         m.joined_at, m.last_seen_at,
         m.preferences_social, m.preferences_conversation_prompt,
         m.preferences_default_set
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_members(uuid) to authenticated;