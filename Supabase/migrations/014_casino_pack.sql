-- 014: Casino pack — tables + RPCs.
-- Apply via:
--   PGPASSWORD='...' psql "host=aws-0-ap-southeast-1.pooler.supabase.com port=6543 user=postgres.bnrgkdcluopicqdpmrtu dbname=postgres sslmode=require" -v ON_ERROR_STOP=1 -f Supabase/migrations/014_casino_pack.sql

-- 1. casino_room_config: per-room casino settings.
create table if not exists public.casino_room_config (
  room_id uuid primary key references public.rooms(id) on delete cascade,
  enabled boolean not null default false,
  chip_color_map jsonb not null default '{}'::jsonb,
  standard_presets boolean not null default true,
  updated_at timestamptz default now() not null
);

alter table public.casino_room_config enable row level security;

create policy "members can read casino config" on public.casino_room_config
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = casino_room_config.room_id and user_id = public.current_user_id())
  );

create policy "host can update casino config" on public.casino_room_config
  for all using (
    exists (select 1 from public.rooms
            where id = casino_room_config.room_id and created_by = public.current_user_id())
  );

-- 2. transactions: generic ledger, used by casino and future packs.
create table if not exists public.transactions (
  id uuid default gen_random_uuid() primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  session_id uuid,
  member_id uuid not null references public.users(id) on delete cascade,
  kind text not null,
  amount_points bigint not null,
  meta jsonb default '{}'::jsonb,
  created_at timestamptz default now() not null,
  created_by uuid references public.users(id) on delete set null
);

create index transactions_room_id_idx on public.transactions using btree (room_id);
create index transactions_member_id_idx on public.transactions using btree (member_id);

alter table public.transactions enable row level security;

create policy "members can read transactions" on public.transactions
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = transactions.room_id and user_id = public.current_user_id())
  );

create policy "host can insert transactions" on public.transactions
  for insert with check (
    exists (select 1 from public.rooms
            where id = transactions.room_id and created_by = public.current_user_id())
  );

-- 3. casino_withdrawals: tracks point → chip brackets.
create table if not exists public.casino_withdrawals (
  id uuid default gen_random_uuid() primary key,
  session_id uuid,
  member_id uuid not null references public.users(id) on delete cascade,
  points_withdrawn bigint not null,
  withdrawn_at timestamptz default now() not null,
  withdrawn_by uuid not null references public.users(id) on delete set null
);

create index casino_withdrawals_member_idx on public.casino_withdrawals using btree (member_id);

alter table public.casino_withdrawals enable row level security;

create policy "members can read own withdrawals" on public.casino_withdrawals
  for select using (
    member_id = public.current_user_id()
    or exists (select 1 from public.rooms r
               join public.room_memberships rm on rm.room_id = r.id
               where rm.user_id = public.current_user_id())
  );

create policy "host can insert withdrawals" on public.casino_withdrawals
  for insert with check (
    withdrawn_by = public.current_user_id()
  );

-- 4. RPC: withdraw_casino_chips. Withdraw points from a member's balance.
create or replace function public.withdraw_casino_chips(
  p_session_id uuid,
  p_member_id uuid,
  p_points int
)
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

  insert into public.casino_withdrawals (session_id, member_id, points_withdrawn, withdrawn_by)
  values (p_session_id, p_member_id, p_points, v_caller);

  return true;
end;
$$;

grant execute on function public.withdraw_casino_chips(uuid, uuid, int) to authenticated;

-- 5. RPC: settle_casino_session. Write settlement rows + update balances atomically.
create or replace function public.settle_casino_session(
  p_session_id uuid,
  p_settlements jsonb  -- [{member_id, amount_points, vision_snapshot}, ...]
)
returns boolean
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_item jsonb;
  v_member_id uuid;
  v_amount int;
  v_snapshot jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Find room from a withdrawal in this session
  select cw.member_id into v_member_id
  from public.casino_withdrawals cw
  where cw.session_id = p_session_id
  limit 1;

  -- Resolve room from the caller's rooms
  select r.id into v_room_id
  from public.rooms r
  where r.created_by = v_caller
  limit 1;

  if v_room_id is null then
    raise exception 'Room not found for host' using errcode = 'P0002';
  end if;

  -- Write one transaction row per member
  for v_item in select * from jsonb_array_elements(p_settlements)
  loop
    v_member_id := (v_item->>'member_id')::uuid;
    v_amount := (v_item->>'amount_points')::int;
    v_snapshot := v_item->>'vision_snapshot';

    insert into public.transactions (room_id, session_id, member_id, kind, amount_points, meta, created_by)
    values (v_room_id, p_session_id, v_member_id, 'casino_settlement', v_amount,
            jsonb_build_object('vision_snapshot', v_snapshot), v_caller);
  end loop;

  return true;
end;
$$;

grant execute on function public.settle_casino_session(uuid, jsonb) to authenticated;

-- 6. RPC: get_casino_config. Get casino config for a room.
create or replace function public.get_casino_config(p_room_id uuid)
returns table (
  room_id uuid,
  enabled boolean,
  chip_color_map jsonb,
  standard_presets boolean
)
language sql
security definer
stable
as $$
  select crc.room_id, crc.enabled, crc.chip_color_map, crc.standard_presets
  from public.casino_room_config crc
  where crc.room_id = p_room_id;
$$;

grant execute on function public.get_casino_config(uuid) to authenticated;

-- 7. RPC: upsert_casino_config. Create or update casino config for a room.
create or replace function public.upsert_casino_config(
  p_room_id uuid,
  p_enabled boolean,
  p_chip_color_map jsonb default '{}'::jsonb,
  p_standard_presets boolean default true
)
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
    raise exception 'Only the host can configure casino' using errcode = '42501';
  end if;

  insert into public.casino_room_config (room_id, enabled, chip_color_map, standard_presets)
  values (p_room_id, p_enabled, p_chip_color_map, p_standard_presets)
  on conflict (room_id) do update
    set enabled = excluded.enabled,
        chip_color_map = excluded.chip_color_map,
        standard_presets = excluded.standard_presets,
        updated_at = now();

  return true;
end;
$$;

grant execute on function public.upsert_casino_config(uuid, boolean, jsonb, boolean) to authenticated;

-- 8. RPC: get_casino_withdrawals. Get withdrawals for a session.
create or replace function public.get_casino_withdrawals(p_session_id uuid)
returns table (
  id uuid,
  session_id uuid,
  member_id uuid,
  points_withdrawn int,
  withdrawn_at timestamptz,
  withdrawn_by uuid
)
language sql
security definer
stable
as $$
  select cw.id, cw.session_id, cw.member_id, cw.points_withdrawn, cw.withdrawn_at, cw.withdrawn_by
  from public.casino_withdrawals cw
  where cw.session_id = p_session_id
  order by cw.withdrawn_at;
$$;

grant execute on function public.get_casino_withdrawals(uuid) to authenticated;
