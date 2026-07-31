-- 022: V0.12 Slice 1 — Schema + RPCs (host tools).
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/022_v0.12_host_tools.sql
--
-- Adds:
--   * public.room_blacklist table (per-room, composite PK on (room_id, user_id))
--   * 6 RPCs: delete_event, update_event_played_at, get_room_blacklist,
--     add_to_blacklist, remove_from_blacklist, search_discoverable_users
--   * public.create_room (drop + create) accepting p_blacklisted_user_ids

-- ── 1. New table ─────────────────────────────────────────────────
create table if not exists public.room_blacklist (
  room_id  uuid not null references public.rooms(id) on delete cascade,
  user_id  uuid not null references public.users(id) on delete cascade,
  added_by uuid not null references public.users(id),
  added_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create index room_blacklist_room_id_idx on public.room_blacklist using btree (room_id);
create index room_blacklist_user_id_idx on public.room_blacklist using btree (user_id);

-- ── 2. RLS on the new table ──────────────────────────────────────
alter table public.room_blacklist enable row level security;

drop policy if exists "Host reads blacklist" on public.room_blacklist;
drop policy if exists "Host writes blacklist" on public.room_blacklist;

create policy "Host reads blacklist" on public.room_blacklist
  for select using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = room_blacklist.room_id
        and m.user_id = public.current_user_id()
        and m.role = 'host'
    )
  );

create policy "Host writes blacklist" on public.room_blacklist
  for all using (
    exists (
      select 1 from public.room_memberships m
      where m.room_id = room_blacklist.room_id
        and m.user_id = public.current_user_id()
        and m.role = 'host'
    )
  );

-- ── 3. RPCs ──────────────────────────────────────────────────────

-- delete_event — host-only cascade delete on a single event.
-- event_packs and scores cascade on event_id FK; explicit deletes
-- kept for clarity and to surface any future orphans early.
create or replace function public.delete_event(p_event_id uuid)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can delete events' using errcode = '42501';
  end if;

  delete from public.event_packs where event_id = p_event_id;
  delete from public.events where id = p_event_id;

  return true;
end;
$$;

grant execute on function public.delete_event(uuid) to authenticated;

-- update_event_played_at — host-only reschedule. Future-only.
create or replace function public.update_event_played_at(
  p_event_id  uuid,
  p_played_at timestamptz
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can change event dates'
      using errcode = '42501';
  end if;

  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;

  update public.events
  set played_at = p_played_at
  where id = p_event_id;

  return true;
end;
$$;

grant execute on function public.update_event_played_at(uuid, timestamptz)
  to authenticated;

-- get_room_blacklist — list users the host has blocked from this room.
create or replace function public.get_room_blacklist(p_room_id uuid)
returns table (
  user_id     uuid,
  display_name text,
  added_at    timestamptz
)
language sql
security definer
stable
as $$
  select rb.user_id, u.display_name, rb.added_at
  from public.room_blacklist rb
  join public.users u on u.id = rb.user_id
  where rb.room_id = p_room_id
  order by rb.added_at desc;
$$;

grant execute on function public.get_room_blacklist(uuid) to authenticated;

-- add_to_blacklist — host inserts; idempotent on conflict.
create or replace function public.add_to_blacklist(
  p_room_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
as $$
declare v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can blacklist users' using errcode = '42501';
  end if;

  insert into public.room_blacklist (room_id, user_id, added_by)
  values (p_room_id, p_user_id, v_caller)
  on conflict (room_id, user_id) do nothing;

  return true;
end;
$$;

grant execute on function public.add_to_blacklist(uuid, uuid) to authenticated;

-- remove_from_blacklist — host deletes; idempotent.
create or replace function public.remove_from_blacklist(
  p_room_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
as $$
declare v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can manage the blacklist'
      using errcode = '42501';
  end if;

  delete from public.room_blacklist
  where room_id = p_room_id and user_id = p_user_id;

  return true;
end;
$$;

grant execute on function public.remove_from_blacklist(uuid, uuid) to authenticated;

-- search_discoverable_users — fuzzy match by display_name, exclude
-- the caller themselves and anyone already blacklisted in p_room_id.
create or replace function public.search_discoverable_users(
  p_room_id uuid,
  p_query   text
)
returns table (
  user_id      uuid,
  display_name text
)
language sql
security definer
stable
as $$
  select u.id, u.display_name
  from public.users u
  where u.display_name ilike '%' || coalesce(p_query, '') || '%'
    and u.id != public.current_user_id()
    and not exists (
      select 1 from public.room_blacklist rb
      where rb.room_id = p_room_id and rb.user_id = u.id
    )
  order by u.display_name
  limit 20;
$$;

grant execute on function public.search_discoverable_users(uuid, text)
  to authenticated;

-- ── 4. create_room — drop + re-create to pick up the blacklist param.
-- member_invite_quota / max_seats use the column defaults (3 / 6) to
-- keep the iOS call site small; callers that need different values can
-- edit via update_room right after creation.
drop function if exists public.create_room(
  text, text, text, text, integer, text, uuid[]
);

create function public.create_room(
  p_name                    text,
  p_mascot_name             text,
  p_mascot_personality      text,
  p_mascot_political_ideology text,
  p_join_starting_bonus     integer default 200,
  p_mascot_api_key          text default null,
  p_blacklisted_user_ids    uuid[] default '{}'::uuid[]
)
returns uuid
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  insert into public.rooms (
    name, mascot_name, mascot_personality, mascot_political_ideology,
    created_by, join_starting_bonus, mascot_api_key
  ) values (
    p_name, p_mascot_name,
    p_mascot_personality::public.mascot_personality,
    p_mascot_political_ideology,
    v_caller, p_join_starting_bonus, p_mascot_api_key
  )
  returning id into v_room_id;

  if p_blacklisted_user_ids is not null
     and array_length(p_blacklisted_user_ids, 1) is not null then
    insert into public.room_blacklist (room_id, user_id, added_by)
    select v_room_id, u, v_caller
    from unnest(p_blacklisted_user_ids) as u
    where u <> v_caller
    on conflict (room_id, user_id) do nothing;
  end if;

  return v_room_id;
end;
$$;

grant execute on function public.create_room(
  text, text, text, text, integer, text, uuid[]
) to authenticated;
