-- v0.7 backfill: create the missing tables from the v0.5 spec that
-- were never applied. Required before 012_seats_and_settings.sql can run.

-- 1. events: a single instance of a game night or session in a room.
create table public.events (
  id uuid default gen_random_uuid() primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  name text not null,
  played_at timestamptz not null,
  created_by uuid not null references public.users(id) on delete set null,
  created_at timestamptz default now() not null
);

create index events_room_id_idx on public.events using btree (room_id);
create index events_played_at_idx on public.events using btree (played_at desc);

-- 2. scores: a single result within an event.
create table public.scores (
  id uuid default gen_random_uuid() primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  room_id uuid not null references public.rooms(id) on delete cascade,
  score int not null,
  created_at timestamptz default now() not null,
  unique (event_id, user_id)
);

create index scores_event_id_idx on public.scores using btree (event_id);
create index scores_user_id_idx on public.scores using btree (user_id);
create index scores_room_id_idx on public.scores using btree (room_id);

-- 3. season_summaries: aggregated scores per user per room per season.
create table public.season_summaries (
  id uuid default gen_random_uuid() primary key,
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.users(id) on delete cascade,
  season text not null,
  total_score int not null default 0,
  events_played int not null default 0,
  updated_at timestamptz default now() not null,
  unique (room_id, user_id, season)
);

create index season_summaries_room_id_idx on public.season_summaries using btree (room_id);
create index season_summaries_user_id_idx on public.season_summaries using btree (user_id);

-- 4. RLS for events.
alter table public.events enable row level security;

create policy "members can read events" on public.events
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = events.room_id and user_id = public.current_user_id())
  );

create policy "host can insert events" on public.events
  for insert with check (
    exists (select 1 from public.rooms
            where id = events.room_id and created_by = public.current_user_id())
  );

create policy "host can update events" on public.events
  for update using (
    exists (select 1 from public.rooms
            where id = events.room_id and created_by = public.current_user_id())
  );

create policy "host can delete events" on public.events
  for delete using (
    exists (select 1 from public.rooms
            where id = events.room_id and created_by = public.current_user_id())
  );

-- 5. RLS for scores.
alter table public.scores enable row level security;

create policy "members can read scores" on public.scores
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = scores.room_id and user_id = public.current_user_id())
  );

create policy "host can insert scores" on public.scores
  for insert with check (
    exists (select 1 from public.rooms
            where id = scores.room_id and created_by = public.current_user_id())
  );

-- 6. RLS for season_summaries.
alter table public.season_summaries enable row level security;

create policy "members can read season summaries" on public.season_summaries
  for select using (
    exists (select 1 from public.room_memberships
            where room_id = season_summaries.room_id and user_id = public.current_user_id())
  );
