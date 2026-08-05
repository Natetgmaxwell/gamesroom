-- 039: Seasons + season awards schema.
--
-- Tracks M1.1. Closes the gap between the V0.8 brief's
-- `.seasonClose` slot and the existing code (Season + SeasonAward
-- + SeasonStatus models are all present in /GamesRoom/Models/ but
-- had no backing tables in 001-038).
--
-- Privacy boundary (per vision §6.1 Q6 and plan §5 Q-DROWNING):
-- the `drowning` award row must be readable only by the recipient.
-- RLS encodes this so V0.9 awards-card UI doesn't need a
-- separate privacy layer; the query that backs the awards card
-- just joins on `auth.uid()` for the drowning filter.

-- =================================================================
-- seasons: one row per room-season arc. Each room has at most one
-- `active` season at a time; closing it opens a new one.
-- =================================================================
create table if not exists public.seasons (
    id uuid primary key default gen_random_uuid(),
    room_id uuid not null references public.rooms(id) on delete cascade,
    ordinal int not null,
    subtitle text not null default '',
    status text not null default 'active' check (status in ('active', 'ended')),
    started_at timestamptz not null default now(),
    ended_at timestamptz,
    unique (room_id, ordinal)
);
create index if not exists seasons_room_id_idx on public.seasons using btree (room_id);
create index if not exists seasons_room_status_idx on public.seasons using btree (room_id, status);

alter table public.seasons enable row level security;

-- Members of the room can read seasons for that room. Hosts and
-- members have the same read scope per V0.8 brief — season
-- metadata is the room's shared knowledge.
create policy "members can read seasons"
    on public.seasons for select
    using (
        exists (
            select 1 from public.room_memberships rm
            where rm.room_id = seasons.room_id
              and rm.user_id = public.current_user_id()
        )
    );

-- Only the host can write seasons (open / close / rename).
create policy "host can write seasons"
    on public.seasons for all
    using (
        exists (
            select 1 from public.rooms r
            where r.id = seasons.room_id
              and r.created_by = public.current_user_id()
        )
    )
    with check (
        exists (
            select 1 from public.rooms r
            where r.id = seasons.room_id
              and r.created_by = public.current_user_id()
        )
    );

-- =================================================================
-- season_awards: one row per recipient per season per award type.
-- =================================================================
create table if not exists public.season_awards (
    id uuid primary key default gen_random_uuid(),
    season_id uuid not null references public.seasons(id) on delete cascade,
    room_id uuid not null references public.rooms(id) on delete cascade,
    recipient_user_id uuid not null references public.users(id) on delete cascade,
    recipient_display_name text not null default 'Member',
    award_type text not null check (award_type in ('phoenix', 'veteran', 'whale', 'drowning')),
    caption text,
    acknowledged boolean not null default false,
    awarded_at timestamptz not null default now(),
    unique (season_id, recipient_user_id, award_type)
);
create index if not exists season_awards_season_idx on public.season_awards using btree (season_id);
create index if not exists season_awards_recipient_idx on public.season_awards using btree (recipient_user_id);
create index if not exists season_awards_room_idx on public.season_awards using btree (room_id);

alter table public.season_awards enable row level security;

-- Public-to-room reads: non-drowning rows are visible to any
-- room member. Drowning rows are readable only by the recipient
-- themselves (Q-DROWNING privacy boundary).
create policy "members can read non-drowning awards"
    on public.season_awards for select
    using (
        award_type <> 'drowning'
        and exists (
            select 1 from public.room_memberships rm
            where rm.room_id = season_awards.room_id
              and rm.user_id = public.current_user_id()
        )
    );

create policy "recipients can read their drowning awards"
    on public.season_awards for select
    using (
        award_type = 'drowning'
        and recipient_user_id = public.current_user_id()
    );

-- Host writes for the room's awards.
create policy "host can write awards"
    on public.season_awards for all
    using (
        exists (
            select 1 from public.rooms r
            where r.id = season_awards.room_id
              and r.created_by = public.current_user_id()
        )
    )
    with check (
        exists (
            select 1 from public.rooms r
            where r.id = season_awards.room_id
              and r.created_by = public.current_user_id()
        )
    );