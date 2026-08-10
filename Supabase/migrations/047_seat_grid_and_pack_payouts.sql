-- 047: Seat-grid RSVP read + per-room pack payout configs.
--
-- Two additions from the 2026-08-10 product-owner feedback round:
--
--   1. get_event_rsvps(p_event_id) — one row per room member with
--      their RSVP state (claimed / declined / unclaimed) joined to
--      the member's display name. Powers the briefing slot's seat
--      grid: which chairs are claimed, by whom, and which are open.
--      The seat grid is the "chairs coloured in" visual indicator
--      the owner asked for when claiming a seat.
--
--   2. room_pack_configs — per-room payout overrides for the
--      single-winner packs. The pack's static win_points is the
--      global default; a row here overrides it for one room. The
--      owner's ask: "you should be able to click on each pack to
--      change how much winning each game pays out" (CAH scores per
--      card, Monopoly Deal winner-takes-all). Host-only writes via
--      set_room_pack_config; members read via get_room_pack_configs.
--
-- Apply via:
--   supabase db execute --file Supabase/migrations/047_seat_grid_and_pack_payouts.sql

-- =================================================================
-- 1. get_event_rsvps — per-member RSVP read for the seat grid
-- =================================================================
create or replace function public.get_event_rsvps(p_event_id uuid)
returns table (
  event_id uuid,
  member_id uuid,
  display_name text,
  state text
)
language plpgsql
security definer
as $$
declare
  v_room_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Caller must be a member of the event's room.
  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = auth.uid()
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  return query
    select
      p_event_id::uuid as event_id,
      rm.user_id as member_id,
      u.display_name as display_name,
      coalesce(er.state::text, 'unclaimed') as state
    from public.room_memberships rm
    join public.users u on u.id = rm.user_id
    left join public.event_rsvps er
      on er.event_id = p_event_id and er.member_id = rm.user_id
    where rm.room_id = v_room_id
    order by case when rm.role = 'host' then 0 else 1 end, u.display_name;
end;
$$;

grant execute on function public.get_event_rsvps(uuid) to authenticated;

-- =================================================================
-- 2. room_pack_configs — per-room payout overrides
-- =================================================================
create table if not exists public.room_pack_configs (
  room_id    uuid        not null references public.rooms(id) on delete cascade,
  pack_slug  text        not null,
  win_points integer     not null default 1 check (win_points >= 0),
  updated_at timestamptz not null default now(),
  primary key (room_id, pack_slug)
);

create index if not exists room_pack_configs_room_idx
  on public.room_pack_configs using btree (room_id);

alter table public.room_pack_configs enable row level security;

-- Members of the room can read payout configs (the shelf shows the
-- configured payout to everyone).
create policy "members can read room pack configs"
  on public.room_pack_configs for select
  using (
    exists (
      select 1 from public.room_memberships rm
      where rm.room_id = room_pack_configs.room_id
        and rm.user_id = public.current_user_id()
    )
  );

-- Only the host can write payout configs.
create policy "host can write room pack configs"
  on public.room_pack_configs for all
  using (
    exists (
      select 1 from public.rooms r
      where r.id = room_pack_configs.room_id
        and r.created_by = public.current_user_id()
    )
  )
  with check (
    exists (
      select 1 from public.rooms r
      where r.id = room_pack_configs.room_id
        and r.created_by = public.current_user_id()
    )
  );

-- Host-only upsert of one pack's payout. Validates the pack slug
-- against public.packs and bounds win_points >= 0.
create or replace function public.set_room_pack_config(
  p_room_id uuid,
  p_pack_slug text,
  p_win_points integer
)
returns table (room_id uuid, pack_slug text, win_points integer)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can configure pack payouts' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.packs where slug = p_pack_slug
  ) then
    raise exception 'Unknown pack: %', p_pack_slug using errcode = 'P0002';
  end if;

  if p_win_points < 0 then
    raise exception 'win_points must be >= 0' using errcode = '22000';
  end if;

  insert into public.room_pack_configs (room_id, pack_slug, win_points)
  values (p_room_id, p_pack_slug, p_win_points)
  on conflict (room_id, pack_slug) do update set
    win_points = excluded.win_points,
    updated_at = now();

  return query
    select rpc.room_id, rpc.pack_slug, rpc.win_points
    from public.room_pack_configs rpc
    where rpc.room_id = p_room_id and rpc.pack_slug = p_pack_slug;
end;
$$;

grant execute on function public.set_room_pack_config(uuid, text, integer) to authenticated;

-- Member read of all payout configs for a room.
create or replace function public.get_room_pack_configs(p_room_id uuid)
returns table (room_id uuid, pack_slug text, win_points integer)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = p_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  return query
    select rpc.room_id, rpc.pack_slug, rpc.win_points
    from public.room_pack_configs rpc
    where rpc.room_id = p_room_id
    order by rpc.pack_slug;
end;
$$;

grant execute on function public.get_room_pack_configs(uuid) to authenticated;
