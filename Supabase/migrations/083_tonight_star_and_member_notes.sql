-- 083: V0.84 C2+C5 — Tonight's Star host-pick persistence + room member notes.
--
-- Closes the V0.84 slice: hosts can override Tonight's Star away
-- from the 067 chip-swing default with a category + optional custom
-- line; members leave a one-line drop for the host to read on the
-- next pre-event visit. Both surfaces are pull-based (read on
-- next open, not push), matching the app's pull-only model.
--
-- Adds:
--   1. tonight_star_picks — host pick per event (one row per
--      session, upserts on unique(event_id)). RLS: members read
--      (is_room_member), no direct writes (RPC only — write
--      policy is with check (false)).
--   2. room_member_notes — member's one-line drop per room.
--      RLS: members read own rows in their rooms; host reads
--      the room's rows; no direct writes (RPC only). No
--      reply/thread columns — one-way.
--   3. set_tonight_star_pick(p_event_id, p_member_id,
--      p_override_category, p_custom_text) — host-only
--      (event→room→created_by == caller). Upserts on
--      unique(event_id). Validates custom ⇒ custom_text
--      non-empty; nulls it otherwise.
--   4. get_tonight_star_card(p_event_id) — returns one row
--      with (member_id, member_display_name, override_category,
--      custom_text, source). source = 'host_pick' when a
--      tonight_star_picks row exists; else falls through to the
--      067 chip-swing computation with source='chip_swing'.
--      Empty when neither. Membership-guarded.
--   5. submit_member_note(p_room_id, p_note_text) — member
--      writes own note. Guards: caller is room member; trim
--      non-empty; ≤500 chars; at most one note per member per
--      calendar day (soft) — reject same-day duplicates with a
--      clear errcode. Sets season_id from the room's active
--      season (may be null when no active season yet).
--   6. get_unconsumed_member_notes(p_room_id) — host-only;
--      returns notes where consumed_by_host_at is null, oldest
--      first, joined with display names. Returns room_id so the
--      Swift decode matches RoomMemberNote.CodingKeys.
--   7. mark_member_notes_consumed(p_room_id, p_note_ids
--      uuid[]) — host-only; stamps consumed_by_host_at = now()
--      on the listed notes.

-- =================================================================
-- 1. tonight_star_picks — host-pick persistence
-- =================================================================
create table if not exists public.tonight_star_picks (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  member_id uuid not null references public.users(id) on delete cascade,
  override_category text not null check (override_category in ('best_play','good_sport','held_the_room','showed_up','custom')),
  custom_text text,
  created_at timestamptz not null default now(),
  unique (event_id)
);

alter table public.tonight_star_picks enable row level security;

drop policy if exists tonight_star_picks_select_members on public.tonight_star_picks;
create policy tonight_star_picks_select_members
  on public.tonight_star_picks for select
  to authenticated
  using (
    exists (
      select 1 from public.room_memberships rm
      where rm.room_id = tonight_star_picks.room_id
        and rm.user_id = public.current_user_id()
    )
  );

drop policy if exists tonight_star_picks_insert_blocked on public.tonight_star_picks;
create policy tonight_star_picks_insert_blocked
  on public.tonight_star_picks for insert
  to authenticated
  with check (false);

drop policy if exists tonight_star_picks_update_blocked on public.tonight_star_picks;
create policy tonight_star_picks_update_blocked
  on public.tonight_star_picks for update
  to authenticated
  using (false)
  with check (false);

drop policy if exists tonight_star_picks_delete_blocked on public.tonight_star_picks;
create policy tonight_star_picks_delete_blocked
  on public.tonight_star_picks for delete
  to authenticated
  using (false);

-- =================================================================
-- 2. room_member_notes — one-line drop
-- =================================================================
create table if not exists public.room_member_notes (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  member_id uuid not null references public.users(id) on delete cascade,
  season_id uuid references public.seasons(id) on delete set null,
  note_text text not null,
  created_at timestamptz not null default now(),
  consumed_by_host_at timestamptz
);

alter table public.room_member_notes enable row level security;

