-- LIVE definitions pulled 2026-11-08 from project bnrgkdcluopicqdpmrtu via pg_get_functiondef. The live shape is the spec.

-- ===== auto_close_stale_events
CREATE OR REPLACE FUNCTION public.auto_close_stale_events(p_room_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_closed integer := 0;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Member gate: the caller must belong to the room.
  if not exists (
    select 1 from public.room_memberships
    where room_id = p_room_id and user_id = v_caller
  ) then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Close events whose night passed the room's window and were
  -- never settled. The window rides the room row so the host's
  -- Room Settings choice is the single source of truth.
  update public.events e
  set settled_at = now()
  from public.rooms r
  where e.room_id = p_room_id
    and e.settled_at is null
    and e.played_at < now() - make_interval(hours => r.auto_close_hours)
    and r.id = p_room_id;

  get diagnostics v_closed = row_count;
  return v_closed;
end;
$function$


-- ===== auto_return_on_settle
CREATE OR REPLACE FUNCTION public.auto_return_on_settle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_deposit record;
begin
  if new.kind in (
    'seat_deposit', 'seat_deposit_return',
    'seat_deposit_forfeit', 'seat_deposit_waive',
    'no_show_tax', 'no_show_tax_waiver'
  ) then
    return new;
  end if;

  for v_deposit in
    select sd.id, sd.room_id, sd.amount
    from public.seat_deposits sd
    where sd.event_id = new.session_id
      and sd.user_id = new.member_id
      and sd.status = 'held'
  loop
    update public.seat_deposits
      set status = 'returned', returned_at = now(), settled_at = now()
      where id = v_deposit.id;

    if v_deposit.amount > 0 then
      update public.room_memberships
        set points_balance = points_balance + v_deposit.amount
        where room_id = v_deposit.room_id and user_id = new.member_id;

      insert into public.transactions (
        room_id, session_id, member_id, kind, amount_points, meta, created_by
      ) values (
        v_deposit.room_id, new.session_id, new.member_id,
        'seat_deposit_return', v_deposit.amount,
        jsonb_build_object('via', 'settle_proof', 'deposit_id', v_deposit.id),
        new.created_by
      );
    end if;
  end loop;

  return new;
end;
$function$


-- ===== check_in_seat
CREATE OR REPLACE FUNCTION public.check_in_seat(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select sd.id, sd.room_id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = v_caller
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- nothing held: already checked in, waived, or no deposit
  end if;

  update public.seat_deposits
    set status = 'returned', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_deposit.room_id and user_id = v_caller;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_deposit.room_id, p_event_id, v_caller, 'seat_deposit_return', v_deposit.amount,
      jsonb_build_object('via', 'check_in'),
      v_caller
    );
  end if;

  return true;
end;
$function$


-- ===== claim_seat_with_deposit
CREATE OR REPLACE FUNCTION public.claim_seat_with_deposit(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_amount integer;
  v_trigger text;
  v_balance integer;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id, r.seat_deposit_amount, r.seat_deposit_trigger
    into v_room_id, v_amount, v_trigger
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  -- Membership gate: only a room member can claim.
  select m.points_balance into v_balance
  from public.room_memberships m
  where m.room_id = v_room_id and m.user_id = v_caller;

  if v_balance is null then
    raise exception 'Not a member of this room' using errcode = '42501';
  end if;

  -- Idempotent: an existing deposit row of any status means the
  -- claim already happened. No second debit, ever.
  if exists (
    select 1 from public.seat_deposits
    where event_id = p_event_id and user_id = v_caller
  ) then
    return true;
  end if;

  -- Escrow off (or zero amount): plain claim, no deposit row.
  -- The RSVP upsert below is the whole effect.
  if v_amount is null or v_amount = 0 or v_trigger = 'off' then
    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
      values (p_event_id, v_room_id, v_caller, 'claimed', now())
      on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
    return true;
  end if;

  if v_balance < v_amount then
    raise exception 'Balance too low for the seat deposit (% CC needed)', v_amount
      using errcode = '42501';
  end if;

  update public.room_memberships
    set points_balance = points_balance - v_amount
    where room_id = v_room_id and user_id = v_caller;

  insert into public.seat_deposits (event_id, room_id, user_id, amount, status)
    values (p_event_id, v_room_id, v_caller, v_amount, 'held');

  insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room_id, v_caller, 'claimed', now())
    on conflict (event_id, member_id) do update set
      state = excluded.state,
      responded_at = excluded.responded_at;

  insert into public.transactions (
    room_id, session_id, member_id, kind, amount_points, meta, created_by
  ) values (
    v_room_id, p_event_id, v_caller, 'seat_deposit', v_amount,
    jsonb_build_object('direction', 'escrow'),
    v_caller
  );

  return true;
end;
$function$


-- ===== create_event
CREATE OR REPLACE FUNCTION public.create_event(p_room_id uuid, p_name text, p_played_at timestamp with time zone, p_pack_slugs text[], p_hidden_from_user_ids uuid[] DEFAULT '{}'::uuid[])
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_event_id uuid;
    v_caller uuid := public.current_user_id();
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;
    if not exists (
        select 1 from public.rooms
        where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
    ) then
        raise exception 'Only the host can create events' using errcode = '42501';
    end if;
    if p_pack_slugs is null or array_length(p_pack_slugs, 1) = 0 then
        raise exception 'At least one pack required' using errcode = '22023';
    end if;
    if exists (
        select 1 from unnest(p_pack_slugs) as s(slug)
        where not exists (select 1 from public.packs where slug = s.slug)
    ) then
        raise exception 'Unknown pack in p_pack_slugs' using errcode = 'P0002';
    end if;

    insert into public.events (room_id, name, played_at, pack_slug, created_by)
    values (p_room_id, p_name, p_played_at, p_pack_slugs[1], v_caller)
    returning id into v_event_id;

    insert into public.event_packs (event_id, pack_slug)
    select v_event_id, unnest(p_pack_slugs);

    -- V0.94 hidden members ride along unchanged.
    update public.events
    set hidden_from_user_ids = p_hidden_from_user_ids
    where id = v_event_id;

    return v_event_id;
end;
$function$


-- ===== delete_event
CREATE OR REPLACE FUNCTION public.delete_event(p_event_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can delete events' using errcode = '42501';
  end if;

  delete from public.event_packs where event_id = p_event_id;
  delete from public.events where id = p_event_id;

  return true;
end;
$function$


-- ===== forfeit_seat_deposit
CREATE OR REPLACE FUNCTION public.forfeit_seat_deposit(p_event_id uuid, p_member_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can forfeit a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'forfeited', forfeited_at = now(), forfeited_by = v_caller, settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_forfeit', v_deposit.amount,
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$function$


-- ===== get_active_event
CREATE OR REPLACE FUNCTION public.get_active_event(p_room_id uuid)
 RETURNS TABLE(id uuid, room_id uuid, name text, played_at timestamp with time zone, created_at timestamp with time zone, host_note text, pack_slug text, settled_at timestamp with time zone, max_seats integer, pack_slugs text[])
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if not (public.rpc_caller_trusted() or public.is_room_member(p_room_id, public.current_user_id())) then
    return;
  end if;
  return query select * from public.get_active_event__inner(p_room_id);
end;
$function$


-- ===== get_active_event__inner
CREATE OR REPLACE FUNCTION public.get_active_event__inner(p_room_id uuid)
 RETURNS TABLE(id uuid, room_id uuid, name text, played_at timestamp with time zone, created_at timestamp with time zone, host_note text, pack_slug text, settled_at timestamp with time zone, max_seats integer, pack_slugs text[])
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    select e.id, e.room_id, e.name, e.played_at, e.created_at,
           e.host_note, e.pack_slug, e.settled_at, r.max_seats,
           coalesce(
               (select array_agg(ep.pack_slug order by ep.pack_slug)
                from public.event_packs ep
                where ep.event_id = e.id),
               array[e.pack_slug]
           ) as pack_slugs
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.room_id = p_room_id
      and e.played_at > now()
    order by e.played_at asc
    limit 1;
$function$


-- ===== is_room_host
CREATE OR REPLACE FUNCTION public.is_room_host(p_room_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1 from public.room_memberships
    where room_id = p_room_id
      and user_id = p_user_id
      and role = 'host'
      and membership_status = 'active'
  );
$function$


-- ===== is_room_member
CREATE OR REPLACE FUNCTION public.is_room_member(p_room_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select exists (
    select 1 from public.room_memberships m
    where m.room_id = p_room_id
      and m.user_id = public.current_user_id()
  );
$function$


-- ===== is_room_member
CREATE OR REPLACE FUNCTION public.is_room_member(p_room_id uuid, p_user_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (select 1 from public.room_memberships
                  where room_id = p_room_id and user_id = p_user_id
                    and membership_status = 'active');
$function$


-- ===== leave_room
CREATE OR REPLACE FUNCTION public.leave_room(p_room_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_caller_role text;
  v_remaining_hosts int;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- Caller must be an active member of this room. Kicked members
  -- have already "left" in the user-visible sense; leave_room is a
  -- no-op for them (the room doesn't appear in their list anyway).
  select m.role into v_caller_role
  from public.room_memberships m
  where m.room_id = p_room_id
    and m.user_id = v_caller
    and m.membership_status = 'active';

  if v_caller_role is null then
    -- Not a member, or already kicked. Idempotent.
    return true;
  end if;

  -- Last-host guard (matching 091's transfer_host_role).
  if v_caller_role = 'host' then
    select count(*) into v_remaining_hosts
    from public.room_memberships
    where room_id = p_room_id
      and role = 'host'
      and membership_status = 'active'
      and user_id <> v_caller;
    if v_remaining_hosts < 1 then
      raise exception 'last_host: a room must always have at least one host'
        using errcode = 'P0001';
    end if;
  end if;

  -- Members leave freely. Hosts leave only when ≥1 other active host
  -- remains. Invariant 1 still holds: leave_room is the ONLY path
  -- that deletes a row from room_memberships (kick preserves the row).
  delete from public.room_memberships
    where room_id = p_room_id
      and user_id = v_caller;

  return true;
end;
$function$


-- ===== list_arrival_candidates
CREATE OR REPLACE FUNCTION public.list_arrival_candidates(p_event_id uuid)
 RETURNS TABLE(user_id uuid, display_name text, deposit_amount integer, status text, within_grace boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with event_row as (
    select e.id, e.room_id, e.played_at, r.created_by,
           r.seat_deposit_grace_minutes
    from public.events e
    join public.rooms r on r.id = e.room_id
    where e.id = p_event_id
  ),
  unresolved as (
    select sd.user_id, sd.amount, sd.status::text as status
    from public.seat_deposits sd
    where sd.event_id = p_event_id
      and sd.status = 'held'
      and not exists (
        select 1 from public.transactions t
        where t.session_id = p_event_id
          and t.member_id = sd.user_id
          and t.kind not in (
            'seat_deposit', 'seat_deposit_return',
            'seat_deposit_forfeit', 'seat_deposit_waive',
            'no_show_tax', 'no_show_tax_waiver'
          )
      )
  )
  select
    u.id as user_id,
    coalesce(u.display_name, 'Member') as display_name,
    un.amount as deposit_amount,
    un.status,
    (now() < event_row.played_at + make_interval(mins => event_row.seat_deposit_grace_minutes)) as within_grace
  from unresolved un
  cross join event_row
  join public.users u on u.id = un.user_id
  where public.is_room_host(event_row.room_id, public.current_user_id());
$function$


-- ===== question_box_advance
CREATE OR REPLACE FUNCTION public.question_box_advance(p_event_id uuid, p_now timestamp with time zone DEFAULT now())
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_e record;
  v_rot uuid[];
  v_reader uuid;
  v_kind text;
  v_q public.room_questions;
  v_turn uuid;
  v_has_turns boolean;
begin
  select e.id, e.room_id, e.played_at, e.settled_at, e.question_reader_index,
         e.question_last_turn_at, r.question_box_enabled, r.question_cadence_minutes,
         r.deleted_at
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
  select exists (select 1 from public.question_turns t where t.event_id = p_event_id) into v_has_turns;
  if not v_has_turns then
    v_kind := 'opener';
    v_reader := public.question_box_host(v_e.room_id);
  else
    if v_e.question_cadence_minutes = 0 or v_e.question_last_turn_at is null
       or p_now < v_e.question_last_turn_at + make_interval(mins => v_e.question_cadence_minutes) then
      return null;
    end if;
    v_rot := public.question_box_rotation(p_event_id);
    if cardinality(v_rot) = 0 then
      return null;
    end if;
    v_kind := 'interval';
    v_reader := v_rot[(v_e.question_reader_index % cardinality(v_rot)) + 1];
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
         question_reader_index = question_reader_index + case when v_kind = 'interval' then 1 else 0 end
   where id = p_event_id;
  return v_turn;
end;
$function$


-- ===== question_box_host
CREATE OR REPLACE FUNCTION public.question_box_host(p_room_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select coalesce(
    (select r.created_by from public.rooms r
      where r.id = p_room_id and public.is_room_host(r.id, r.created_by)),
    (select m.user_id from public.room_memberships m
      where m.room_id = p_room_id and m.role = 'host' and m.membership_status = 'active'
      order by m.joined_at limit 1)
  );
$function$


-- ===== record_round_score
CREATE OR REPLACE FUNCTION public.record_round_score(p_room_id uuid, p_event_id uuid, p_pack_slug text, p_round_index integer, p_entries jsonb DEFAULT '[]'::jsonb, p_correction_of uuid DEFAULT NULL::uuid)
 RETURNS TABLE(id uuid, room_id uuid, event_id uuid, round_index integer, pack_slug text, created_at timestamp with time zone, correction_of uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_submission_id uuid;
  v_old_entries jsonb;
  v_entry jsonb;
  v_member_id uuid;
  v_points_delta bigint;
  v_meta jsonb;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = p_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can record a round' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.events
    where id = p_event_id and room_id = p_room_id
  ) then
    raise exception 'Event does not belong to room' using errcode = 'P0002';
  end if;

  -- Capture the existing entries BEFORE the upsert replaces the row.
  -- Null for a fresh round; the reverse loop is a no-op in that case.
  select rs.entries into v_old_entries
  from public.round_submissions rs
  where rs.room_id = p_room_id
    and rs.event_id = p_event_id
    and rs.round_index = p_round_index;

  insert into public.round_submissions (
    room_id, event_id, pack_slug, round_index, entries, created_by, correction_of
  ) values (
    p_room_id, p_event_id, p_pack_slug, p_round_index, p_entries, v_caller, p_correction_of
  )
  on conflict (room_id, event_id, round_index) do update
    set entries = excluded.entries,
        pack_slug = excluded.pack_slug,
        created_by = excluded.created_by,
        correction_of = excluded.correction_of,
        created_at = now()
  returning id into v_submission_id;

  -- Reverse the old deltas first so the new deltas land on a clean
  -- season_score. Reverse + delete ordering matches migration 035's
  -- "delete then apply" flow inverted: here we replace, so we must
  -- subtract before we add.
  for v_entry in select * from jsonb_array_elements(coalesce(v_old_entries, '[]'::jsonb))
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;

    update public.room_memberships
      set season_score = season_score - v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  delete from public.transactions
    where room_id = p_room_id
      and session_id = p_event_id
      and (meta->>'round_index')::integer = p_round_index;

  for v_entry in select * from jsonb_array_elements(p_entries)
  loop
    v_member_id := (v_entry->>'member_id')::uuid;
    v_points_delta := (v_entry->>'points_delta')::bigint;
    v_meta := coalesce(v_entry->'meta', '{}'::jsonb) || jsonb_build_object(
      'submission_id', v_submission_id,
      'round_index', p_round_index,
      'pack_slug', p_pack_slug,
      'correction_of', p_correction_of
    );

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      p_room_id, p_event_id, v_member_id, 'round_score', v_points_delta, v_meta, v_caller
    );

    update public.room_memberships
      set season_score = season_score + v_points_delta
      where user_id = v_member_id and room_id = p_room_id;
  end loop;

  return query
    select v_submission_id, p_room_id, p_event_id, p_round_index,
           p_pack_slug, now(), p_correction_of;
end;
$function$


-- ===== update_event_member_fields
CREATE OR REPLACE FUNCTION public.update_event_member_fields(p_event_id uuid, p_note text, p_venue text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_played_at timestamptz;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  -- F-IDENT-01: room scope derives from the event, never from the
  -- caller's membership claim.
  select room_id, played_at into v_room_id, v_played_at
  from public.events
  where id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.room_memberships rm
    where rm.room_id = v_room_id and rm.user_id = v_caller
  ) then
    raise exception 'Only room members can edit event details' using errcode = '42501';
  end if;

  if v_played_at <= now() then
    raise exception 'Event details can only be edited before play starts' using errcode = '22023';
  end if;

  update public.events
    set host_note = nullif(trim(p_note), ''),
        venue = nullif(trim(p_venue), '')
  where id = p_event_id;

  return true;
end;
$function$


-- ===== update_event_played_at
CREATE OR REPLACE FUNCTION public.update_event_played_at(p_event_id uuid, p_played_at timestamp with time zone)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
declare
  v_caller  uuid := public.current_user_id();
  v_room_id uuid;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select room_id into v_room_id from public.events where id = p_event_id;
  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms
    where id = v_room_id and (created_by = v_caller OR public.is_room_host(id, v_caller))
  ) then
    raise exception 'Only the host can change event dates'
      using errcode = '42501';
  end if;

  if p_played_at <= now() then
    raise exception 'Events must be in the future' using errcode = '22023';
  end if;

  update public.events
  set played_at = p_played_at
  where id = p_event_id;

  return true;
end;
$function$


-- ===== upsert_event_rsvp
CREATE OR REPLACE FUNCTION public.upsert_event_rsvp(p_event_id uuid, p_state text, p_target_member_id uuid DEFAULT NULL::uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_caller uuid := auth.uid();
    v_target uuid := coalesce(p_target_member_id, v_caller);
    v_room uuid;
begin
    if v_caller is null then
        raise exception 'Not authenticated' using errcode = '42501';
    end if;

    if v_target <> v_caller then
        select e.room_id into v_room
        from public.events e
        join public.rooms r on r.id = e.room_id
        where e.id = p_event_id and public.is_room_host(r.id, v_caller);
        if v_room is null then
            raise exception 'Only the host can update another member''s RSVP'
                using errcode = '42501';
        end if;
    else
        select e.room_id into v_room
        from public.events e
        where e.id = p_event_id;
    end if;

    if v_room is null then
        raise exception 'Event not found' using errcode = 'P0002';
    end if;

    insert into public.event_rsvps (event_id, room_id, member_id, state, responded_at)
    values (p_event_id, v_room, v_target, p_state::event_rsvp_state, now())
    on conflict (event_id, member_id) do update set
        state = excluded.state,
        responded_at = excluded.responded_at;
end;
$function$


-- ===== waive_seat_deposit
CREATE OR REPLACE FUNCTION public.waive_seat_deposit(p_event_id uuid, p_member_id uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_caller uuid := public.current_user_id();
  v_room_id uuid;
  v_deposit record;
begin
  if v_caller is null then
    raise exception 'Not authenticated' using errcode = '42501';
  end if;

  select e.room_id into v_room_id
  from public.events e
  join public.rooms r on r.id = e.room_id
  where e.id = p_event_id;

  if v_room_id is null then
    raise exception 'Event not found' using errcode = 'P0002';
  end if;

  if not exists (
    select 1 from public.rooms r
    where r.id = v_room_id and (r.created_by = v_caller OR public.is_room_host(r.id, v_caller))
  ) then
    raise exception 'Only the host can waive a seat deposit' using errcode = '42501';
  end if;

  select sd.id, sd.amount into v_deposit
  from public.seat_deposits sd
  where sd.event_id = p_event_id
    and sd.user_id = p_member_id
    and sd.status = 'held'
  limit 1;

  if v_deposit is null then
    return true; -- already resolved: idempotent
  end if;

  update public.seat_deposits
    set status = 'waived', returned_at = now(), settled_at = now()
    where id = v_deposit.id;

  if v_deposit.amount > 0 then
    update public.room_memberships
      set points_balance = points_balance + v_deposit.amount
      where room_id = v_room_id and user_id = p_member_id;

    insert into public.transactions (
      room_id, session_id, member_id, kind, amount_points, meta, created_by
    ) values (
      v_room_id, p_event_id, p_member_id, 'seat_deposit_waive', v_deposit.amount,
      jsonb_build_object('deposit_id', v_deposit.id),
      v_caller
    );
  end if;

  return true;
end;
$function$


