-- 040: M3 — Casino V0.29 settlement surface.
--
-- Closes the audit §11 placeholder where SettleCasinoSheet opens
-- with `withdrawn: 0` because the attestation → withdrawal
-- lookup isn't wired. Adds:
--
--   1. get_my_open_withdrawal(p_event_id) — RPC that returns the
--      calling member's latest open casino_withdrawals row for
--      one event, or NULL if none. Powers the SettleCasinoSheet
--      stepper default so the member sees the actual amount
--      they moved, not 0.
--
--   2. cron_close_unscanned_attestations() — pg_cron-scheduled
--      function that runs every 15 minutes and closes any
--      settlement_attestations row older than 24h that never
--      received a member scan. Marks them as P&L=0 with a
--      "did_not_scan" flag so the ledger stays consistent with
--      the brief's "no-member-scan default = P&L = 0" rule.
--
-- Both functions are read-side or schedule-side; no new tables
-- are introduced (casino_withdrawals + settlement_attestations
-- already exist from migrations 025 + 030).

-- =================================================================
-- 1. get_my_open_withdrawal RPC
-- =================================================================
create or replace function public.get_my_open_withdrawal(p_event_id uuid)
returns public.casino_withdrawals
language sql
stable
security definer
set search_path = public
as $$
    select cw.*
    from public.casino_withdrawals cw
    where cw.session_id = p_event_id
      and cw.member_id = public.current_user_id()
      and not exists (
        select 1 from public.casino_scans cs
        where cs.session_id = cw.session_id
          and cs.member_id = cw.member_id
          and cs.finalized_at is not null
      )
    order by cw.withdrawn_at desc
    limit 1;
$$;

grant execute on function public.get_my_open_withdrawal(uuid) to authenticated;

comment on function public.get_my_open_withdrawal(uuid) is
    'Returns the calling member''s latest open (un-settled) casino_withdrawals row for one event, or NULL if none. Powers the SettleCasinoSheet stepper default.';

-- =================================================================
-- 2. cron_close_unscanned_attestations function
-- =================================================================
create or replace function public.cron_close_unscanned_attestations()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    -- For any settlement_attestations row whose event has been
    -- settled for >= 24h AND the member never submitted a scan
    -- (attested_at IS NULL), mark it as P&L = 0 with a
    -- "did_not_scan" flag so the ledger reflects the brief's
    -- default outcome.
    update public.settlement_attestations sa
    set
        vision_amount_points = 0,
        claimed_amount_points = 0,
        disputed = true,
        attested_at = now(),
        dispute_reason = coalesce(sa.dispute_reason, 'did_not_scan')
    from public.events e
    where sa.session_id = e.id
      and e.settled_at is not null
      and e.settled_at + interval '24 hours' < now()
      and sa.attested_at is null;

    -- No-op if nothing matched. Caller is the pg_cron schedule;
    -- logs surface in supabase.cron.job_run_details.
end;
$$;

grant execute on function public.cron_close_unscanned_attestations() to authenticated;

comment on function public.cron_close_unscanned_attestations() is
    'Closes settlement_attestations rows older than 24h that never received a member scan. Marks them P&L=0, disputed=true. Designed to run on a pg_cron schedule (every 15 min).';

-- =================================================================
-- 3. pg_cron schedule (every 15 minutes)
-- =================================================================
-- pg_cron is the Supabase-recommended scheduler. The schedule is
-- idempotent: re-creating with the same name overwrites the prior
-- schedule. If pg_cron isn't enabled on the project the schedule
-- insert will fail; the function still exists for manual invocation
-- via `select cron_close_unscanned_attestations();`.
do $$
begin
    if exists (select 1 from pg_extension where extname = 'pg_cron') then
        perform cron.schedule(
            'close_unscanned_attestations_15min',
            '*/15 * * * *',
            'select public.cron_close_unscanned_attestations();'
        );
    else
        raise notice 'pg_cron extension not installed; schedule not created. Run cron_close_unscanned_attestations() manually or enable the extension.';
    end if;
end;
$$;