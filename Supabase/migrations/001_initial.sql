-- Games Room v0.2 initial schema
-- Run via Supabase SQL Editor (recommended for first migration), or:
--   psql "$SUPABASE_DB_URL" -f Supabase/migrations/001_initial.sql

-- ponytail: two tables, RLS on both, one enum. Nothing else lands until a use-case proves it.

create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- Users table mirrors auth.users. Auto-populated on signup via trigger.
create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.users enable row level security;

create policy "users read own row" on public.users
  for select using (auth.uid() = id);

create policy "users insert own row" on public.users
  for insert with check (auth.uid() = id);

create policy "users update own row" on public.users
  for update using (auth.uid() = id);

-- ponytail: trigger inserts a users row on auth.users insert. display_name
-- defaults to email local-part if user_metadata doesn't carry one. v0.3+
-- can add profile photos, usernames, etc.
create or replace function public.handle_new_user()
returns trigger as $$
begin
  insert into public.users (id, display_name)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1))
  );
  return new;
end;
$$ language plpgsql security definer;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Mascot personality enum — locked from hub, 5 levels.
create type public.mascot_personality as enum (
  'professional', 'friendly', 'snarky', 'sarcastic', 'unhinged'
);

-- Rooms table. v0.2 only supports creator-owned rooms; join-code flow
-- (room_memberships, multi-user visibility) lands in v0.3.
create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  mascot_name text not null,
  mascot_personality public.mascot_personality not null default 'friendly',
  created_by uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index rooms_created_by_idx on public.rooms(created_by);

alter table public.rooms enable row level security;

create policy "creator can read own rooms" on public.rooms
  for select using (auth.uid() = created_by);

create policy "creator can insert own rooms" on public.rooms
  for insert with check (auth.uid() = created_by);

create policy "creator can update own rooms" on public.rooms
  for update using (auth.uid() = created_by);

create policy "creator can delete own rooms" on public.rooms
  for delete using (auth.uid() = created_by);

-- ponytail: shared updated_at trigger. Set on both tables that mutate.
create or replace function public.set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger users_set_updated_at
  before update on public.users
  for each row execute function public.set_updated_at();

create trigger rooms_set_updated_at
  before update on public.rooms
  for each row execute function public.set_updated_at();

-- ponytail: no seed data, no fake users, no demo rooms. Real data only.