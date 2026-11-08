-- 110: The anchor push waits for waking hours.
--
-- Lane S2B step 4. The server half of audit 01-notifications #13.
--
-- The failure this exists to kill: a newcomer claims a seat at 11:40pm
-- and the inviter's phone lights up with a time-sensitive "Sam's coming
-- Friday. Are you?". The nudge is meant to change behaviour (go claim
-- too), and it arrives when the inviter cannot act on it, through a
-- Focus mode they chose, for a night that is days away. It is not time
-- critical, so it should not break through Focus, and it should not
-- land at midnight.
--
-- What this migration changes
--   1. public.queue_anchor_nudge is replaced. Every rule from 105 stays
--      exactly as it was. What changes is the last step: the ledger row
--      is written first, and the push is only posted when the ROOM's
--      local clock is between 09:00 and 20:00. Outside that window the
--      row stays 'queued' and the cron delivers it at the next window.
--   2. public.anchor_push_in_window(p_room_id, p_at) — the window
--      test, read in the room's zone (rooms.time_zone, migration 108).
--   3. public.anchor_push_due(p_now) — the queued rows that are
--      deliverable now, with the room's clock.
--   4. public.anchor_push_cron_tick() — drops the rows that can no
--      longer be delivered and posts the due rows to the edge function.
--   5. cron job 'anchor-push-tick', every 15 minutes.
--
-- The deadline
--   A nudge is never delivered later than 24 hours before the night
--   (played_at - 24h). "Sam's coming Friday. Are you?" is only
--   actionable while there is time to claim a seat, so a nudge that
--   cannot be delivered before the mark is dropped rather than sent
--   late. The mark applies at queue time (a claim inside the last 24
--   hours is not worth nudging about) and again at delivery time (a
--   row that sat outside the window too long is expired, not sent).
--
-- The window
--   09:00 to 20:00 in the room's own time zone, so a room in Sydney
--   and a room in London get their own quiet hours. The window is
--   half open: 09:00 is inside it, 20:00 is not.
--
-- Who still gets it
--   The inviter, and only the inviter. The row already names them
--   (anchor_nudges.inviter_user_id) and the edge function only ever
--   addresses that one person. The queue does not widen the audience,
--   it only moves the moment.
--
-- The rules that did NOT change (105, unchanged here)
--   * the newcomer holds a claimed seat for this event;
--   * the newcomer is in their first three nights;
--   * the inviter is an ACTIVE member of the same room;
--   * the inviter's room notifications and anchor push switch are on;
--   * the inviter has NOT claimed a seat for this event;
--   * the event has not started;
--   * once per newcomer per event (the ledger key);
--   * fail closed: no pg_net or no vault secret means no row, so a
--     send that never happened does not consume the one allowed nudge.
--
-- The seat re-check at send time
--   The inviter may claim a seat between the queue and the delivery, so
--   the edge function re-reads the inviter's RSVP before it sends and
--   drops the nudge when they are already seated (audit #13). That
--   check lives in the edge function, where "send time" is.
--
-- Requires 108 (rooms.time_zone) to be applied first.
--
-- NOT applied to live. Written and gated here; the orchestrator applies
-- it after Nathan's sign-off, then sets the vault secret and deploys the
-- edge function (it ships disabled behind ANCHOR_PUSH_ENABLED until it
-- does):
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/110_anchor_push_waking_hours.sql
--
-- Idempotent: create-or-replace, drop-and-reschedule the cron job.
-- Rollback: drop function public.anchor_push_cron_tick();
-- drop function public.anchor_push_due(timestamptz);
-- drop function public.anchor_push_in_window(uuid, timestamptz);
-- drop function public.anchor_push_post(uuid, uuid);
-- restore the 105 body of public.queue_anchor_nudge(uuid, uuid);
-- and unschedule the cron job 'anchor-push-tick'.
begin;

-- =================================================================
-- 1. The service role writes the ledger
-- =================================================================
-- 105 revoked the table from the app roles and left it to the service
-- role, but never granted it explicitly. The edge function now claims a
-- queued row with a conditional UPDATE before it sends, so the grant
-- has to be there.
grant all on table public.anchor_nudges to service_role;

comment on column public.anchor_nudges.push_status is
  'S2B: queued -> sending -> sent / failed / no_device / skipped_started / skipped_seated, or expired when the T-24h mark passed before it could be delivered. The edge function claims a queued row with a conditional UPDATE, so the cron and the trigger can both post the same row without double-pushing.';

-- =================================================================
-- 2. The window test
-- =================================================================
-- Half open: 09:00 is inside, 20:00 is not. Read in the room's zone,
-- never in UTC and never in a hardcoded Australian zone.
create or replace function public.anchor_push_in_window(
  p_room_id uuid,
  p_at       timestamptz
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.rooms r
    where r.id = p_room_id
      and r.deleted_at is null
      and (p_at at time zone r.time_zone)::time >= time '09:00'
      and (p_at at time zone r.time_zone)::time < time '20:00'
  );
$$;

revoke all on function public.anchor_push_in_window(uuid, timestamptz) from public, anon;
grant execute on function public.anchor_push_in_window(uuid, timestamptz) to authenticated, service_role;

comment on function public.anchor_push_in_window(uuid, timestamptz) is
  'S2B: true when the room''s local clock is between 09:00 and 20:00 at the given instant, read in rooms.time_zone. The waking hours window for the anchor push (audit 01-notifications #13).';

-- =================================================================
-- 3. The post helper
-- =================================================================
-- One place that knows how to talk to the edge function, used by the
-- trigger (inside the window) and by the cron (for the rows that were
-- queued outside it).
create or replace function public.anchor_push_post(
  p_event_id         uuid,
  p_newcomer_user_id uuid
)
returns boolean
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_url    text := 'https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/anchor-nudge-push';
  v_secret text;
begin
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return false;
  end if;

  v_secret := public.anchor_push_secret();
  if v_secret is null or v_secret = '' then
    return false;
  end if;

  -- Payload carries ids only; the function re-reads the row and
  -- resolves the single recipient (the inviter), the name, and the
  -- event time.
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
    using v_url,
          jsonb_build_object('Content-Type', 'application/json', 'X-Anchor-Push-Secret', v_secret),
          jsonb_build_object('event_id', p_event_id,
                             'newcomer_user_id', p_newcomer_user_id);
  return true;
end;
$$;

revoke all on function public.anchor_push_post(uuid, uuid) from public, anon, authenticated;

comment on function public.anchor_push_post(uuid, uuid) is
  'S2B: posts one anchor nudge to the anchor-nudge-push edge function over pg_net with the vault shared secret. Trigger and cron path only, never callable by a member. Returns false when pg_net or the secret is missing, which is what keeps the sender closed until an orchestrator sets it up.';

-- =================================================================
-- 4. The rule set, with the queue
-- =================================================================
create or replace function public.queue_anchor_nudge(
  p_event_id uuid,
  p_newcomer_user_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_room      uuid;
  v_inviter   uuid;
  v_nights    int;
  v_played_at timestamptz;
  v_secret    text;
begin
  select e.room_id, e.played_at into v_room, v_played_at
  from public.events e
  where e.id = p_event_id;

  if v_room is null then
    return;
  end if;

  -- Never once the event has started (A12).
  if v_played_at is not null and v_played_at <= now() then
    return;
  end if;

  -- Never inside the last 24 hours (audit #13). The nudge asks the
  -- inviter to claim a seat; inside a day of the night there is no
  -- time to act on it, and the delivery deadline (played_at - 24h)
  -- has already passed.
  if v_played_at is not null
     and (v_played_at - interval '24 hours') <= now() then
    return;
  end if;

  -- The newcomer must actually be in. Both trigger paths pass through this.
  if not exists (
    select 1 from public.event_rsvps r
    where r.event_id = p_event_id
      and r.member_id = p_newcomer_user_id
      and r.state = 'claimed'
  ) then
    return;
  end if;

  -- First three nights only. After three settled nights they have their own
  -- footing and the push stops (spec section 2b, Limits).
  select count(*)::int into v_nights
  from public.event_rsvps r
  join public.events e on e.id = r.event_id
  where r.member_id = p_newcomer_user_id
    and r.state = 'claimed'
    and e.room_id = v_room
    and e.settled_at is not null;

  if v_nights >= 3 then
    return;
  end if;

  -- The inviter: still an ACTIVE member of the same room, someone else,
  -- room notifications on, anchor push switch on (A12 "member switch off"),
  -- and not already seated for this event (A12 "inviter already seated").
  select m.invited_by into v_inviter
  from public.room_memberships m
  where m.room_id = v_room
    and m.user_id = p_newcomer_user_id
    and m.membership_status = 'active'
    and m.invited_by is not null
    and m.invited_by <> m.user_id;

  if v_inviter is null then
    return;
  end if;

  if not exists (
    select 1 from public.room_memberships i
    where i.room_id = v_room
      and i.user_id = v_inviter
      and i.membership_status = 'active'
      and coalesce(i.notifications_enabled, false)
      and coalesce(i.anchor_push_enabled, true)
  ) then
    return;
  end if;

  if exists (
    select 1 from public.event_rsvps r
    where r.event_id = p_event_id
      and r.member_id = v_inviter
      and r.state = 'claimed'
  ) then
    return;
  end if;

  -- Fail closed, and only now consume the one allowed nudge: no pg_net, no
  -- secret, no row. Set up the secret later and the next claim still sends.
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return;
  end if;

  v_secret := public.anchor_push_secret();
  if v_secret is null or v_secret = '' then
    return;
  end if;

  insert into public.anchor_nudges (
    event_id, newcomer_user_id, inviter_user_id, room_id, push_status
  )
  values (
    p_event_id, p_newcomer_user_id, v_inviter, v_room, 'queued'
  )
  on conflict (event_id, newcomer_user_id) do nothing;

  -- Not inserted means this nudge already went out for this event (A11).
  if not found then
    return;
  end if;

  -- Inside the waking hours the nudge goes now. Outside them it stays
  -- 'queued' and the cron delivers it at the next window, or drops it
  -- if the T-24h mark passes first.
  if public.anchor_push_in_window(v_room, now()) then
    perform public.anchor_push_post(p_event_id, p_newcomer_user_id);
  end if;
end;
$$;

revoke all on function public.queue_anchor_nudge(uuid, uuid) from public, anon, authenticated;

comment on function public.queue_anchor_nudge(uuid, uuid) is
  'V0.107 section 2b with S2B step 4: applies every anchor-push rule for (event, newcomer) and writes the ledger row. The push is posted only when the room''s local clock is inside 09:00-20:00; outside that window the row stays queued for the anchor-push-tick cron, which delivers it at the next window and never later than played_at - 24h. Trigger-only, never callable by a member.';

-- =================================================================
-- 5. The due query
-- =================================================================
-- The queued rows that can be delivered right now: the room is in its
-- waking hours, the night is still more than 24 hours away, and the
-- night has not started.
create or replace function public.anchor_push_due(p_now timestamptz)
returns table (
  event_id         uuid,
  newcomer_user_id uuid,
  inviter_user_id  uuid,
  room_id          uuid,
  played_at        timestamptz,
  time_zone        text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    n.event_id,
    n.newcomer_user_id,
    n.inviter_user_id,
    n.room_id,
    e.played_at,
    r.time_zone
  from public.anchor_nudges n
  join public.events e on e.id = n.event_id
  join public.rooms r on r.id = n.room_id
  where n.push_status = 'queued'
    and r.deleted_at is null
    and e.played_at > p_now
    and (e.played_at - interval '24 hours') > p_now
    and (p_now at time zone r.time_zone)::time >= time '09:00'
    and (p_now at time zone r.time_zone)::time < time '20:00'
    and (
      -- Trusted callers (pg_cron, triggers, the service role) see every
      -- room. An app user sees only the rooms they are in, so the
      -- function is safe to call from the client.
      public.rpc_caller_trusted()
      or public.is_room_member(e.room_id, public.current_user_id())
    )
  order by n.created_at
  limit 200;
$$;

revoke all on function public.anchor_push_due(timestamptz) from public, anon;
grant execute on function public.anchor_push_due(timestamptz) to authenticated, service_role;

comment on function public.anchor_push_due(timestamptz) is
  'S2B: the queued anchor nudges that are deliverable at p_now, one row per (event, newcomer). A row is deliverable when the room''s local clock is inside 09:00-20:00, the night has not started and played_at - 24h has not passed. Trusted callers see every room; an app user sees only their own rooms.';

-- =================================================================
-- 6. The tick
-- =================================================================
-- Drop what can no longer be delivered, then post what can.
create or replace function public.anchor_push_cron_tick()
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
  -- The deadline: a row that sat outside the window for too long is
  -- expired, not sent late. The night starting covers this too, because
  -- played_at - 24h is already past by then.
  update public.anchor_nudges n
     set push_status = 'expired'
    from public.events e
   where n.event_id = e.id
     and n.push_status = 'queued'
     and (e.played_at - interval '24 hours') <= now();

  -- Fail closed. No pg_net or no vault secret means no send, and the
  -- rows stay queued for the next tick.
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return 0;
  end if;

  v_secret := public.anchor_push_secret();
  if v_secret is null or v_secret = '' then
    return 0;
  end if;

  for v_row in
    select d.event_id, d.newcomer_user_id
    from public.anchor_push_due(now()) d
  loop
    perform public.anchor_push_post(v_row.event_id, v_row.newcomer_user_id);
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

revoke all on function public.anchor_push_cron_tick() from public, anon;
grant execute on function public.anchor_push_cron_tick() to authenticated, service_role;

comment on function public.anchor_push_cron_tick() is
  'S2B: expires the anchor nudges whose T-24h mark has passed and posts the deliverable ones to the anchor-nudge-push edge function over pg_net with the vault shared secret. Returns the number of rows posted. No pg_net or no secret means no send and the rows stay queued. The edge function claims each row before it sends, so a row posted by both the trigger and the cron still goes out once.';

-- =================================================================
-- 7. The cron job
-- =================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'anchor-push-tick';
    perform cron.schedule('anchor-push-tick', '*/15 * * * *', 'select public.anchor_push_cron_tick();');
  else
    raise notice '110: pg_cron not installed; the queued anchor nudges have to be driven by hand.';
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
