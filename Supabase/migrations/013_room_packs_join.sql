-- v0.7.1: room_packs join table + RPCs.
-- Apply via:
--   PGPASSWORD='...' psql "host=aws-0-ap-southeast-1.pooler.supabase.com port=6543 user=postgres.bnrgkdcluopicqdpmrtu dbname=postgres sslmode=require" -v ON_ERROR_STOP=1 -f Supabase/migrations/013_room_packs_join.sql

-- 1. Join table: which packs each room has.
create table if not exists public.room_packs (
  room_id uuid not null references public.rooms(id) on delete cascade,
  pack_slug text not null references public.packs(slug) on delete cascade,
  added_at timestamptz default now() not null,
  added_by uuid references public.users(id) on delete set null,
  primary key (room_id, pack_slug)
);

create index room_packs_room_id_idx on public.room_packs using btree (room_id);

-- 2. RLS: members can read; hosts can write.
alter table public.room_packs enable row level security;

create policy "members can read room packs" on public.room_packs
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = room_packs.room_id and user_id = public.current_user_id())
  );

create policy "host can add a pack" on public.room_packs
  for insert with check (
    exists (select 1 from public.rooms
            where id = room_packs.room_id and created_by = public.current_user_id())
  );

create policy "host can remove a pack" on public.room_packs
  for delete using (
    exists (select 1 from public.rooms
            where id = room_packs.room_id and created_by = public.current_user_id())
  );

-- 3. RPC: add_pack_to_room. Host adds a pack to a room.
create or replace function public.add_pack_to_room(p_room_id uuid, p_pack_slug text)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can add packs' using errcode = '42501';
  end if;
  if not exists (select 1 from public.packs where slug = p_pack_slug) then
    raise exception 'Unknown pack' using errcode = 'P0002';
  end if;
  insert into public.room_packs (room_id, pack_slug, added_by)
  values (p_room_id, p_pack_slug, v_caller)
  on conflict do nothing;
  return true;
end;
$$;

grant execute on function public.add_pack_to_room(uuid, text) to authenticated;

-- 4. RPC: remove_pack_from_room. Host removes a pack from a room.
create or replace function public.remove_pack_from_room(p_room_id uuid, p_pack_slug text)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can remove packs' using errcode = '42501';
  end if;
  delete from public.room_packs where room_id = p_room_id and pack_slug = p_pack_slug;
  return true;
end;
$$;

grant execute on function public.remove_pack_from_room(uuid, text) to authenticated;

-- 5. RPC: get_room_packs. List the packs in a room.
create or replace function public.get_room_packs(p_room_id uuid)
returns table (pack_slug text, display_name text, description text, scoring_type text, added_at timestamptz)
language sql
security definer
stable
as $$
  select rp.pack_slug, p.display_name, p.description, p.scoring_type, rp.added_at
  from public.room_packs rp
  join public.packs p on p.slug = rp.pack_slug
  where rp.room_id = p_room_id
  order by rp.added_at;
$$;

grant execute on function public.get_room_packs(uuid) to authenticated;

-- 6. RPC: list_available_packs. All packs in the global pool.
create or replace function public.list_available_packs()
returns table (slug text, display_name text, description text, scoring_type text, win_points int, withdraw_default int)
language sql
security definer
stable
as $$
  select slug, display_name, description, scoring_type, win_points, withdraw_default
  from public.packs
  order by display_name;
$$;

grant execute on function public.list_available_packs() to authenticated;
