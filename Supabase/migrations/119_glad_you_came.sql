-- 119: "Glad you came" (1.2.5 Task 4).
--
-- After a settled night, anyone who held a seat can tell any of the people
-- they sat with that they were glad to see them. Each recipient hears it
-- once, batched, the next morning: "Connor and Sam were glad you came."
--
-- Why: the liking gap (Boothby, Cooney, Clark & Clark 2018) and the
-- undervalued thanks (Kumar & Epley 2018; Zhao & Epley 2021). People leave
-- a night thinking the others liked them less than they did, and they send
-- too few thanks. This closes the gap privately, one person at a time.
--
-- Privacy, the rules that make or break the feature
--   * Nothing here counts, ranks or totals anything for anyone. There is no
--     aggregate RPC, no view, no profile number, no season tally.
--   * A row is readable only by its sender and its one recipient (RLS).
--     Nobody can see who did NOT get one. The host has no special view.
--   * The per-recipient grouping for the push happens server-side, inside
--     functions the app roles cannot execute, and in the glad-push edge
--     function on the service role.
--   * pg_stats hides RLS tables from roles RLS applies to (PG >= 9.5), and
--     the user columns collect no most-common-values statistics anyway
--     (statistics target 0), so the planner cannot leak a distribution.
--
-- What this migration adds
--   1. public.glad_you_came(event_id, from_user, to_user, created_at),
--      unique (event_id, from_user, to_user), check from_user <> to_user.
--   2. public.glad_can_send(event, from, to): the send gate. True only when
--      the caller IS from, from <> to, the night is in its recap window
--      (public.night_phase = 'recap', the twin of NightPhaseResolver), and
--      both held a claimed seat that night as active members of the room.
--   3. RLS: insert only through glad_can_send; select only rows you sent or
--      rows addressed to you. No update, no delete. Column-level insert
--      grant, so created_at is the server's clock.
--   4. public.glad_push_queue(event_id, to_user, ...): one push per
--      recipient per night. Service role only; RLS on, no policies.
--   5. public.glad_push_deliver_at(settled_at, time_zone): the delivery
--      hour. Twin of GladPushTime.deliverAt (GamesRoom/Models/
--      GladYouCame.swift), pinned by TestsGladYouCame.swift and the probes.
--   6. A trigger on glad_you_came that queues the recipient once.
--   7. public.glad_push_due(now) and public.glad_push_cron_tick(): post the
--      due recipients to the glad-push edge function over pg_net.
--   8. The cron schedule, COMMENTED OUT. TARS deploys glad-push, sets the
--      vault secret 'glad_push_secret', then schedules it.
--
-- The delivery hour (room's zone, rooms.time_zone from 108)
--   settled before 09:00            -> 09:00 that morning
--   settled 09:00 to before 22:00   -> the next whole hour, unless that is
--                                      22:00, then 09:00 next morning
--   settled 22:00 or later          -> 09:00 next morning
--   Never 22:00 to 08:00. The tick re-checks the room's clock before it
--   posts, and the edge function checks it again before it sends.
--
-- Notes that arrive after a recipient's push has gone out still show on
-- the recipient's recap; they do not send a second push (one per night).
--
-- NOT applied to live. TARS applies it:
--   supabase db query --linked -f Supabase/migrations/119_glad_you_came.sql
-- Probes: Supabase/tests/119_probes.sql (schema-only replica).
--
-- Idempotent: if-not-exists, create-or-replace, drop-policy/trigger-if-exists.
-- Rollback: drop trigger glad_you_came_queue_push on public.glad_you_came;
-- drop function public.glad_you_came_queue_push(); drop function
-- public.glad_push_cron_tick(); drop function public.glad_push_due(timestamptz);
-- drop function public.glad_push_post(uuid, uuid); drop function
-- public.glad_push_secret(); drop function public.glad_push_deliver_at(timestamptz, text);
-- drop table public.glad_push_queue; drop function public.glad_can_send(uuid, uuid, uuid);
-- drop table public.glad_you_came; and unschedule 'glad-push-tick' if TARS scheduled it.
begin;

-- =================================================================
-- 1. The notes
-- =================================================================
create table if not exists public.glad_you_came (
  event_id   uuid        not null references public.events(id) on delete cascade,
  from_user  uuid        not null references auth.users(id) on delete cascade,
  to_user    uuid        not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint glad_you_came_once unique (event_id, from_user, to_user),
  constraint glad_you_came_not_self check (from_user <> to_user)
);

comment on table public.glad_you_came is
  '1.2.5 Task 4: "Glad you came". One row per (night, sender, recipient). Readable only by the sender and the one recipient. Never counted, ranked or totalled anywhere: there is no aggregate RPC on purpose.';

-- The recipient's read (and the push grouping) is by recipient.
create index if not exists idx_glad_you_came_to_user
  on public.glad_you_came (to_user, event_id);

-- No most-common-values for the user columns: the distribution of who
-- receives the most is exactly the number this feature must never have.
alter table public.glad_you_came alter column to_user set statistics 0;
alter table public.glad_you_came alter column from_user set statistics 0;

alter table public.glad_you_came enable row level security;
alter table public.glad_you_came force row level security;

-- =================================================================
-- 2. The send gate
-- =================================================================
-- SECURITY DEFINER so it can read event_rsvps and room_memberships whatever
-- their own policies say, and so the policy never recurses. It answers only
-- for the caller's own sends (p_from must be the caller), so it is not an
-- oracle for anyone else's seats.
create or replace function public.glad_can_send(
  p_event_id uuid,
  p_from     uuid,
  p_to       uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_from is not null
     and p_to is not null
     and p_from = auth.uid()
     and p_from <> p_to
     and exists (
       select 1
       from public.events e
       join public.rooms r on r.id = e.room_id
       where e.id = p_event_id
         and r.deleted_at is null
         and public.night_phase(e.played_at, e.settled_at, r.auto_close_hours, now()) = 'recap'
         -- both held a seat that night ...
         and exists (
           select 1 from public.event_rsvps s
           where s.event_id = e.id and s.member_id = p_from and s.state = 'claimed'
         )
         and exists (
           select 1 from public.event_rsvps s
           where s.event_id = e.id and s.member_id = p_to and s.state = 'claimed'
         )
         -- ... and both are still active members of the room.
         and exists (
           select 1 from public.room_memberships m
           where m.room_id = e.room_id and m.user_id = p_from and m.membership_status = 'active'
         )
         and exists (
           select 1 from public.room_memberships m
           where m.room_id = e.room_id and m.user_id = p_to and m.membership_status = 'active'
         )
     );
$$;

revoke all on function public.glad_can_send(uuid, uuid, uuid) from public, anon;
grant execute on function public.glad_can_send(uuid, uuid, uuid) to authenticated, service_role;

comment on function public.glad_can_send(uuid, uuid, uuid) is
  '1.2.5 Task 4: the glad_you_came insert gate. True only for the caller''s own send, to someone else, on a night in its recap window (night_phase = recap), where both held a claimed seat and are active members. Answers false for any p_from that is not the caller.';

-- =================================================================
-- 3. RLS and grants
-- =================================================================
drop policy if exists glad_you_came_insert_seated on public.glad_you_came;
create policy glad_you_came_insert_seated on public.glad_you_came
  for insert to authenticated
  with check (
    from_user = (select auth.uid())
    and public.glad_can_send(event_id, from_user, to_user)
  );

drop policy if exists glad_you_came_select_own on public.glad_you_came;
create policy glad_you_came_select_own on public.glad_you_came
  for select to authenticated
  using (
    from_user = (select auth.uid())
    or to_user = (select auth.uid())
  );

-- No update or delete policy, and no grant either: a note, once sent, is
-- the sender's and the recipient's. Undo happens on the phone before send.
revoke all on table public.glad_you_came from public, anon, authenticated;
grant select on table public.glad_you_came to authenticated;
grant insert (event_id, from_user, to_user) on table public.glad_you_came to authenticated;
grant all on table public.glad_you_came to service_role;

-- =================================================================
-- 4. One push per recipient per night
-- =================================================================
create table if not exists public.glad_push_queue (
  event_id    uuid        not null references public.events(id) on delete cascade,
  to_user     uuid        not null references auth.users(id) on delete cascade,
  room_id     uuid        not null,
  deliver_at  timestamptz not null,
  push_status text        not null default 'queued',
  created_at  timestamptz not null default now(),
  primary key (event_id, to_user)
);

comment on table public.glad_push_queue is
  '1.2.5 Task 4: the glad-push ledger. One row per (night, recipient); the key is the one-push-per-night rule. push_status: queued -> sending -> sent / failed / no_device / skipped_muted / expired. Service role only.';

create index if not exists idx_glad_push_queue_due
  on public.glad_push_queue (deliver_at) where push_status = 'queued';

alter table public.glad_push_queue enable row level security;
revoke all on table public.glad_push_queue from public, anon, authenticated;
grant all on table public.glad_push_queue to service_role;

-- =================================================================
-- 5. The delivery hour (twin of GladPushTime.deliverAt)
-- =================================================================
create or replace function public.glad_push_deliver_at(
  p_settled_at timestamptz,
  p_time_zone  text
)
returns timestamptz
language plpgsql
immutable
set search_path = public
as $$
declare
  v_tz    text := coalesce(nullif(p_time_zone, ''), 'UTC');
  v_local timestamp;
  v_day   date;
  v_next  timestamp;
begin
  if p_settled_at is null then
    return null;
  end if;
  v_local := p_settled_at at time zone v_tz;
  v_day   := v_local::date;

  -- Before 09:00: that morning at 09:00.
  if v_local::time < time '09:00' then
    return (v_day + time '09:00') at time zone v_tz;
  end if;

  -- 09:00 to before 22:00: the next whole hour, if that is before 22:00.
  v_next := date_trunc('hour', v_local) + interval '1 hour';
  if v_next < v_day + time '22:00' then
    return v_next at time zone v_tz;
  end if;

  -- Otherwise the next morning at 09:00. Never 22:00 to 08:00.
  return ((v_day + 1) + time '09:00') at time zone v_tz;
end;
$$;

revoke all on function public.glad_push_deliver_at(timestamptz, text) from public, anon;
grant execute on function public.glad_push_deliver_at(timestamptz, text) to authenticated, service_role;

comment on function public.glad_push_deliver_at(timestamptz, text) is
  '1.2.5 Task 4: when a recipient''s batched "glad you came" push goes out, in the room''s zone. Before 09:00 -> 09:00; 09:00-21:59 -> next whole hour unless that is 22:00; otherwise 09:00 next day. Twin of GladPushTime.deliverAt (TestsGladYouCame.swift). Pure; carries no user data.';

-- =================================================================
-- 6. Queue the recipient on the first note
-- =================================================================
create or replace function public.glad_you_came_queue_push()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.glad_push_queue (event_id, to_user, room_id, deliver_at)
  select new.event_id, new.to_user, e.room_id,
         public.glad_push_deliver_at(e.settled_at, r.time_zone)
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = new.event_id
    and e.settled_at is not null
  on conflict (event_id, to_user) do nothing;
  return new;
end;
$$;

revoke all on function public.glad_you_came_queue_push() from public, anon, authenticated;

drop trigger if exists glad_you_came_queue_push on public.glad_you_came;
create trigger glad_you_came_queue_push
  after insert on public.glad_you_came
  for each row execute function public.glad_you_came_queue_push();

-- =================================================================
-- 7. The sender: secret, post, due, tick
-- =================================================================
create or replace function public.glad_push_secret()
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
    into v_secret using 'glad_push_secret';
  return v_secret;
end;
$$;

revoke all on function public.glad_push_secret() from public, anon, authenticated;

create or replace function public.glad_push_post(
  p_event_id uuid,
  p_to_user  uuid
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_url    text := 'https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/glad-push';
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return false;
  end if;
  v_secret := public.glad_push_secret();
  if v_secret is null or v_secret = '' then
    return false;
  end if;
  -- Ids only. The function re-reads the ledger row and the notes.
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
    using v_url,
          jsonb_build_object('Content-Type', 'application/json', 'X-Glad-Push-Secret', v_secret),
          jsonb_build_object('event_id', p_event_id, 'to_user', p_to_user);
  return true;
end;
$$;

revoke all on function public.glad_push_post(uuid, uuid) from public, anon, authenticated;

-- The recipients whose push is due. Service role and cron only: a list of
-- who has a note queued is exactly what an app user must never read.
create or replace function public.glad_push_due(p_now timestamptz default now())
returns table (event_id uuid, to_user uuid)
language sql
stable
security definer
set search_path = public
as $$
  -- language sql: every column is qualified, so the OUT names
  -- (event_id, to_user) cannot shadow them (the 116 bug is plpgsql-only).
  select q.event_id, q.to_user
  from public.glad_push_queue q
  join public.rooms r on r.id = q.room_id
  where q.push_status = 'queued'
    and r.deleted_at is null
    and q.deliver_at <= p_now
    and (p_now at time zone r.time_zone)::time >= time '08:00'
    and (p_now at time zone r.time_zone)::time <  time '22:00'
  order by q.deliver_at
  limit 200;
$$;

revoke all on function public.glad_push_due(timestamptz) from public, anon, authenticated;
grant execute on function public.glad_push_due(timestamptz) to service_role;

create or replace function public.glad_push_cron_tick()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_secret text;
  v_row    record;
  v_n      integer := 0;
begin
  -- A push that could not go out within a day of its hour is stale.
  update public.glad_push_queue q
     set push_status = 'expired'
   where q.push_status = 'queued'
     and q.deliver_at + interval '24 hours' <= now();

  -- Recipients who have left the room or turned the room's pushes off.
  update public.glad_push_queue q
     set push_status = 'skipped_muted'
   where q.push_status = 'queued'
     and q.deliver_at <= now()
     and not exists (
       select 1 from public.room_memberships m
       where m.room_id = q.room_id
         and m.user_id = q.to_user
         and m.membership_status = 'active'
         and coalesce(m.notifications_enabled, false)
     );

  -- Fail closed: no pg_net or no secret, nothing posted, rows stay queued.
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 0;
  end if;
  v_secret := public.glad_push_secret();
  if v_secret is null or v_secret = '' then
    return 0;
  end if;

  for v_row in select d.event_id, d.to_user from public.glad_push_due(now()) d loop
    perform public.glad_push_post(v_row.event_id, v_row.to_user);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function public.glad_push_cron_tick() from public, anon, authenticated;
grant execute on function public.glad_push_cron_tick() to service_role;

comment on function public.glad_push_cron_tick() is
  '1.2.5 Task 4: expires stale glad pushes, skips muted or departed recipients, and posts the due ones (room clock 08:00-22:00 and past deliver_at) to the glad-push edge function. The edge function claims each row before it sends, so a row posted twice still goes out once. Returns the number posted.';

-- =================================================================
-- 8. The schedule (TARS turns this on after deploying glad-push)
-- =================================================================
-- do $$ begin
--   if exists (select 1 from pg_extension where extname = 'pg_cron') then
--     perform cron.unschedule(jobid) from cron.job where jobname = 'glad-push-tick';
--     perform cron.schedule('glad-push-tick', '*/15 * * * *', 'select public.glad_push_cron_tick();');
--   end if;
-- end $$;
--
-- Every 15 minutes is enough: deliver_at is always on the hour, so a push
-- lands within 15 minutes of 09:00 or of the next whole hour.

notify pgrst, 'reload schema';

commit;
