-- Contract probes for the store/server boundary (task F+H, step F3).
--
-- Runs against the schema-replica harness only — never the live DB.
-- Every check prints one greppable line:  PROBE <id> PASS|FAIL
--
--   psql "$REPLICA_URL" -v ON_ERROR_STOP=0 -f supabase/probes/contract-rls-probes.sql
--
-- Covers three contracts the client currently mirrors or defensively re-checks:
--   a. get_season_awards drowning read set          (048:56-98; 045 read set)
--   b. get_current_season prefers an 'ended' season (048:17-38)
--   c. auto_close_stale_events is idempotent        (115:783-836)
--
-- Impersonation uses the project's JWT-claim convention, exactly as the
-- other probe files do: current_user_id() reads request.jwt.claims->>'sub'.
-- The whole file runs in one transaction so the transaction-local claim
-- set_config(..., true) persists across statements; it rolls back at the end.

\set ON_ERROR_STOP 0

begin;

create or replace function pg_temp.act(u uuid) returns void
language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', u, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', u::text, true);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures
--   f01 host, f02 drowning recipient, f03 plain member (non-host, not opted
--   in), f04 member who opted in to the drowning share.
--   Season e11 is 'ended' at ordinal 1; season e12 is 'active' at ordinal 2,
--   so a naive "latest ordinal" read would wrongly pick e12.
-- ---------------------------------------------------------------------------
insert into auth.users(id) values
  ('00000000-0000-0000-0000-000000000f01'),
  ('00000000-0000-0000-0000-000000000f02'),
  ('00000000-0000-0000-0000-000000000f03'),
  ('00000000-0000-0000-0000-000000000f04')
on conflict do nothing;

insert into public.users(id, display_name) values
  ('00000000-0000-0000-0000-000000000f01', 'Host'),
  ('00000000-0000-0000-0000-000000000f02', 'Recipient'),
  ('00000000-0000-0000-0000-000000000f03', 'Plain'),
  ('00000000-0000-0000-0000-000000000f04', 'Opted')
on conflict do nothing;

insert into public.rooms
  (id, name, mascot_name, created_by, max_seats, seat_deposit_amount,
   seat_deposit_trigger, auto_close_hours)
values
  ('00000000-0000-0000-0000-000000000e01', 'Probe Room', 'Tally',
   '00000000-0000-0000-0000-000000000f01', 4, 200, 'escrow', 8)
on conflict do nothing;

insert into public.room_memberships
  (room_id, user_id, role, points_balance, membership_status,
   member_drowning_opt_in)
values
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f01', 'host',   500, 'active', false),
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f02', 'member', 500, 'active', false),
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f03', 'member', 500, 'active', false),
  ('00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f04', 'member', 500, 'active', true)
on conflict (room_id, user_id) do update
  set membership_status = excluded.membership_status,
      member_drowning_opt_in = excluded.member_drowning_opt_in;

insert into public.seasons(id, room_id, ordinal, status, ended_at) values
  ('00000000-0000-0000-0000-000000000e11', '00000000-0000-0000-0000-000000000e01', 1, 'ended',  now()),
  ('00000000-0000-0000-0000-000000000e12', '00000000-0000-0000-0000-000000000e01', 2, 'active', null)
on conflict (room_id, ordinal) do nothing;

insert into public.season_awards
  (id, season_id, room_id, member_id, recipient_user_id, recipient_display_name,
   award_type, caption)
values
  ('00000000-0000-0000-0000-000000000a01', '00000000-0000-0000-0000-000000000e11', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-000000000f02', 'Recipient', 'drowning', 'took the dive'),
  ('00000000-0000-0000-0000-000000000a02', '00000000-0000-0000-0000-000000000e11', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f03', '00000000-0000-0000-0000-000000000f03', 'Plain',     'drowning', 'also dove'),
  ('00000000-0000-0000-0000-000000000a03', '00000000-0000-0000-0000-000000000e11', '00000000-0000-0000-0000-000000000e01', '00000000-0000-0000-0000-000000000f02', '00000000-0000-0000-0000-000000000f02', 'Recipient', 'phoenix',  'rose again')
on conflict (season_id, recipient_user_id, award_type) do nothing;

insert into public.events(id, room_id, name, played_at, created_by) values
  ('00000000-0000-0000-0000-000000000d01', '00000000-0000-0000-0000-000000000e01',
   'Stale night', now() - interval '9 hours', '00000000-0000-0000-0000-000000000f01')
on conflict do nothing;

-- ===========================================================================
-- a. get_season_awards drowning read set
-- ===========================================================================

-- a1: the recipient reads their own drowning row.
select pg_temp.act('00000000-0000-0000-0000-000000000f02');
select 'PROBE FH.a.recipient-own ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
  where award_type = 'drowning'
    and recipient_user_id = '00000000-0000-0000-0000-000000000f02'
) = 1 then 'PASS' else 'FAIL' end;

-- a2: a non-recipient plain member sees none of the recipient's drowning rows.
select pg_temp.act('00000000-0000-0000-0000-000000000f03');
select 'PROBE FH.a.non-recipient-blocked ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
  where award_type = 'drowning'
    and recipient_user_id = '00000000-0000-0000-0000-000000000f02'
) = 0 then 'PASS' else 'FAIL' end;

