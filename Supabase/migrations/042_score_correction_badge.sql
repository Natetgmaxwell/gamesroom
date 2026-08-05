-- 042: F-MVP-11 — Score correction visibility.
--
-- Adds `correction_of uuid` to `round_submissions` so a host can
-- mark a re-submission as correcting a prior round. The leaderboard
-- RPC surfaces `score_corrected_at` so the iOS row can render a 60s
-- amber dot on the affected member.
--
-- Apply via:
--   PGPASSWORD='...' psql -h <host> -p 6543 -U postgres -d postgres \
--     -v ON_ERROR_STOP=1 -f Supabase/migrations/042_score_correction_badge.sql

-- 1. Column on round_submissions. Nullable; null = original submission.
alter table public.round_submissions
  add column if not exists correction_of uuid
  references public.round_submissions(id) on delete set null;

-- 2. Extend record_round_score with p_correction_of. DROP + CREATE
--    because the RETURNS TABLE shape changes (Postgres won't let us
--    CREATE OR REPLACE with a different column list — error 42P13).
drop function if exists public.record_round_score(uuid, uuid, text, integer, jsonb);
create function public.record_round_score(
  p_room_id uuid,
  p_event_id uuid,
  p_pack_slug text,
  p_round_index integer,
  p_entries jsonb default '[]'::jsonb,
  p_correction_of uuid default null
)
returns table (
  id uuid,
  room_id uuid,
  event_id uuid,
  round_index integer,
  pack_slug text,
  created_at timestamptz,
  correction_of uuid
)
language plpgsql
security definer
as $$
declare
  v_caller uuid := public.current_user_id();
  v_submission_id uuid;
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
    where id = p_room_id and created_by = v_caller
  ) then
    raise exception 'Only the host can record a round' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.events
    where id = p_event_id and room_id = p_room_id
  ) then
    raise exception 'Event does not belong to room' using errcode = 'P0002';
  end if;

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
$$;

grant execute on function public.record_round_score(
  uuid, uuid, text, integer, jsonb, uuid
) to authenticated;

-- 3. Extend get_room_leaderboard to surface score_corrected_at —
--    the created_at of the most recent correction submission that
--    touched this member's transactions in the current season.
--    The iOS row checks if this is within 60s of now and renders
--    an amber dot.
drop function if exists public.get_room_leaderboard(uuid);
create function public.get_room_leaderboard(p_room_id uuid)
returns table (
  user_id uuid,
  display_name text,
  role text,
  points_balance bigint,
  season_score bigint,
  sessions_played bigint,
  last_session_at timestamptz,
  last_session_delta bigint,
  trajectory jsonb,
  score_corrected_at timestamptz
)
language sql
security definer
stable
as $$
  with
  session_deltas as (
    select
      t.member_id,
      t.session_id,
      sum(t.amount_points)::bigint as delta,
      max(t.created_at) as created_at
    from public.transactions t
    join public.room_memberships m
      on m.user_id = t.member_id and m.room_id = t.room_id
    where t.room_id = p_room_id
      and t.kind = 'casino_settlement'
      and t.session_id is not null
    group by t.member_id, t.session_id
  ),
  recent_per_member as (
    select
      sd.member_id,
      sd.session_id,
      sd.delta,
      sd.created_at,
      row_number() over (partition by sd.member_id order by sd.created_at desc) as rn
    from session_deltas sd
  ),
  trajectory_per_member as (
    select
      rpm.member_id,
      jsonb_agg(
        jsonb_build_object('session_id', rpm.session_id, 'delta', rpm.delta)
        order by rpm.created_at asc
      ) as trajectory
    from recent_per_member rpm
    where rpm.rn <= 7
    group by rpm.member_id
  ),
  aggregates_per_member as (
    select
      sd.member_id,
      count(*) as sessions_played,
      max(sd.created_at) as last_session_at
    from session_deltas sd
    group by sd.member_id
  ),
  last_delta_per_member as (
    select distinct on (sd.member_id)
      sd.member_id,
      sd.delta as last_session_delta
    from session_deltas sd
    order by sd.member_id, sd.created_at desc
  ),
  -- The most recent correction submission that wrote a transaction
  -- for this member in this room. Joins through transactions.meta
  -- to round_submissions.correction_of; non-null correction_of means
  -- the host re-scored this member's round.
  corrections_per_member as (
    select distinct on (t.member_id)
      t.member_id,
      rs.created_at as score_corrected_at
    from public.transactions t
    join public.round_submissions rs
      on (t.meta->>'submission_id')::uuid = rs.id
    where t.room_id = p_room_id
      and rs.correction_of is not null
    order by t.member_id, rs.created_at desc
  )
  select
    m.user_id,
    coalesce(u.display_name, 'Member') as display_name,
    m.role::text as role,
    m.points_balance,
    m.season_score,
    coalesce(aggr.sessions_played, 0) as sessions_played,
    aggr.last_session_at,
    coalesce(ld.last_session_delta, 0) as last_session_delta,
    coalesce(trajectory.trajectory, '[]'::jsonb) as trajectory,
    corrections.score_corrected_at
  from public.room_memberships m
  join public.users u on u.id = m.user_id
  left join aggregates_per_member aggr on aggr.member_id = m.user_id
  left join last_delta_per_member ld on ld.member_id = m.user_id
  left join trajectory_per_member trajectory on trajectory.member_id = m.user_id
  left join corrections_per_member corrections on corrections.member_id = m.user_id
  where m.room_id = p_room_id
  order by case when m.role = 'host' then 0 else 1 end,
           m.season_score desc,
           u.display_name asc;
$$;

grant execute on function public.get_room_leaderboard(uuid) to authenticated;
