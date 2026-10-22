-- 105: V0.107 Brought By, section 2b — the anchor push.
--
-- Spec: docs/V0.107_BROUGHT_BY_SPEC.md section 2b, checks A11 and A12.
-- Lineage: 103_brought_by.sql (the roster anchor + host switch),
--          097_question_box.sql section 8 (the pg_net sender shape),
--          068_multi_room_graph.sql (room_memberships.invited_by),
--          093/095 (membership_status = 'active', is_room_host).
--
-- The failure this exists to kill: a newcomer claims a seat and the person
-- who brought them does not, so they arrive with nobody at the table. When
-- that happens the inviter gets exactly one push. Never the newcomer, never
-- the table.
--
-- What this migration adds
--   1. room_memberships.anchor_push_enabled boolean not null default true —
--      the member switch from spec section 3. Additive.
--   2. public.anchor_nudges, keyed (event_id, newcomer_user_id). The key IS
--      the once-per-newcomer-per-event rule: the second attempt conflicts
--      and sends nothing. RLS on, no policies, service role only.
--   3. public.anchor_push_secret() — vault read, same shape as
--      097's question_turn_push_secret, null when vault is absent.
--   4. public.queue_anchor_nudge(p_event_id, p_newcomer_user_id) — every
--      rule below, then one pg_net post to anchor-nudge-push.
--   5. public.event_rsvps_anchor_push() trigger, after insert or update of
--      state, on public.event_rsvps.
--   6. get_anchor_push_enabled / set_anchor_push_enabled for the caller's
--      own active membership.
--
-- The rules, all inside queue_anchor_nudge
--   * the newcomer holds a claimed seat for this event;
--   * the newcomer has an inviter (room_memberships.invited_by) who is
--     still an ACTIVE member of the same room — a kicked or departed
--     inviter never receives anything (spec section 5);
--   * the inviter has NOT claimed a seat for this event (otherwise they are
--     already coming and the push is noise);
--   * the inviter's room notifications are on AND their anchor push switch
--     is on;
--   * the event has not started (events.played_at > now());
--   * the newcomer is in their first three nights: fewer than 3 settled
--     events in this room where they held a claimed RSVP.
--
-- Fail-closed ordering: pg_net and the vault secret are checked BEFORE the
-- anchor_nudges insert. If either is missing we return without inserting, so
-- a send that never happened does not consume the one allowed nudge — when
-- the secret is finally set, the next claim can still send.
--
-- NOT applied to live. Written and gated here; the orchestrator applies it
-- after Nathan's sign-off, then sets the vault secret and deploys the edge
-- function (it ships disabled behind ANCHOR_PUSH_ENABLED until it does):
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/105_anchor_push.sql
--
-- Idempotent: create-table-if-not-exists, add-column-if-not-exists,
-- create-or-replace, drop-trigger-if-exists.
-- Rollback: drop trigger event_rsvps_anchor_push on public.event_rsvps;
-- drop function public.event_rsvps_anchor_push(); drop function
-- public.queue_anchor_nudge(uuid, uuid); drop function
-- public.anchor_push_secret(); drop table public.anchor_nudges; alter
-- table public.room_memberships drop column anchor_push_enabled;
-- drop function public.get_anchor_push_enabled(uuid); drop function
-- public.set_anchor_push_enabled(uuid, boolean).
begin;

-- =================================================================
-- 1. Member switch
-- =================================================================
alter table public.room_memberships
  add column if not exists anchor_push_enabled boolean not null default true;

comment on column public.room_memberships.anchor_push_enabled is
  'V0.107 Brought By section 3: member switch for the anchor push. Off stops the "Sam''s coming Friday. Are you?" push to this member. Distinct from notifications_enabled, which is the room-wide push switch.';

-- =================================================================
-- 2. One row per nudge attempt — the dedupe lives in the key
-- =================================================================
create table if not exists public.anchor_nudges (
  event_id         uuid        not null references public.events(id) on delete cascade,
  newcomer_user_id uuid        not null,
  inviter_user_id  uuid        not null,
  room_id          uuid        not null,
  created_at       timestamptz not null default now(),
  push_status      text,
  primary key (event_id, newcomer_user_id)
);

comment on table public.anchor_nudges is
  'V0.107 Brought By section 2b: the anchor push ledger. One row per (event, newcomer); the primary key is what makes the push once-only (A11: "claiming again or re-saving does not resend"). The inviter, never the newcomer or the table, is the recipient. push_status moves queued -> sent / failed in the edge function.';

create index if not exists idx_anchor_nudges_room_id
  on public.anchor_nudges (room_id);

alter table public.anchor_nudges enable row level security;

-- No policies on purpose. Writes come from queue_anchor_nudge (SECURITY
-- DEFINER, trigger-only) and from the edge function on the service role.
revoke all on table public.anchor_nudges from public, anon, authenticated;

-- =================================================================
-- 3. Shared secret
-- =================================================================
create or replace function public.anchor_push_secret()
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
    into v_secret using 'anchor_push_secret';
  return v_secret;
end;
$$;

revoke all on function public.anchor_push_secret() from public, anon, authenticated;