-- a3: the host sees both drowning rows (migration 045 read set).
select pg_temp.act('00000000-0000-0000-0000-000000000f01');
select 'PROBE FH.a.host-reads ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
  where award_type = 'drowning'
) = 2 then 'PASS' else 'FAIL' end;

-- a4: an opted-in member sees both drowning rows (migration 045 read set).
select pg_temp.act('00000000-0000-0000-0000-000000000f04');
select 'PROBE FH.a.opt-in-reads ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
  where award_type = 'drowning'
) = 2 then 'PASS' else 'FAIL' end;

-- a5: non-drowning awards stay visible to every member.
select pg_temp.act('00000000-0000-0000-0000-000000000f03');
select 'PROBE FH.a.non-drowning-visible ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
  where award_type = 'phoenix'
) = 1 then 'PASS' else 'FAIL' end;

-- a6: a non-member reads no awards at all (membership guard).
select pg_temp.act('00000000-0000-0000-0000-000000000f99');
select 'PROBE FH.a.non-member-none ' || case when (
  select count(*) from public.get_season_awards('00000000-0000-0000-0000-000000000e11')
) = 0 then 'PASS' else 'FAIL' end;

-- ===========================================================================
-- b. get_current_season: ended beats a newer active season
-- ===========================================================================

select pg_temp.act('00000000-0000-0000-0000-000000000f03');
select 'PROBE FH.b.ended-over-active ' || case when (
  select id from public.get_current_season('00000000-0000-0000-0000-000000000e01')
) = '00000000-0000-0000-0000-000000000e11'::uuid then 'PASS' else 'FAIL' end;

-- b2: a non-member gets no season.
select pg_temp.act('00000000-0000-0000-0000-000000000f99');
-- get_current_season returns a single composite row (RETURNS seasons), so count(*) is always 1;
-- the boundary check is whether the row's id is null for a non-member.
select 'PROBE FH.b.non-member-none ' || case when (
  select s.id from public.get_current_season('00000000-0000-0000-0000-000000000e01') s
) is null then 'PASS' else 'FAIL' end;

-- ===========================================================================
-- c. auto_close_stale_events is idempotent
-- ===========================================================================

update public.events set settled_at = null
where id = '00000000-0000-0000-0000-000000000d01';

select pg_temp.act('00000000-0000-0000-0000-000000000f03');

-- c1: the first call closes exactly the one stale night.
select 'PROBE FH.c.first-close ' || case when
  public.auto_close_stale_events('00000000-0000-0000-0000-000000000e01') = 1
then 'PASS' else 'FAIL' end;

-- c2: settled_at is stamped at played_at + the room's auto_close_hours.
select 'PROBE FH.c.settled-at ' || case when (
  select settled_at from public.events
  where id = '00000000-0000-0000-0000-000000000d01'
) = (
  select played_at + interval '8 hours' from public.events
  where id = '00000000-0000-0000-0000-000000000d01'
) then 'PASS' else 'FAIL' end;

-- c3: the second call closes nothing.
select 'PROBE FH.c.second-close ' || case when
  public.auto_close_stale_events('00000000-0000-0000-0000-000000000e01') = 0
then 'PASS' else 'FAIL' end;

-- c4: the second call leaves settled_at untouched.
select 'PROBE FH.c.stable ' || case when (
  select settled_at from public.events
  where id = '00000000-0000-0000-0000-000000000d01'
) = (
  select played_at + interval '8 hours' from public.events
  where id = '00000000-0000-0000-0000-000000000d01'
) then 'PASS' else 'FAIL' end;

rollback;
