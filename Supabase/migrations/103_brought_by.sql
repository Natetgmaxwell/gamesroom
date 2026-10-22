-- 103: V0.107 Brought By — the anchor on the roster, plus the room switch.
--
-- Spec: docs/V0.107_BROUGHT_BY_SPEC.md (sections 3, 4 and 5).
--
-- What this migration adds
--   1. get_room_members(uuid) is dropped and recreated with the live
--      column set plus two at the end: invited_by uuid, invite_tier int.
--      invited_by is the anchor, and it is only carried when that person
--      still holds an ACTIVE membership in the same room (left join on
--      room_memberships). A kicked or departed inviter reads null, so a
--      kicked name can never reach a surface (spec section 1.5, D2).
--   2. rooms.show_brought_by boolean not null default true: the host
--      switch from spec section 3. The only schema change in the slice,
--      and it is additive.
--   3. get_show_brought_by(uuid) reads it for active members;
--      set_show_brought_by(uuid, bool) writes it behind the role-based
--      host check from migration 095 (is_room_host, never
--      rooms.created_by).
--
-- Security fix — why the roster is dropped rather than patched in place
--   The live get_room_members was SECURITY DEFINER with search_path = ''
--   and EXECUTE granted to PUBLIC, which includes anon, and it never
--   checked that the caller belongs to the room. Any unauthenticated
--   caller holding a room uuid could read the whole roster: display names,
--   chip balances, season scores, social preferences and notification
--   settings. V0.107 has to add the anchor to that same payload, so the
--   hole would have got wider before it got closed. Two changes close it:
--     * the where clause gains an active-membership guard on the caller,
--       so a non-member reads zero rows;
--     * execute is revoked from public and anon, granted to
--       authenticated only.
--   Both new functions are guarded the same way: the read needs an active
--   membership, the write needs a role-based host.
--
-- No new tables. Anchor data already exists (room_memberships.invited_by,
-- invite_tier, migration 068; invited_by is set null when the user row
-- goes away).
--
-- NOT applied to live. Written and gated here; the orchestrator applies
-- it after Nathan's sign-off:
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/103_brought_by.sql
--
-- Idempotent: drop-if-exists, add-column-if-not-exists, create-or-replace.
-- Rollback: drop function public.get_show_brought_by(uuid); drop function
-- public.set_show_brought_by(uuid, boolean); alter table public.rooms drop
-- column show_brought_by; then restore migration 093's get_room_members
-- body and its grants.
begin;

-- =================================================================
-- 1. Roster carries the anchor
-- =================================================================
-- Same columns as live (093 lineage), same where and order by, plus
-- invited_by / invite_tier and the caller guard.
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
  preferences_default_set boolean,
  notifications_enabled boolean,
  invited_by uuid,
  invite_tier int
)
language sql
security definer
stable
set search_path = ''
as $$
  select m.user_id, m.room_id, u.display_name, m.role::text,
         m.points_balance, m.season_score, m.team,
         m.joined_at, m.last_seen_at,
         m.preferences_social, m.preferences_conversation_prompt,
         m.preferences_default_set,
         coalesce(m.notifications_enabled, false) as notifications_enabled,
         i.user_id as invited_by,
         m.invite_tier
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  left join public.room_memberships i
    on i.room_id = m.room_id
   and i.user_id = m.invited_by
   and i.membership_status = 'active'
  where m.room_id = p_room_id
    and m.membership_status = 'active'
    -- Caller must hold an active membership in this room. Live had no
    -- such check, which is the anon-read hole described in the header.
    and exists (
      select 1 from public.room_memberships c
      where c.room_id = p_room_id
        and c.user_id = public.current_user_id()
        and c.membership_status = 'active'
    )
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

revoke all on function public.get_room_members(uuid) from public, anon;
grant execute on function public.get_room_members(uuid) to authenticated;

comment on function public.get_room_members(uuid) is
  'Room roster, active members only, host first. V0.107 adds invited_by (null unless the inviter is still an active member of this room) and invite_tier, and closes the anon read: the caller must be an active member, execute is revoked from public and anon.';

-- =================================================================
-- 2. Room switch
-- =================================================================
alter table public.rooms
  add column if not exists show_brought_by boolean not null default true;

comment on column public.rooms.show_brought_by is
  'V0.107 Brought By: host-only room switch. On shows "with Alex" under a newcomer name; off hides the anchor and first-night lines for the whole room (spec section 3).';

create or replace function public.get_show_brought_by(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No row for a non-member, so the client reads null and falls back to
  -- the column default (on).
  select r.show_brought_by
  from public.rooms r
  where r.id = p_room_id
    and exists (
      select 1 from public.room_memberships c
      where c.room_id = p_room_id
        and c.user_id = public.current_user_id()
        and c.membership_status = 'active'
    );
$$;

revoke all on function public.get_show_brought_by(uuid) from public, anon;
grant execute on function public.get_show_brought_by(uuid) to authenticated;

comment on function public.get_show_brought_by(uuid) is
  'Rooms.show_brought_by for an active member of the room, null otherwise. V0.107 Brought By host switch (spec section 3).';

create or replace function public.set_show_brought_by(p_room_id uuid, p_on boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.is_room_host(p_room_id, public.current_user_id()) then
    raise exception 'not_authorized' using errcode = '42501';
  end if;

  update public.rooms r
     set show_brought_by = p_on,
         updated_at = now()
   where r.id = p_room_id;
end;
$$;

revoke all on function public.set_show_brought_by(uuid, boolean) from public, anon;
grant execute on function public.set_show_brought_by(uuid, boolean) to authenticated;

comment on function public.set_show_brought_by(uuid, boolean) is
  'Sets rooms.show_brought_by. Host only, via is_room_host (migration 095); everyone else raises not_authorized (42501). V0.107 Brought By.';

commit;