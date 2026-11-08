-- 112: Events belong to the room's active roster.
--
-- Lane S2B step 6. The table half of the lane goal ("kicked members
-- stop seeing events") and the RLS half of audit 04-interconnect F5.
--
-- The failure this exists to kill
--   public.events still carries the four policies from migration 011,
--   and every one of them predates the kick feature (093) and the
--   multi-host rooms (091, 094).
--
--   The read policy says "there is a room_memberships row with your
--   user_id in it". A kick is a status change and never a delete
--   (093), so that row is still there after the member is removed,
--   and the events of the room they were kicked out of stay readable:
--   the name of the night, the date, the host note. The events table
--   was the one room-scoped table 093 missed.
--
--   The three write policies say "you created the room"
--   (rooms.created_by). A room can have several hosts now, so a
--   promoted host cannot edit or cancel a night through PostgREST even
--   though add_event lets them create one, and a host who was kicked
--   keeps the keys to every event they ever made.
--
-- What this migration changes
--   1. "members can read events" gains m.membership_status = 'active'.
--      The hidden-from check from 090 stays exactly as it was.
--   2. "host can update events" and "host can delete events" move from
--      rooms.created_by to public.is_room_host(events.room_id,
--      public.current_user_id()) - the canonical host guard (095),
--      which counts an ACTIVE host-role membership and nothing else.
--   3. "host can insert events" moves to the same guard.
--
-- The decision the brief left open: the INSERT policy
--   The brief for this step names the UPDATE and DELETE policies. The
--   INSERT policy keys on the same rooms.created_by and has the same
--   defect - a promoted host can create a night through add_event
--   (095 already accepts is_room_host there) but would be refused by
--   the table policy. Two guards that disagree about who is a host is
--   how a host ends up locked out of their own room, which is exactly
--   what 095 and 106 were written to stop. So the insert policy moves
--   to is_room_host as well, and the four policies now agree with the
--   RPCs.
--
-- What did NOT change
--   * the hidden-from list: a member the host hid from one event still
--     does not see that event (090).
--   * the read scope: every ACTIVE member of the room still reads
--     every event of the room, settled or not, past or future.
--   * no RPC changed. add_event, add_event_with_packs, delete_event
--     and update_event_played_at already use is_room_host (095); this
--     migration only makes the table policies agree with them.
--   * rooms, room_memberships, event_rsvps and the rest of the room
--     tables are untouched. 093 already put the active filter on
--     room_memberships and rooms.
--
-- Note on the kicked member
--   093 gives room_memberships' own SELECT policies the active filter,
--   so a kicked member already cannot see their own membership row
--   through PostgREST, and the exists() below runs with the caller's
--   permissions - so the read policy was already closed by the back
--   door. This migration makes the events policy say what it means on
--   its own, instead of leaning on another table's policy to keep the
--   secret. Belt and braces, in that order.
--
-- Applying
--   Migrations are written, never applied by an agent. Nathan applies
--   this one after 111.

begin;

-- =================================================================
-- 1. Read policy: active members only, hidden-from list unchanged.
-- =================================================================
drop policy if exists "members can read events" on public.events;

create policy "members can read events"
  on public.events for select
  using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = events.room_id
        and m.user_id = public.current_user_id()
        and m.membership_status = 'active'
    )
    and not (public.current_user_id() = any(events.hidden_from_user_ids))
  );

comment on policy "members can read events" on public.events is
  'S2B.6 — an ACTIVE member of the room reads the room''s events, minus the ones the host hid them from. A kicked member reads nothing. Migration 090 added the hidden-from check; 112 added the active-membership check.';

-- =================================================================
-- 2. Write policies: the canonical host guard, not rooms.created_by.
-- =================================================================
drop policy if exists "host can insert events" on public.events;

create policy "host can insert events"
  on public.events for insert
  with check (
    public.is_room_host(events.room_id, public.current_user_id())
  );

comment on policy "host can insert events" on public.events is
  'S2B.6 — an active host-role member of the room creates the event. Same guard as add_event (095), so a promoted host is not locked out by the table policy.';

drop policy if exists "host can update events" on public.events;

create policy "host can update events"
  on public.events for update
  using (
    public.is_room_host(events.room_id, public.current_user_id())
  );

comment on policy "host can update events" on public.events is
  'S2B.6 — an active host-role member of the room edits the event. The old guard was the room creator alone, which locked out promoted hosts and left a kicked host holding the keys.';

drop policy if exists "host can delete events" on public.events;

create policy "host can delete events"
  on public.events for delete
  using (
    public.is_room_host(events.room_id, public.current_user_id())
  );

comment on policy "host can delete events" on public.events is
  'S2B.6 — an active host-role member of the room cancels the night. Same guard as the update policy.';

commit;
