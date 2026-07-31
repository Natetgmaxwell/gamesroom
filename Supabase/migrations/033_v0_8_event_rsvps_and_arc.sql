-- ============================================================================
-- V0.8 — event_rsvps, chapter_lines, season_awards, events.settled_at,
--        sent_notifications
-- Games Room redesign v0.8 schema additions beyond V0.31.
--
-- Design notes:
--   * Every CREATE TYPE / CREATE TABLE / ALTER TABLE is wrapped in a
--     do-block that swallows `duplicate_object`, so the migration is
--     idempotent and safe to re-run.
--   * `ALTER TABLE … ADD COLUMN IF NOT EXISTS` is used defensively inside
--     the same do-block pattern for the events.settled_at add.
--   * Indexes use `CREATE INDEX IF NOT EXISTS` (already idempotent, no
--     do-block needed).
--   * RLS is enabled on every new table; policies follow the room-membership
--     pattern (member is part of room_memberships for the relevant room).
--   * sent_notifications is treated as an audit log — service-role only.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Enums (must exist before any table that references them)
-- ----------------------------------------------------------------------------

do $$ begin
  create type public.event_rsvp_state
    as enum ('claimed', 'declined', 'unclaimed');
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create type public.season_award_type
    as enum ('phoenix', 'veteran', 'whale', 'drowning');
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create type public.notification_cadence
    as enum ('on_create', 't_48h', 'morning_of');
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- ----------------------------------------------------------------------------
-- 2. events.settled_at — supports the .justSettled state machine slot
-- ----------------------------------------------------------------------------

do $$ begin
  alter table public.events
    add column if not exists settled_at timestamptz;
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- ----------------------------------------------------------------------------
-- 3. event_rsvps — mirrors the Swift MemberRSVP struct
--    (id, event_id, room_id, member_id, state, responded_at)
-- ----------------------------------------------------------------------------

do $$ begin
  create table public.event_rsvps (
    id            uuid                        primary key default gen_random_uuid(),
    event_id      uuid                        not null references public.events(id) on delete cascade,
    room_id       uuid                        not null references public.rooms(id)  on delete cascade,
    member_id     uuid                        not null,
    state         public.event_rsvp_state     not null default 'unclaimed',
    responded_at  timestamptz,
    created_at    timestamptz                 not null default now(),
    unique (event_id, member_id)
  );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

create index if not exists idx_event_rsvps_event_id  on public.event_rsvps(event_id);
create index if not exists idx_event_rsvps_room_id   on public.event_rsvps(room_id);
create index if not exists idx_event_rsvps_member_id on public.event_rsvps(member_id);
create index if not exists idx_event_rsvps_state     on public.event_rsvps(state);

alter table public.event_rsvps enable row level security;

do $$ begin
  create policy "event_rsvps_select_room_members"
    on public.event_rsvps
    for select
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = event_rsvps.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "event_rsvps_insert_self"
    on public.event_rsvps
    for insert
    with check (member_id = auth.uid());
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "event_rsvps_update_self"
    on public.event_rsvps
    for update
    using       (member_id = auth.uid())
    with check  (member_id = auth.uid());
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "event_rsvps_delete_self"
    on public.event_rsvps
    for delete
    using (member_id = auth.uid());
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- ----------------------------------------------------------------------------
-- 4. chapter_lines — one narrative beat per event
--    (id, event_id, room_id, title, call_forward, created_at)
-- ----------------------------------------------------------------------------

do $$ begin
  create table public.chapter_lines (
    id           uuid         primary key default gen_random_uuid(),
    event_id     uuid         not null references public.events(id) on delete cascade,
    room_id      uuid         not null references public.rooms(id)  on delete cascade,
    title        text         not null,
    call_forward text,
    created_at   timestamptz  not null default now(),
    unique (event_id)
  );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

create index if not exists idx_chapter_lines_event_id on public.chapter_lines(event_id);
create index if not exists idx_chapter_lines_room_id  on public.chapter_lines(room_id);

alter table public.chapter_lines enable row level security;