comment on function public.anchor_push_secret() is
  'Vault read for anchor_push_secret, mirroring public.question_turn_push_secret() from 097. null when the vault schema is absent or the secret is unset, which is what keeps the sender closed until an orchestrator sets it.';

-- =================================================================
-- 4. The rule set
-- =================================================================
create or replace function public.queue_anchor_nudge(
  p_event_id uuid,
  p_newcomer_user_id uuid
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_url     text := 'https://bnrgkdcluopicqdpmrtu.supabase.co/functions/v1/anchor-nudge-push';
  v_secret  text;
  v_room    uuid;
  v_inviter uuid;
  v_nights  int;
begin
  select e.room_id into v_room
  from public.events e
  where e.id = p_event_id;

  if v_room is null then
    return;
  end if;

  -- Never once the event has started (A12).
  if exists (
    select 1 from public.events e
    where e.id = p_event_id
      and e.played_at is not null
      and e.played_at <= now()
  ) then
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

  -- Payload carries ids only; the function re-reads the row and resolves
  -- the single recipient (the inviter), the name, and the event time.
  execute 'select net.http_post(url := $1, headers := $2, body := $3, timeout_milliseconds := 10000)'
    using v_url,
          jsonb_build_object('Content-Type', 'application/json', 'X-Anchor-Push-Secret', v_secret),
          jsonb_build_object('event_id', p_event_id,
                             'newcomer_user_id', p_newcomer_user_id);
end;
$$;

revoke all on function public.queue_anchor_nudge(uuid, uuid) from public, anon, authenticated;

comment on function public.queue_anchor_nudge(uuid, uuid) is
  'V0.107 section 2b: applies every anchor-push rule for (event, newcomer) and, only when a ledger row was actually inserted, posts to the anchor-nudge-push edge function. Trigger-only, never callable by a member.';

-- =================================================================
-- 5. Trigger on RSVPs
-- =================================================================
create or replace function public.event_rsvps_anchor_push()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_newcomer uuid;
begin
  -- event_rsvps.member_id is a user id, not a membership id: the 033 RLS
  -- policies are member_id = auth.uid().

  -- A newcomer claims (or re-saves a claim): check their inviter.
  if new.state = 'claimed' then
    perform public.queue_anchor_nudge(new.event_id, new.member_id);
    return new;
  end if;

  -- An inviter releases a seat the newcomer still holds: now the anchor is
  -- missing, so re-check everyone they brought who is still coming (A11
  -- second trigger, spec section 2b Trigger). tg_op guard first: OLD is
  -- unassigned on INSERT, so an 'unclaimed' row arriving fresh would raise.
  if tg_op = 'UPDATE'
     and old.state = 'claimed'
     and new.state is distinct from 'claimed' then
    for v_newcomer in
      select m.user_id
      from public.room_memberships m
      where m.room_id = new.room_id
        and m.invited_by = new.member_id
        and m.membership_status = 'active'
        and m.user_id <> new.member_id
        and exists (
          select 1 from public.event_rsvps r
          where r.event_id = new.event_id
            and r.member_id = m.user_id
            and r.state = 'claimed'
        )
    loop
      perform public.queue_anchor_nudge(new.event_id, v_newcomer);
    end loop;
  end if;

  return new;
end;
$$;

revoke all on function public.event_rsvps_anchor_push() from public, anon, authenticated;

drop trigger if exists event_rsvps_anchor_push on public.event_rsvps;
create trigger event_rsvps_anchor_push
  after insert or update of state on public.event_rsvps
  for each row execute function public.event_rsvps_anchor_push();

comment on trigger event_rsvps_anchor_push on public.event_rsvps is
  'V0.107 section 2b: fires the anchor-push rule when a seat is claimed and again when an inviter releases one. Idempotent by design — the ledger key absorbs every repeat.';

-- =================================================================
-- 6. Member RPCs
-- =================================================================
create or replace function public.get_anchor_push_enabled(p_room_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  -- No row for a non-member, so the client reads null and falls back to on.
  select m.anchor_push_enabled
  from public.room_memberships m
  where m.room_id = p_room_id
    and m.user_id = public.current_user_id()
    and m.membership_status = 'active';
$$;

revoke all on function public.get_anchor_push_enabled(uuid) from public, anon;
grant execute on function public.get_anchor_push_enabled(uuid) to authenticated;

comment on function public.get_anchor_push_enabled(uuid) is
  'The caller''s own anchor_push_enabled for one room, active members only, null otherwise. V0.107 Brought By section 3 member switch.';

create or replace function public.set_anchor_push_enabled(p_room_id uuid, p_on boolean)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  -- Member-callable but self-scoped: the predicate is the guard, so there
  -- is no host check and no way to write another member's switch.
  update public.room_memberships m
     set anchor_push_enabled = p_on
   where m.room_id = p_room_id
     and m.user_id = public.current_user_id()
     and m.membership_status = 'active';

  if not found then
    raise exception 'not_a_member' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.set_anchor_push_enabled(uuid, boolean) from public, anon;
grant execute on function public.set_anchor_push_enabled(uuid, boolean) to authenticated;

comment on function public.set_anchor_push_enabled(uuid, boolean) is
  'Sets the caller''s own anchor_push_enabled for one room. Anyone without an active membership raises not_a_member (42501). V0.107 Brought By.';

commit;