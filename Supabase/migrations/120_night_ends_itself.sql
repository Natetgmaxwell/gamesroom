-- 120: The night ends itself.
--
-- Lane: Task AD (derive-at-read autoclose). This file replaces the
-- never-applied 120_stale_close_cron.sql: same number, same slot, new
-- name and new rule.
--
-- Why
--   The end of a night is played_at + the room's auto_close_hours. That
--   value is known the moment the night is BOOKED -- before it starts,
--   before anybody is in the room -- so "has this night ended?" is a
--   question about two timestamps, not about whether some writer has
--   run yet.
--
--   The old rule answered it with the physical column events.settled_at,
--   which stays null until somebody writes it: the host, when they
--   settle their own night, or the janitor, when it gets around to it.
--   Until then an expired night read 'stranded' -- started, window
--   gone, nobody settled it -- even though the night had ended hours
--   ago. The table simply did not know it yet.
--
--   That made correctness depend on a clock. The janitor
--   (public.cron_close_stale, hourly at minute 17) was the only writer
--   that could end a night nobody settled, so how a night read depended
--   on whether the tick had run yet -- and a night nobody ever looked
--   at was a night the tick was the only thing that would ever close.
--
-- The rule
--   Effective settle, for an event e in a room r, at time p_now:
--
--     coalesce(
--       e.settled_at,                                     -- the host's stamp wins
--       case when p_now >= e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
--            then e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
--       end)
--
--   The physical stamp is FIRST, so a host who settles their own night
--   early (or late) keeps the truth about their night. The derived
--   value is the night's true end -- the same stamp the writers already
--   write (auto_close_stale_events at 115:820, and the janitor below) --
--   so deriving and stamping agree by construction: the column catches
--   up with what the reads already said.
--
-- What changes
--   1. public.night_phase(...) -- the recap/past branches read the
--      EFFECTIVE settle. 'stranded' stays in the vocabulary but becomes
--      unreachable: an expired night now has a non-null effective
--      settle, so it reads 'recap' (ended inside 24h) or 'past' (ended
--      before that). The branch is kept as a safety fallback.
--   2. public.get_active_event__inner(p_room_id) -- the settled leg
--      keys recency on the effective settle and RETURNS the effective
--      value as settled_at, so the client renders exactly as it did.
--   3. public.get_recent_settled_event(p_room_id) -- the same.
--   4. public.cron_close_stale() -- the body is unchanged (it stamps
--      the same derived value); the SCHEDULE drops from hourly at
--      minute 17 to DAILY at 03:17 ('17 3 * * *'). The janitor is now
--      hygiene: it keeps the physical column tidy for the queries that
--      still read it directly. Nothing waits on it any more, and
--      correctness does not depend on a writer having run.
--
-- What does NOT change
--   - The membership gate on get_recent_settled_event, the
--     hidden-member filter on both reads, and every other gate:
--     byte-for-byte.
--   - The live leg of get_active_event__inner. Its filter
--     (settled_at is null AND played_at > now() - the room's window) is
--     exactly "the effective settle is null", so the live leg and the
--     settled leg stay disjoint and exhaustive.
--   - Every consumer that reads events.settled_at for a reason other
--     than phase recency (the newcomer-anchor count, settle_event's
--     write guard, the question box, the briefing sweep, the
--     attestation sweep). Those live in applied migrations; they are
--     listed in REPORT-task-AD.md and are not touched here.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/120_night_ends_itself.sql
--
-- Live apply is Nathan-gated and is NOT done in this lane.
--
-- Numbering note: 120 was never applied (it is the highest number in
-- the chain and it shipped on this branch only), so the rule changed in
-- place rather than as a 121. Nothing that is live depends on the old
-- body.

begin;

-- =================================================================
-- 1. night_phase -- one rule for "what phase is this night in".
-- =================================================================
create or replace function public.night_phase(
  p_played_at timestamp with time zone,
  p_settled_at timestamp with time zone,
  p_auto_close_hours integer,
  p_now timestamp with time zone default now()
)
returns text
language sql
immutable
as $$
  -- The effective settle: the host's own stamp when there is one, the
  -- night's true end (played_at + the room's window) once p_now has
  -- reached it. The stamp wins, so a host who settled early keeps the
  -- truth about their night.
  with facts as (
    select
      p_played_at as played_at,
      p_now as now_at,
      coalesce(
        p_settled_at,
        case when p_now >= p_played_at + make_interval(hours => coalesce(p_auto_close_hours, 8))
             then p_played_at + make_interval(hours => coalesce(p_auto_close_hours, 8))
        end
      ) as settled_at
  )
  select case
    when f.played_at is null then 'none'
    when f.played_at > f.now_at then 'upcoming'
    -- 'live' also requires NO effective settle: a night the host
    -- settled early has ended, so it reads 'recap' below, never 'live'.
    when f.settled_at is null
         and f.now_at < f.played_at + make_interval(hours => coalesce(p_auto_close_hours, 8))
      then 'live'
    when f.settled_at > f.now_at - interval '24 hours' then 'recap'
    when f.settled_at is not null then 'past'
    -- Unreachable safety fallback: a null effective settle means p_now
    -- has not reached the window end, so the 'live' branch above took
    -- it. 'stranded' stays in the vocabulary because the Swift twin
    -- still names it; no input reaches it any more.
    else 'stranded'
  end
  from facts f;