do $$ begin
  create policy "chapter_lines_select_room_members"
    on public.chapter_lines
    for select
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = chapter_lines.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "chapter_lines_insert_room_members"
    on public.chapter_lines
    for insert
    with check (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = chapter_lines.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "chapter_lines_update_room_members"
    on public.chapter_lines
    for update
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = chapter_lines.room_id
          and rm.user_id = auth.uid()
      )
    )
    with check (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = chapter_lines.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "chapter_lines_delete_room_members"
    on public.chapter_lines
    for delete
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = chapter_lines.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- ----------------------------------------------------------------------------
-- 5. season_awards — end-of-season honours per room
--    (id, room_id, season_id, member_id, award_type, is_private, created_at)
-- ----------------------------------------------------------------------------

do $$ begin
  create table public.season_awards (
    id          uuid                     primary key default gen_random_uuid(),
    room_id     uuid                     not null references public.rooms(id) on delete cascade,
    season_id   uuid                     not null,
    member_id   uuid                     not null,
    award_type  public.season_award_type not null,
    is_private  boolean                  not null default false,
    created_at  timestamptz              not null default now()
  );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

create index if not exists idx_season_awards_room_id    on public.season_awards(room_id);
create index if not exists idx_season_awards_season_id  on public.season_awards(season_id);
create index if not exists idx_season_awards_member_id  on public.season_awards(member_id);
create index if not exists idx_season_awards_award_type on public.season_awards(award_type);

alter table public.season_awards enable row level security;

-- Public awards in rooms the caller belongs to.
do $$ begin
  create policy "season_awards_select_public_in_own_rooms"
    on public.season_awards
    for select
    using (
      is_private = false
      and exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = season_awards.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- Private awards are only visible to the recipient themselves.
do $$ begin
  create policy "season_awards_select_private_self"
    on public.season_awards
    for select
    using (is_private = true and member_id = auth.uid());
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- Any room member can award (host-side moderation lives at the app layer).
do $$ begin
  create policy "season_awards_insert_room_members"
    on public.season_awards
    for insert
    with check (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = season_awards.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "season_awards_update_room_members"
    on public.season_awards
    for update
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = season_awards.room_id
          and rm.user_id = auth.uid()
      )
    )
    with check (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = season_awards.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "season_awards_delete_room_members"
    on public.season_awards
    for delete
    using (
      exists (
        select 1
        from public.room_memberships rm
        where rm.room_id   = season_awards.room_id
          and rm.user_id = auth.uid()
      )
    );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

-- ----------------------------------------------------------------------------
-- 6. sent_notifications — audit log of outbound notification cadence hits
--    (id, event_id, member_id, cadence, sent_at)
--    Restrictive: writes go through service_role via edge functions / cron,
--    reads are also service-role so any audit query requires elevated access.
-- ----------------------------------------------------------------------------

do $$ begin
  create table public.sent_notifications (
    id         uuid                        primary key default gen_random_uuid(),
    event_id   uuid                        not null references public.events(id) on delete cascade,
    member_id  uuid                        not null,
    cadence    public.notification_cadence not null,
    sent_at    timestamptz                 not null default now(),
    unique (event_id, member_id, cadence)
  );
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

create index if not exists idx_sent_notifications_event_id  on public.sent_notifications(event_id);
create index if not exists idx_sent_notifications_member_id on public.sent_notifications(member_id);
create index if not exists idx_sent_notifications_cadence   on public.sent_notifications(cadence);
create index if not exists idx_sent_notifications_sent_at   on public.sent_notifications(sent_at);

alter table public.sent_notifications enable row level security;

do $$ begin
  create policy "sent_notifications_service_role_select"
    on public.sent_notifications
    for select
    to service_role
    using (true);
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "sent_notifications_service_role_insert"
    on public.sent_notifications
    for insert
    to service_role
    with check (true);
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "sent_notifications_service_role_update"
    on public.sent_notifications
    for update
    to service_role
    using (true)
    with check (true);
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;

do $$ begin
  create policy "sent_notifications_service_role_delete"
    on public.sent_notifications
    for delete
    to service_role
    using (true);
exception when duplicate_object OR duplicate_table OR duplicate_function then null; end $$;