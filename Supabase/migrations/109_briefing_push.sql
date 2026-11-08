-- 109: Briefing push ledger, due query and cron tick.
--
-- Lane S2B step 2. The server half of the pre-play briefing.
--
-- The failure this exists to kill (audit 01-notifications #1): every
-- briefing push today is a LOCAL notification scheduled on some
-- device's behalf. The device only schedules when the member opens
-- that room. The member who most needs the week-before nudge is the
-- one who never opens the app, and that member gets nothing. The
-- server knows the room, the night, the roster and the RSVP states.
-- It has no reason to wait for an app to open.
--
-- What this migration adds
--   1. public.briefing_push_ledger — one row per (event, member, kind)
--      that has gone out. The key IS the once-per-slot rule; the
--      edge function writes the row before it sends, so a repeat tick
--      cannot double-push.
--   2. public.briefing_push_due(p_now timestamptz) — the due query.
--      It resolves every slot that is due at p_now and returns one
--      row per (event, member, kind) that should go out, with the
--      current RSVP state and the room's clock.
--   3. public.briefing_push_secret() — vault read, the same shape as
--      105's anchor_push_secret.
--   4. public.briefing_push_cron_tick() — reads the due rows and
--      posts them to the briefing-push edge function over pg_net with
--      the shared secret.
--   5. cron job 'briefing-push-tick' every 15 minutes.
--
-- The slots, all computed in the ROOM's time zone (rooms.time_zone,
-- migration 108)
--   on_create      the event was created in the last 60 minutes.
--                  Non-host members only, and only those still
--                  unclaimed. The host is standing in the room.
--   t168h          7 days before the event day, 18:00 local.
--   t48h           3 days before the event day, 18:00 local.
--   morning_of     the earlier of 09:00 local on the event day and
--                  played_at - 3h, floored at 07:00 local.
--   host_headcount the t48h slot, to each host of the room.
--
-- The fire times are calendar-anchored, not offsets (audit #4, #5):
-- a plain played_at - 84h lands at 2am for an afternoon event, and
-- 09:00 on the day lands after the start for an early event.
--
-- The skip rules, the same ones the client plans with
--   * a slot is due when its time falls in (p_now - 20 min, p_now].
--     The cron runs every 15 minutes, so the 20 minute window catches
--     every slot exactly once and never twice.
--   * on_create is due when the event was created in the last 60
--     minutes (its own window, so a creation that lands between two
--     ticks is not missed).
--   * t168h and t48h are skipped when they fall within 24 hours
--     after the event was created (audit #6: no two pings an hour
--     apart for the same night).
--   * morning_of is skipped when it falls within 2 hours after the
--     event was created (audit #5: a same-day creation already got
--     the on-create prompt).
--   * t48h is skipped when it falls within 24 hours of t168h
--     (audit #6). With the calendar-anchored times the two slots sit
--     exactly four days apart, so this guard is belt and braces.
--
-- The eligibility rules, per member
--   * active membership (membership_status = 'active');
--   * room notifications enabled for that member;
--   * the event is not muted for that member
--     (event_rsvps.notifications_muted, set by set_event_notifications_muted
--     from 066/078);
--   * the member is not in the event's hidden list;
--   * the event is unsettled and still in the future;
--   * the member has not declined (declined is terminal silence);
--   * no ledger row for that (event, member, kind) yet;
--   * the member has an active device token, so nobody is pushed to a
--     device that cannot show it (audit #18).
--
-- host_headcount rides the t48h slot, so it inherits that slot's skip
-- rules: when the t48h slot is skipped there is no headcount either.
-- That is the one deliberate reading in this file and it is noted in
-- .maestro/STATE-S2B.md.
--
-- Requires 108 (rooms.time_zone) to be applied first.
--
-- NOT applied to live. Written and gated here; the orchestrator applies
-- it after Nathan's sign-off, then sets the vault secret and deploys the
-- edge function (it ships disabled behind BRIEFING_PUSH_ENABLED until
-- it does):
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/109_briefing_push.sql
--
-- Idempotent: create-table-if-not-exists, create-or-replace,
-- drop-and-reschedule the cron job.
-- Rollback: drop function public.briefing_push_cron_tick();
-- drop function public.briefing_push_due(timestamptz);
-- drop function public.briefing_push_secret(); drop table
-- public.briefing_push_ledger; and unschedule the cron job
-- 'briefing-push-tick'.
begin;

-- =================================================================
-- 1. The ledger: one row per (event, member, kind) that has gone out
-- =================================================================
create table if not exists public.briefing_push_ledger (
  event_id uuid        not null references public.events(id) on delete cascade,
  user_id  uuid        not null references public.users(id) on delete cascade,
  kind     text        not null,
  sent_at  timestamptz not null default now(),
  primary key (event_id, user_id, kind)
);

comment on table public.briefing_push_ledger is
  'S2B: the briefing push ledger. One row per (event, member, kind) that has gone out. The primary key is the once-per-slot rule. Written by the briefing-push edge function on the service role before the send, so a repeated cron tick cannot double-push.';

create index if not exists idx_briefing_push_ledger_sent_at
  on public.briefing_push_ledger (sent_at);

alter table public.briefing_push_ledger enable row level security;

-- No client policies on purpose. The only writer is the edge function
-- on the service role.
revoke all on table public.briefing_push_ledger from public, anon, authenticated;
grant all on table public.briefing_push_ledger to service_role;

-- =================================================================
-- 2. The due query
-- =================================================================
create or replace function public.briefing_push_due(p_now timestamptz)
returns table (
  event_id    uuid,
  room_id     uuid,
  user_id     uuid,
  kind        text,
  rsvp_state  text,
  event_name  text,
  played_at   timestamptz,
  host_note   text,
  time_zone   text,
  mascot_name text
)
language sql
stable
security definer
set search_path = public
as $$
  with ev as (
    -- The nights that could produce a push at all.
    select
      e.id                   as event_id,
      e.room_id              as room_id,
      e.name                 as event_name,
      e.played_at            as played_at,
      e.created_at           as created_at,
      e.host_note            as host_note,
      e.hidden_from_user_ids as hidden_from_user_ids,
      r.time_zone            as time_zone,
      r.mascot_name          as mascot_name
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.settled_at is null
      and e.played_at > p_now
      and r.deleted_at is null
      and (
        -- Trusted callers (pg_cron, triggers, the service role) see
        -- every room. An app user sees only the rooms they are in, so
        -- the function is safe to call from the client.
        public.rpc_caller_trusted()
        or public.is_room_member(e.room_id, public.current_user_id())
      )
  ),
  times as (
    -- The three clock-anchored slots, in the room's own zone.
    select
      ev.*,
      (((ev.played_at at time zone ev.time_zone)::date - 7) + time '18:00')
        at time zone ev.time_zone as t168_at,
      (((ev.played_at at time zone ev.time_zone)::date - 3) + time '18:00')
        at time zone ev.time_zone as t48_at,
      greatest(
        least(
          (((ev.played_at at time zone ev.time_zone)::date + time '09:00')
            at time zone ev.time_zone),
          ev.played_at - interval '3 hours'
        ),
        (((ev.played_at at time zone ev.time_zone)::date + time '07:00')
          at time zone ev.time_zone)
      ) as morning_at
    from ev
  ),
  slots as (
    -- Which slots are due at p_now, and which are skipped.
    select
      t.*,
      (
        t.created_at > p_now - interval '60 minutes'
        and t.created_at <= p_now
      ) as on_create_due,
      (
        t.t168_at > p_now - interval '20 minutes'
        and t.t168_at <= p_now
        and t.t168_at - t.created_at >= interval '24 hours'
      ) as t168_due,
      (
        t.t48_at > p_now - interval '20 minutes'
        and t.t48_at <= p_now
        and t.t48_at - t.created_at >= interval '24 hours'
        and t.t48_at - t.t168_at >= interval '24 hours'
      ) as t48_due,
      (
        t.morning_at > p_now - interval '20 minutes'
        and t.morning_at <= p_now
        and t.morning_at - t.created_at >= interval '2 hours'
      ) as morning_due
    from times t
  ),
  due_slots as (
    select
      s.event_id, s.room_id, s.event_name, s.played_at, s.host_note,
      s.hidden_from_user_ids, s.time_zone, s.mascot_name,
      'on_create'::text as kind
    from slots s where s.on_create_due
    union all
    select
      s.event_id, s.room_id, s.event_name, s.played_at, s.host_note,
      s.hidden_from_user_ids, s.time_zone, s.mascot_name,
      't168h'::text
    from slots s where s.t168_due
    union all
    select
      s.event_id, s.room_id, s.event_name, s.played_at, s.host_note,
      s.hidden_from_user_ids, s.time_zone, s.mascot_name,
      't48h'::text
    from slots s where s.t48_due
    union all
    select
      s.event_id, s.room_id, s.event_name, s.played_at, s.host_note,
      s.hidden_from_user_ids, s.time_zone, s.mascot_name,
      'morning_of'::text
    from slots s where s.morning_due
    union all
    -- The headcount rides the t48h slot, so it inherits that slot's
    -- skip rules.
    select
      s.event_id, s.room_id, s.event_name, s.played_at, s.host_note,
      s.hidden_from_user_ids, s.time_zone, s.mascot_name,
      'host_headcount'::text
    from slots s where s.t48_due
  )
  select
    d.event_id,
    d.room_id,
    m.user_id,
    d.kind,
    coalesce(er.state::text, 'unclaimed') as rsvp_state,
    d.event_name,
    d.played_at,
    d.host_note,
    d.time_zone,
    d.mascot_name
  from due_slots d
  join public.room_memberships m
    on m.room_id = d.room_id
   and m.membership_status = 'active'
  left join public.event_rsvps er
    on er.event_id = d.event_id
   and er.member_id = m.user_id
  where coalesce(m.notifications_enabled, false)
    and not (m.user_id = any (d.hidden_from_user_ids))
    and coalesce(er.state::text, 'unclaimed') <> 'declined'
    and not coalesce(er.notifications_muted, false)
    and exists (
      select 1 from public.device_tokens dt
      where dt.user_id = m.user_id
        and dt.is_active
    )
    and not exists (
      select 1 from public.briefing_push_ledger l
      where l.event_id = d.event_id
        and l.user_id = m.user_id
        and l.kind = d.kind
    )
    and (
      -- on_create: non-host members who have not claimed yet.
      (
        d.kind = 'on_create'
        and coalesce(er.state::text, 'unclaimed') = 'unclaimed'
        and not public.is_room_host(d.room_id, m.user_id)
      )
      -- host_headcount: the hosts of the room.
      or (
        d.kind = 'host_headcount'
        and public.is_room_host(d.room_id, m.user_id)
      )
      -- The three member slots: any eligible member, claimed or not.
      or (d.kind in ('t168h', 't48h', 'morning_of'))
    )
  order by d.kind, d.event_id, m.user_id;
$$;

revoke all on function public.briefing_push_due(timestamptz) from public, anon;
grant execute on function public.briefing_push_due(timestamptz) to authenticated, service_role;

comment on function public.briefing_push_due(timestamptz) is
  'S2B: the briefing slots that are due at p_now, one row per (event, member, kind), with the current RSVP state, the room time zone and the mascot name. Slot times are computed in the room zone. Trusted callers see every room; an app user sees only their own rooms.';

-- =================================================================
-- 3. Shared secret
-- =================================================================
create or replace function public.briefing_push_secret()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if not exists (select 1 from pg_namespace where nspname = 'vault') then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
    into v_secret using 'briefing_push_secret';
  return v_secret;
end;
$$;

-- NOT granted to authenticated. This reader returns the push shared
-- secret, and migration 104 revoked EXECUTE on the same shape of
-- reader (question_turn_push_secret) from the app roles for exactly
-- this reason. Only the service role and the cron path get it.
revoke all on function public.briefing_push_secret() from public, anon, authenticated;
grant execute on function public.briefing_push_secret() to service_role;

comment on function public.briefing_push_secret() is
  'Vault read for briefing_push_secret, mirroring public.anchor_push_secret() from 105 and public.question_turn_push_secret() from 097. null when the vault schema is absent or the secret is unset, which is what keeps the sender closed until an orchestrator sets it.';

-- =================================================================
-- 4. The tick: due rows -> pg_net -> briefing-push
-- =================================================================
create or replace function public.briefing_push_cron_tick()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_url    text := 'https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/briefing-push';
  v_secret text;
  v_batch  record;
  v_n      integer := 0;
begin
  -- Fail closed. No pg_net or no vault secret means no send, and no
  -- ledger row is consumed, so the slots stay due for the next tick.
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 0;
  end if;

  v_secret := public.briefing_push_secret();
  if v_secret is null or v_secret = '' then
    return 0;
  end if;

  -- Batched so no single request carries an unbounded body. Every row
  -- is sent; nothing is dropped, because a dropped slot would fall out
  -- of the 20 minute due window before the next tick.
  for v_batch in
    select
      jsonb_agg(
        jsonb_build_object(
          'event_id',    s.event_id,
          'room_id',     s.room_id,
          'user_id',     s.user_id,
          'kind',        s.kind,
          'rsvp_state',  s.rsvp_state,
          'event_name',  s.event_name,
          'played_at',   s.played_at,
          'host_note',   s.host_note,
          'time_zone',   s.time_zone,
          'mascot_name', s.mascot_name
        )
        order by s.kind, s.event_id, s.user_id
      ) as body,
      count(*) as n
    from (
      select
        d.*,
        (((row_number() over (order by d.kind, d.event_id, d.user_id) - 1) / 200))::int as grp
      from public.briefing_push_due(now()) d
    ) s
    group by s.grp
  loop
    -- The body carries the rows; the edge function writes the ledger
    -- row, sends, and marks dead tokens inactive.
    execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
      using v_url,
            jsonb_build_object('Content-Type', 'application/json', 'X-Briefing-Push-Secret', v_secret),
            jsonb_build_object('rows', v_batch.body);

    v_n := v_n + v_batch.n::int;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.briefing_push_cron_tick() from public, anon;
grant execute on function public.briefing_push_cron_tick() to authenticated, service_role;

comment on function public.briefing_push_cron_tick() is
  'S2B: reads the due briefing slots and posts them to the briefing-push edge function over pg_net with the vault shared secret. Returns the number of rows sent. No pg_net or no secret means no send and no consumed slot. The cron runs with no JWT, so it sees every room; a tick an app user triggers carries that user''s JWT, so it only covers the rooms that user is in.';

-- =================================================================
-- 5. The cron job
-- =================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'briefing-push-tick';
    perform cron.schedule('briefing-push-tick', '*/15 * * * *', 'select public.briefing_push_cron_tick();');
  else
    raise notice '109: pg_cron not installed; the briefing push has to be driven by hand.';
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