$$;

revoke all on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) from public, anon;
grant execute on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) to authenticated, service_role;

comment on function public.night_phase(timestamp with time zone, timestamp with time zone, integer, timestamp with time zone) is
  'S -- the night''s phase as one scalar: none / upcoming / live / recap / past (stranded stays in the vocabulary as an unreachable safety fallback). The settle input is the EFFECTIVE settle: the host''s own stamp when there is one, otherwise the night''s true end (played_at + auto_close_hours) once p_now has reached it -- the end is known at booking time, so no writer has to run for the night to have ended. `live` ends at played_at + auto_close_hours whether or not the night was settled; `recap` is an end inside the last 24h; `past` is an end before that. Immutable: pass p_now to pin the clock.';

-- =================================================================
-- 2. get_active_event__inner -- the settled leg reads the effective
--    settle and returns it, so the client renders unchanged.
-- =================================================================
create or replace function public.get_active_event__inner(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamp with time zone,
    created_at timestamp with time zone,
    host_note text,
    pack_slug text,
    settled_at timestamp with time zone,
    max_seats integer,
    pack_slugs text[],
    hidden_from_user_ids uuid[],
    event_calendar_identifier text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  -- (i) The live night. Started, not settled, and still inside the
  --     room's auto-close window, so a night from last month cannot
  --     masquerade as tonight. Latest start wins.
  --
  --     This filter is unchanged, and it is exactly "the effective
  --     settle is null": settled_at is null AND the window has not
  --     closed. So this leg and the settled leg below stay disjoint.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at <= now()
      and e.settled_at is null
      and e.played_at > now() - make_interval(hours => coalesce(r.auto_close_hours, 8))
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by e.played_at desc
    limit 1;
  if found then
    return;
  end if;

  -- (ii) The next night. Soonest first. A future night outranks a
  --      fresh recap: the claim card is what the room page needs,
  --      and get_recent_settled_event carries the recap alongside it.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at > now()
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by e.played_at asc
    limit 1;
  if found then
    return;
  end if;

  -- (iii) The night we just finished. The recap window is measured
  --       from the EFFECTIVE settle: the host's own stamp when there
  --       is one, otherwise the night's true end (played_at + the
  --       room's window) once now() has reached it. A night nobody
  --       settled but that ended two hours ago is already a recap --
  --       it no longer waits for a janitor to notice.
  --
  --       The effective value is what the row CARRIES back as
  --       settled_at, so the client renders exactly what it rendered
  --       when the column was written by hand.
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, eff.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    cross join lateral (
      select coalesce(
               e.settled_at,
               case when now() >= e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
                    then e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
               end
             ) as settled_at
    ) eff
    where e.room_id = p_room_id
      and eff.settled_at is not null
      and eff.settled_at > now() - interval '24 hours'
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by eff.settled_at desc
    limit 1;
end;
$$;

revoke all on function public.get_active_event__inner(uuid) from public, anon, authenticated;

comment on function public.get_active_event__inner(uuid) is
  'V1.24 -- the one event a room page should show: the live night (started, unsettled, inside the room''s auto-close window), else the next scheduled night, else the night that ended in the last 24h. The third leg keys on the EFFECTIVE settle -- the host''s stamp, else the night''s true end (played_at + auto_close_hours) -- and returns that value as settled_at, so a night nobody settled reads as a recap the moment it ends. Exactly one row. Hidden members never see the events they are hidden from.';

-- =================================================================
-- 3. get_recent_settled_event -- the same effective settle, behind
--    the same membership gate and the same hidden-member filter.
-- =================================================================
create or replace function public.get_recent_settled_event(p_room_id uuid)
returns table (
    id uuid,
    room_id uuid,
    name text,
    played_at timestamp with time zone,
    created_at timestamp with time zone,
    host_note text,
    pack_slug text,
    settled_at timestamp with time zone,
    max_seats integer,
    pack_slugs text[],
    hidden_from_user_ids uuid[],
    event_calendar_identifier text
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (public.rpc_caller_trusted() or public.is_room_member(p_room_id, public.current_user_id())) then
    return;
  end if;
  return query
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, eff.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs,
           e.hidden_from_user_ids,
           e.event_calendar_identifier
    from public.events e
    join public.rooms r on r.id = e.room_id
    cross join lateral (
      select coalesce(
               e.settled_at,
               case when now() >= e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
                    then e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
               end
             ) as settled_at
    ) eff
    where e.room_id = p_room_id
      and eff.settled_at is not null
      and eff.settled_at > now() - interval '24 hours'
      and not (public.current_user_id() = any(coalesce(e.hidden_from_user_ids, '{}'::uuid[])))
    order by eff.settled_at desc
    limit 1;
end;
$$;

revoke all on function public.get_recent_settled_event(uuid) from public, anon;
grant execute on function public.get_recent_settled_event(uuid) to authenticated, service_role;

comment on function public.get_recent_settled_event(uuid) is
  'V1.24 -- the night that ended in the last 24h, for the room page recap section. Recency is measured from the EFFECTIVE settle (the host''s stamp, else the night''s true end), and that value is returned as settled_at. Kept separate from get_active_event, which ranks the next future night first so one upcoming night can be scheduled straight after a settle.';

-- =================================================================
-- 4. The janitor, demoted to hygiene. The body is UNCHANGED: it
--    stamps played_at + the room's window, which is exactly the value
--    the reads above now derive. Only the schedule moves -- hourly at
--    minute 17 becomes daily at 03:17.
-- =================================================================
create or replace function public.cron_close_stale()
returns integer
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_room record;
  v_n integer := 0;
  v_closed integer := 0;
begin
  -- Events: the body of public.auto_close_stale_events(p_room_id)
  -- (migration 115), minus the member gate it cannot pass from a cron
  -- session, applied to every live room. The stamp is the moment the
  -- night stopped being live, so a long-stranded night reads 'past'
  -- rather than a recap settled a second ago.
  for v_room in
    select r.id, r.auto_close_hours
      from public.rooms r
     where r.deleted_at is null
  loop
    update public.events e
       set settled_at = e.played_at + make_interval(hours => v_room.auto_close_hours)
      where e.room_id = v_room.id
        and e.settled_at is null
        and e.played_at < now() - make_interval(hours => v_room.auto_close_hours);
    get diagnostics v_n = row_count;
    v_closed := v_closed + v_n;
  end loop;

  -- Attestations: global and guard-free -- one call, not one per room.
  v_closed := v_closed + public.close_stale_attestations();

  return v_closed;
end;
$$;

revoke all on function public.cron_close_stale() from public, anon, authenticated;

comment on function public.cron_close_stale() is
  'Task AD: the janitor is now HYGIENE, not correctness. The reads derive a night''s end from played_at + the room''s auto_close_hours, so nothing waits for this job to run; it exists to keep the physical settled_at column tidy for the queries that still read it directly, and to close attestations open more than 24h. It stamps settled_at = played_at + the room''s auto_close_hours -- the same value the reads derive -- and is called by the pg_cron job ''gr-stale-close'' (daily at 03:17) only: no app role may execute it. Idempotent: a second run closes nothing.';

-- =================================================================
-- 5. The cron job (guarded: pg_cron may not be installed).
--    Daily at 03:17 -- the janitor is hygiene now, so it does not need
--    to be hourly. The job is replaced rather than duplicated: the
--    unschedule runs first, by job name.
-- =================================================================
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gr-stale-close';
    perform cron.schedule('gr-stale-close', '17 3 * * *', 'select public.cron_close_stale();');
  else
    raise notice '120: pg_cron not installed; gr-stale-close not scheduled. Correctness does not depend on it -- the reads derive the effective settle -- so the only thing lost is the physical stamp; run public.cron_close_stale() by hand if you want it.';
  end if;
end $$;

notify pgrst, 'reload schema';

commit;
