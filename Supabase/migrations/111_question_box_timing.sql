-- 111: The Question Box waits for the table, and stops when the night does.
--
-- Lane S2B step 5. The server half of audit 01-notifications #14 and #15,
-- and the reader half of #18.
--
-- The failure this exists to kill
--   The opener card is created the moment played_at arrives, so the host's
--   phone buzzes at 7:30:00 exactly: the host is at the door and the table
--   is empty. People trickle in over the next half hour, so the box opens
--   into a room that has not formed. Then the rotation falls back to
--   "everyone who claimed a seat", so a member who never turned up gets
--   the reader push, never answers, and every turn after theirs dies with
--   it. And if the host forgets to settle the night, the box keeps
--   pushing time-sensitive reader cards into the small hours.
--
-- What this migration changes
--   1. public.question_box_arrivals(p_event_id) - who is actually at the
--      table: a withdrawal on the event, or a seat deposit that was
--      checked in.
--   2. public.question_box_rotation(p_event_id) - the no-bank fallback is
--      the arrived members, not the claimed ones.
--   3. public.question_box_advance(p_event_id, p_now) - the opener waits
--      for three arrivals or played_at + 30 minutes, whichever comes
--      first; the night ends at played_at + auto_close_hours; the box
--      goes quiet after 60 minutes without a read or a pass; and readers
--      with no active device token are skipped.
--   4. public.question_box_host(p_room_id) - the opener goes to a host
--      who can be reached (an active device token), with the live
--      resolution as the fallback.
--
-- The arrival signals
--   * a withdrawal: the member took chips off the bank for this event
--     (transactions.session_id = event and kind = 'casino_withdrawal').
--     This is the signal the rotation already used, and it stays first.
--   * a checked-in seat deposit: seat_deposits.returned_at is set. That is
--     the "I'm here" tap (check_in_seat), the host's waiver for a member
--     who arrived unscanned, and the automatic return when a play
--     transaction proves they were there. A forfeited deposit is not an
--     arrival and is left out.
--
--   Both signals are filtered to ACTIVE room members. A member who left
--   the room mid-night is not at the table and is not asked.
--
-- The rules that did NOT change
--   * the opener is still read by a host, and it is still the first turn;
--   * the cadence is still rooms.question_cadence_minutes (10, 20 or 30,
--     0 = off);
--   * one live card per event: a new turn supersedes the unanswered one;
--   * the question is drawn from tonight's member questions first, then
--     the host questions, then the house deck;
--   * the turn still goes out as one push to one reader
--     (question-turn-push), and the trigger on question_turns is
--     untouched.
--
-- The reading of "no turn was read or passed in the last 60 minutes"
--   It is read as the brief writes it: the newest read or pass on any
--   turn of the event. While the table is answering, the box keeps its
--   cadence; once an hour passes with nobody answering, the box stops.
--   The box wakes up again if somebody answers the card that is still
--   open, because the answer is then the newest read.
--
-- Started from the LIVE bodies in docs/audit/2026-11-08/live-functions.sql
-- (question_box_advance, question_box_host). question_box_rotation is not
-- in that dump: its body is 097's, unchanged since, and 098, 099 and 104
-- do not redefine it (104 only revokes its grants, and those are
-- preserved here).
--
-- NOT applied to live. Written and gated here; the orchestrator applies
-- it after Nathan's sign-off:
--   psql "$GAMES_ROOM_DB_URL" -v ON_ERROR_STOP=1 -f Supabase/migrations/111_question_box_timing.sql
--
-- Idempotent: create-or-replace on every function, create-index-if-not-exists
-- for the one index.
-- Rollback: restore the 097 bodies of public.question_box_advance(uuid,
-- timestamptz), public.question_box_host(uuid) and
-- public.question_box_rotation(uuid), and drop function
-- public.question_box_arrivals(uuid).
begin;

