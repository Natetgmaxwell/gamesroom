-- 020: Multi-pack events. Junction table.
-- Slice 1 used prefix 019 for season_score; Slice 3 takes 020 to avoid
-- the rename problem.
--
-- Apply via:
--   PGPASSWORD='...' psql -h aws-0-ap-southeast-1.pooler.supabase.com -p 6543 \
--     -U postgres.bnrgkdcluopicqdpmrtu -d postgres -v ON_ERROR_STOP=1 \
--     -f Supabase/migrations/020_event_packs.sql

-- 1. Junction table.
create table if not exists public.event_packs (
  event_id uuid not null references public.events(id) on delete cascade,
  pack_slug text not null references public.packs(slug) on delete cascade,
  primary key (event_id, pack_slug)
);

create index event_packs_event_id_idx on public.event_packs using btree (event_id);
create index event_packs_pack_slug_idx on public.event_packs using btree (pack_slug);

-- 2. RLS.
alter table public.event_packs enable row level security;

create policy "members can read event_packs" on public.event_packs
  for select using (
    exists (select 1 from public.room_memberships m
            join public.events e on e.room_id = m.room_id
            where e.id = event_packs.event_id and m.user_id = public.current_user_id())
  );

create policy "host can insert event_packs" on public.event_packs
  for insert with check (
    exists (select 1 from public.events e
            join public.rooms r on r.id = e.room_id
            where e.id = event_packs.event_id and r.created_by = public.current_user_id())
  );

-- 3. Backfill: every existing event with pack_slug gets a row.
insert into public.event_packs (event_id, pack_slug)
select id, pack_slug from public.events where pack_slug is not null;

-- 4. New RPC: add_event_with_packs. Replaces add_event for v0.9.
-- Auth-check pattern matches the existing add_event (caller + host).
create or replace function public.add_event_with_packs(
  p_room_id uuid,
  p_name text,
  p_played_at timestamptz,
  p_pack_slugs text[]
) returns uuid
language plpgsql security definer as $$
declare
  v_event_id uuid;
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rooms
                 where id = p_room_id and created_by = v_caller) then
    raise exception 'Only the host can create events' using errcode = '42501';
  end if;
  if p_pack_slugs is null or array_length(p_pack_slugs, 1) = 0 then
    raise exception 'At least one pack required' using errcode = '22023';
  end if;
  -- Validate every slug exists.
  if exists (
    select 1 from unnest(p_pack_slugs) as s(slug)
    where not exists (select 1 from public.packs where slug = s.slug)
  ) then
    raise exception 'Unknown pack in p_pack_slugs' using errcode = 'P0002';
  end if;

  -- Insert event. Set pack_slug to the first pack for legacy
  -- single-pack reads (kept until v0.10 cleanup).
  insert into public.events (room_id, name, played_at, pack_slug, created_by)
  values (p_room_id, p_name, p_played_at, p_pack_slugs[1], v_caller)
  returning id into v_event_id;

  -- Insert junction rows.
  insert into public.event_packs (event_id, pack_slug)
  select v_event_id, unnest(p_pack_slugs);

  return v_event_id;
end;
$$;

grant execute on function public.add_event_with_packs(uuid, text, timestamptz, text[]) to authenticated;