drop policy if exists room_member_notes_select_members on public.room_member_notes;
create policy room_member_notes_select_members
  on public.room_member_notes for select
  to authenticated
  using (
    member_id = public.current_user_id()
    or exists (
      select 1 from public.rooms r
      where r.id = room_member_notes.room_id
        and r.created_by = public.current_user_id()
    )
  );

drop policy if exists room_member_notes_insert_blocked on public.room_member_notes;
create policy room_member_notes_insert_blocked
  on public.room_member_notes for insert
  to authenticated
  with check (false);

drop policy if exists room_member_notes_update_blocked on public.room_member_notes;
create policy room_member_notes_update_blocked
  on public.room_member_notes for update
  to authenticated
  using (false)
  with check (false);

drop policy if exists room_member_notes_delete_blocked on public.room_member_notes;
create policy room_member_notes_delete_blocked
  on public.room_member_notes for delete
  to authenticated
  using (false);

create index if not exists room_member_notes_room_unconsumed_idx
  on public.room_member_notes (room_id, consumed_by_host_at, created_at);

-- =================================================================
-- 3. set_tonight_star_pick — host-only upsert
-- =================================================================
create or replace function public.set_tonight_star_pick(
  p_event_id uuid,
  p_member_id uuid,
  p_override_category text,
  p_custom_text text
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_custom_text text;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if p_override_category not in ('best_play','good_sport','held_the_room','showed_up','custom') then
    raise exception 'Unknown override_category' using errcode = '22023';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can set Tonight''s Star' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = p_member_id
  ) then
    raise exception 'Picked member is not in this room' using errcode = '22023';
  end if;

  if p_override_category = 'custom' then
    v_custom_text := nullif(trim(coalesce(p_custom_text, '')), '');
    if v_custom_text is null then
      raise exception 'Custom category requires a non-empty custom_text' using errcode = '22023';
    end if;
  else
    v_custom_text := null;
  end if;

  insert into public.tonight_star_picks (
    event_id, room_id, member_id, override_category, custom_text, created_at
  ) values (
    p_event_id, v_room_id, p_member_id, p_override_category, v_custom_text, now()
  )
  on conflict (event_id) do update
    set member_id = excluded.member_id,
        override_category = excluded.override_category,
        custom_text = excluded.custom_text,
        created_at = now();

  return true;
end;
$$;

grant execute on function public.set_tonight_star_pick(uuid, uuid, text, text) to authenticated;

comment on function public.set_tonight_star_pick(uuid, uuid, text, text) is
  'Host-only. Upserts the host''s Tonight''s Star pick for an event. Validates custom ⇒ custom_text non-empty; nulls custom_text otherwise. C2 (Carnegie Champions).';

-- =================================================================
-- 4. get_tonight_star_card — host-pick wins, else chip-swing.
-- =================================================================
create or replace function public.get_tonight_star_card(p_event_id uuid)
returns table (
  member_id uuid,
  member_display_name text,
  override_category text,
  custom_text text,
  source text
)
language sql
stable
security definer
set search_path = public
as $$
  with pick as (
    select tsp.member_id,
           coalesce(u.display_name, 'Member') as member_display_name,
           tsp.override_category,
           tsp.custom_text,
           'host_pick'::text as source
    from public.tonight_star_picks tsp
    join public.users u on u.id = tsp.member_id
    where tsp.event_id = p_event_id
  ),
  chip as (
    select t.member_id,
           coalesce(u.display_name, 'Member') as member_display_name,
           null::text as override_category,
           null::text as custom_text,
           'chip_swing'::text as source
    from public.transactions t
    join public.users u on u.id = t.member_id
    where t.session_id = p_event_id
      and t.kind = 'casino_settlement'
    group by t.member_id, u.display_name
    having sum(t.amount_points) > 0
    order by sum(t.amount_points) desc, t.member_id
    limit 1
  ),
  guarded as (
    select exists (
      select 1 from public.events e
      join public.room_memberships rm on rm.room_id = e.room_id
      where e.id = p_event_id
        and rm.user_id = public.current_user_id()
    ) as is_member
  )
  select pick.member_id, pick.member_display_name, pick.override_category, pick.custom_text, pick.source
  from pick, guarded
  where guarded.is_member
  union all
  select chip.member_id, chip.member_display_name, chip.override_category, chip.custom_text, chip.source
  from chip, guarded
  where guarded.is_member
    and not exists (select 1 from pick);