-- =================================================================
-- 1. Who is at the table
-- =================================================================
-- The arrivals of one event: the members who took chips off the bank for
-- it, and the members whose seat deposit was checked in. Both are the
-- honest "I am here" signal; a claim is not.
create or replace function public.question_box_arrivals(p_event_id uuid)
returns table (
  arrived_member_id uuid,
  arrived_at       timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_room uuid;
begin
  select e.room_id into v_room
    from public.events e
   where e.id = p_event_id;
  if v_room is null then
    return;
  end if;

  -- Trusted callers (cron, triggers, the service role) see every room. An
  -- app user sees only the rooms they are in, the same guard the other
  -- S2B query functions use.
  if not (
    public.rpc_caller_trusted()
    or public.is_room_member(v_room, public.current_user_id())
  ) then
    return;
  end if;

  return query
  select a.member_id, min(a.first_at)
    from (
      -- A withdrawal: the member took chips off the bank for this event.
      select t.member_id, min(t.created_at) as first_at
        from public.transactions t
        join public.room_memberships m
          on m.room_id = t.room_id
         and m.user_id = t.member_id
         and m.membership_status = 'active'
       where t.session_id = p_event_id
         and t.kind = 'casino_withdrawal'
       group by t.member_id
      union all
      -- A checked-in seat deposit: the "I'm here" tap, the host's waiver
      -- for somebody who arrived unscanned, or a play transaction that
      -- returned the deposit automatically. A forfeit is not an arrival.
      select sd.user_id, sd.returned_at as first_at
        from public.seat_deposits sd
        join public.room_memberships m
          on m.room_id = sd.room_id
         and m.user_id = sd.user_id
         and m.membership_status = 'active'
       where sd.event_id = p_event_id
         and sd.returned_at is not null
         and sd.status <> 'forfeited'
    ) a
   group by a.member_id
   order by min(a.first_at), a.member_id;
end;
$$;

revoke all on function public.question_box_arrivals(uuid) from public, anon;
grant execute on function public.question_box_arrivals(uuid) to authenticated, service_role;

comment on function public.question_box_arrivals(uuid) is
  'S2B: the members who are actually at the table for an event, with the time they arrived. A withdrawal on the event or a checked-in seat deposit (seat_deposits.returned_at is set) counts; a claim does not. Active members only. Trusted callers see every room; an app user sees only their own rooms.';

-- The arrivals read the transactions ledger by session, and there was no
-- index for that shape. The rotation query had the same gap.
create index if not exists transactions_session_kind_idx
  on public.transactions (session_id, kind);

-- =================================================================
-- 2. The rotation
-- =================================================================
-- The bank branch is unchanged: the people who withdrew, in the order
-- they withdrew. The fallback used to be everyone who claimed a seat,
-- which asked the absent; it is now the people who arrived.
create or replace function public.question_box_rotation(p_event_id uuid)
returns uuid[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_room uuid;
  v_ids uuid[];
begin
  select e.room_id into v_room from public.events e where e.id = p_event_id;

  -- Withdrawals are the arrival signal, ordered by first withdrawal.
  select array_agg(w.member_id order by w.first_at, w.member_id) into v_ids
    from (
      select t.member_id, min(t.created_at) as first_at
        from public.transactions t
        join public.room_memberships m
          on m.room_id = v_room and m.user_id = t.member_id and m.membership_status = 'active'
       where t.session_id = p_event_id and t.kind = 'casino_withdrawal'
       group by t.member_id
    ) w;
  if v_ids is not null and cardinality(v_ids) > 0 then
    return v_ids;
  end if;

  -- No bank tonight: the people who are actually here, in arrival order.
  -- The members who claimed a seat and never turned up are not asked.
  select array_agg(a.arrived_member_id order by a.arrived_at, a.arrived_member_id) into v_ids
    from public.question_box_arrivals(p_event_id) a;
  return coalesce(v_ids, '{}'::uuid[]);
end;
$$;

revoke all on function public.question_box_rotation(uuid) from public, anon, authenticated;
grant execute on function public.question_box_rotation(uuid) to service_role;

comment on function public.question_box_rotation(uuid) is
  'S2B: the reader rotation for an event. The members who withdrew from the bank, in withdrawal order; with no bank tonight, the members who arrived (public.question_box_arrivals), in arrival order. The old fallback was everyone who claimed a seat, which asked the people who never came. Active members only.';

-- =================================================================
-- 3. Who opens the box
-- =================================================================
-- The live resolution first: the room's host, else the longest-standing
-- active host. Then the reachability rule: the opener only arrives on a
-- phone with an active iOS device token, so a host who cannot be reached
-- is skipped for one who can.
create or replace function public.question_box_host(p_room_id uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_host uuid;
  v_alt  uuid;
begin
  select coalesce(
    (select r.created_by from public.rooms r
      where r.id = p_room_id and public.is_room_host(r.id, r.created_by)),
    (select m.user_id from public.room_memberships m
      where m.room_id = p_room_id and m.role = 'host' and m.membership_status = 'active'
      order by m.joined_at limit 1)
  ) into v_host;

  if v_host is null then
    return null;
  end if;

  if exists (
    select 1 from public.device_tokens dt
     where dt.user_id = v_host and dt.is_active and dt.platform = 'ios'
  ) then
    return v_host;
  end if;

  select m.user_id into v_alt
    from public.room_memberships m
   where m.room_id = p_room_id
     and m.role = 'host'
     and m.membership_status = 'active'
     and m.user_id <> v_host
     and exists (
       select 1 from public.device_tokens dt
        where dt.user_id = m.user_id and dt.is_active and dt.platform = 'ios'
     )
   order by m.joined_at
   limit 1;

  if v_alt is not null then
    return v_alt;
  end if;

  -- No host has a token. The opener still happens: the card shows in the
  -- app, and a host can answer it for the reader.
  return v_host;
end;
$$;

revoke all on function public.question_box_host(uuid) from public, anon, authenticated;
grant execute on function public.question_box_host(uuid) to service_role;

comment on function public.question_box_host(uuid) is
  'S2B: the host who reads the opener card. The room''s host, else the longest-standing active host; a host with no active iOS device token is passed over for one who has a token, and the live host is kept when no host has one. Never callable by a member.';

-- =================================================================
-- 4. The advance
-- =================================================================
-- The single writer of turns. Every rule from the live body is unchanged
-- except the four this migration adds.
create or replace function public.question_box_advance(
  p_event_id uuid,
  p_now      timestamptz default now()
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_e          record;
  v_rot        uuid[];
  v_reader     uuid;
  v_next_pos   integer;
  v_cand       uuid;
  v_kind       text;
  v_q          public.room_questions;
  v_turn       uuid;
  v_has_turns  boolean;
  v_arrived    integer;
  v_n          integer;
  v_i          integer;
begin
  select e.id, e.room_id, e.played_at, e.settled_at, e.question_reader_index,
         e.question_last_turn_at, r.question_box_enabled, r.question_cadence_minutes,
         r.auto_close_hours, r.deleted_at
    into v_e
    from public.events e join public.rooms r on r.id = e.room_id
   where e.id = p_event_id
   for update of e;
  if v_e.id is null or not v_e.question_box_enabled or v_e.deleted_at is not null then
    return null;
  end if;
  if v_e.settled_at is not null or v_e.played_at > p_now then
    return null;
  end if;
  -- The night is over. The host forgot to settle; the box stops anyway
  -- (audit #15).
  if p_now > v_e.played_at + make_interval(hours => v_e.auto_close_hours) then
    return null;
  end if;

  select exists (select 1 from public.question_turns t where t.event_id = p_event_id) into v_has_turns;

  if not v_has_turns then
    -- The opener waits for the table: three people have to be there, or
    -- half an hour after the start, whichever comes first (audit #14).
    select count(*)::int into v_arrived
      from public.question_box_arrivals(p_event_id);
    if v_arrived < 3 and p_now < v_e.played_at + make_interval(mins => 30) then
      return null;
    end if;
    v_kind := 'opener';
    v_reader := public.question_box_host(v_e.room_id);
  else
    -- The box has gone quiet: nothing has been read or passed for an
    -- hour, so stop asking (audit #15).
    if not exists (
      select 1 from public.question_turns t
       where t.event_id = p_event_id
         and coalesce(t.read_at, t.passed_at) > p_now - make_interval(mins => 60)
    ) then
      return null;
    end if;
    if v_e.question_cadence_minutes = 0 or v_e.question_last_turn_at is null
       or p_now < v_e.question_last_turn_at + make_interval(mins => v_e.question_cadence_minutes) then
      return null;
    end if;
    v_rot := public.question_box_rotation(p_event_id);
    v_n := cardinality(v_rot);
    if v_n = 0 then
      return null;
    end if;
    v_kind := 'interval';
    -- Skip the readers who cannot be reached: the push is the only way
    -- they would find out it is their turn (audit #18). The cursor lands
    -- on the member after the chosen one, so the next turn starts there.
    v_reader := null;
    v_next_pos := null;
    for v_i in 1..v_n loop
      v_cand := v_rot[((v_e.question_reader_index + v_i - 1) % v_n) + 1];
      if exists (
        select 1 from public.device_tokens dt
         where dt.user_id = v_cand and dt.is_active and dt.platform = 'ios'
      ) then
        v_reader := v_cand;
        v_next_pos := ((v_e.question_reader_index + v_i) % v_n);
        exit;
      end if;
    end loop;
    if v_reader is null then
      return null;
    end if;
  end if;
  if v_reader is null then
    return null;
  end if;
  v_q := public.question_box_draw(v_e.room_id, p_event_id);
  if v_q.id is null then
    return null;
  end if;
  -- One live card per event: an unanswered earlier turn is superseded.
  update public.question_turns set superseded_at = p_now
   where event_id = p_event_id and read_at is null and passed_at is null and superseded_at is null;
  insert into public.question_turns (event_id, room_id, reader_id, question_id, question_text, kind, created_at)
  values (p_event_id, v_e.room_id, v_reader, v_q.id, v_q.text, v_kind, p_now)
  returning id into v_turn;
  update public.events
     set question_last_turn_at = p_now,
         question_reader_index = case
           when v_kind = 'interval' then v_next_pos
           else v_e.question_reader_index
         end
   where id = p_event_id;
  return v_turn;
end;
$$;

revoke all on function public.question_box_advance(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.question_box_advance(uuid, timestamptz) to service_role;

comment on function public.question_box_advance(uuid, timestamptz) is
  'S2B: the single writer of question turns. The opener waits for three arrivals or played_at + 30 minutes; the night ends at played_at + rooms.auto_close_hours; the box stops after 60 minutes with no read or pass; and a reader with no active device token is skipped for the next one in the rotation. Never callable by a member (104 keeps it to the service role).';

notify pgrst, 'reload schema';

commit;
