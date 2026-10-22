-- 104_lockdown_internal_functions.sql
-- Security fix (2026-10-22, applied live by TARS on Nathan's approval: "lock it down").
--
-- These SECURITY DEFINER functions are internal: called only by triggers,
-- pg_cron, other SECURITY DEFINER functions (owner postgres) or edge
-- functions using the service role. The default PUBLIC EXECUTE grant was
-- never revoked, so the app's anon key could call them. Worst case:
-- question_turn_push_secret() returned the push shared secret to anyone.
-- The secret was rotated in the same change (vault + edge function env).
--
-- Trigger functions are not EXECUTE-checked when a trigger fires; cron runs
-- as postgres; definer callers run as postgres. Nothing in the app calls
-- these (checked against GamesRoom/ and supabase/functions/).

begin;

do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in (
         'question_turn_push_secret', 'invoke_question_turn_push',
         'question_box_cron_tick', 'cron_close_unscanned_attestations',
         'handle_new_room', 'handle_new_room_question_deck', 'handle_new_user',
         'seed_room_house_deck', 'auto_return_on_settle',
         'mascot_voice_budget_check', 'mascot_voice_budget_record',
         'mascot_captions_last',
         'question_box_advance', 'question_box_draw', 'question_box_rotation'
       )
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$$;

commit;
