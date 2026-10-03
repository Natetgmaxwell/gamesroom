-- Shadow-DB stub of the pre-097 schema: only the objects 097 reads/writes.
-- Used by scripts/validate-097.sh. Mirrors column names/types from
-- migrations 001, 004, 005, 014, 033, 052, 093, 095.
create role authenticated nologin;
create schema if not exists auth;
create table auth.users (id uuid primary key);

create table public.users (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.current_user_id()
returns uuid language sql stable security definer as $$
  select nullif(current_setting('request.jwt.claims', true)::json->>'sub', '')::uuid;
$$;

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references public.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.room_memberships (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  role text not null default 'member' check (role in ('host', 'member')),
  joined_at timestamptz not null default now(),
  membership_status text not null default 'active',
  preferences_conversation_prompt text check (
    preferences_conversation_prompt is null or char_length(preferences_conversation_prompt) <= 280
  ),
  unique (room_id, user_id)
);

create or replace function public.is_room_host(p_room_id uuid, p_user_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.room_memberships
    where room_id = p_room_id and user_id = p_user_id
      and role = 'host' and membership_status = 'active'
  );
$$;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  played_at timestamptz not null,
  created_by uuid references public.users(id) on delete set null,
  settled_at timestamptz
);

create type public.event_rsvp_state as enum ('unclaimed', 'claimed', 'declined');
create table public.event_rsvps (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  member_id uuid not null,
  state public.event_rsvp_state not null default 'unclaimed',
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, member_id)
);

create table public.transactions (
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

create publication supabase_realtime;

-- Supabase grants table privileges to authenticated by default; RLS gates rows.
alter default privileges in schema public grant select, insert, update, delete on tables to authenticated;
grant usage on schema public to authenticated;