$$;

grant execute on function public.get_tonight_star_card(uuid) to authenticated;

comment on function public.get_tonight_star_card(uuid) is
  'Membership-guarded read of Tonight''s Star for one event. Returns a host_pick row when tonight_star_picks has one; else the 067 chip-swing computation with source=chip_swing; empty when neither. C2 + C5.';

-- =================================================================
-- 5. submit_member_note — member writes own note
-- =================================================================
create or replace function public.submit_member_note(
  p_room_id uuid,
  p_note_text text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_text text;
  v_season_id uuid;
  v_note_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = p_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Only room members can submit notes' using errcode = '42501';
  end if;

  v_text := nullif(trim(coalesce(p_note_text, '')), '');
  if v_text is null then
    raise exception 'Note text cannot be empty' using errcode = '22023';
  end if;

  if char_length(v_text) > 500 then
    raise exception 'Note text exceeds 500 characters' using errcode = '22023';
  end if;

  -- Soft rate: at most one note per member per calendar day.
  if exists (
    select 1 from public.room_member_notes n
    where n.room_id = p_room_id
      and n.member_id = v_caller
      and n.created_at >= date_trunc('day', now())
      and n.created_at < date_trunc('day', now()) + interval '1 day'
  ) then
    raise exception 'You already left a note today' using errcode = '22023';
  end if;

  select id into v_season_id
  from public.seasons
  where room_id = p_room_id and status = 'active'
  limit 1;

  insert into public.room_member_notes (
    room_id, member_id, season_id, note_text, created_at
  ) values (
    p_room_id, v_caller, v_season_id, v_text, now()
  )
  returning id into v_note_id;

  return v_note_id;
end;
$$;

grant execute on function public.submit_member_note(uuid, text) to authenticated;

comment on function public.submit_member_note(uuid, text) is
  'Member writes one''s own room_member_notes row. Guards: caller is room member; trim non-empty; ≤500 chars; at most one per member per calendar day. Sets season_id from the room''s active season (null when none). C5.';

-- =================================================================
-- 6. get_unconsumed_member_notes — host-only read
-- =================================================================
create or replace function public.get_unconsumed_member_notes(p_room_id uuid)
returns table (
  id uuid,
  room_id uuid,
  member_id uuid,
  member_display_name text,
  note_text text,
  created_at timestamptz,
  consumed_by_host_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select n.id,
         n.room_id,
         n.member_id,
         coalesce(u.display_name, 'Member') as member_display_name,
         n.note_text,
         n.created_at,
         n.consumed_by_host_at
  from public.room_member_notes n
  join public.users u on u.id = n.member_id
  where n.room_id = p_room_id
    and n.consumed_by_host_at is null
    and exists (
      select 1 from public.rooms r
      where r.id = n.room_id and r.created_by = public.current_user_id()
    )
  order by n.created_at asc;
$$;

grant execute on function public.get_unconsumed_member_notes(uuid) to authenticated;

comment on function public.get_unconsumed_member_notes(uuid) is
  'Host-only. Returns the room''s unconsumed room_member_notes rows, oldest first, joined with member display names. C5.';

-- =================================================================
-- 7. mark_member_notes_consumed — host-only stamp
-- =================================================================
create or replace function public.mark_member_notes_consumed(
  p_room_id uuid,
  p_note_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller uuid := public.current_user_id();
  v_count integer;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = p_room_id and r.created_by = v_caller
  ) then
    raise exception 'Only the host can mark notes consumed' using errcode = '42501';
  end if;

  update public.room_member_notes n
    set consumed_by_host_at = now()
  where n.room_id = p_room_id
    and n.id = any(p_note_ids)
    and n.consumed_by_host_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.mark_member_notes_consumed(uuid, uuid[]) to authenticated;

comment on function public.mark_member_notes_consumed(uuid, uuid[]) is
  'Host-only. Stamps consumed_by_host_at = now() on the listed unconsumed notes belonging to the room. Returns the number of rows stamped. C5.';