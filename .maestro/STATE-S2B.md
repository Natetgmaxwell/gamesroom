# STATE S2B

STATE: step 2 of 7 done. Next: step 3 (briefing-push edge function).

Step 2 (S2B.2: briefing push ledger, due query and cron tick) committed as a3126a9.
- Supabase/migrations/109_briefing_push.sql (new). Not applied to live. Requires 108 (rooms.time_zone) first.
- public.briefing_push_ledger(event_id, user_id, kind, sent_at default now()), primary key (event_id, user_id, kind). RLS on, no client policies, revoke from public/anon/authenticated, grant all to service_role. The key is the once-per-slot rule.
- public.briefing_push_due(p_now timestamptz) returns table(event_id, room_id, user_id, kind, rsvp_state, event_name, played_at, host_note, time_zone, mascot_name). plpgsql-free, language sql, stable, security definer, set search_path = public.
- public.briefing_push_secret() reads vault secret 'briefing_push_secret' (null when the vault schema is absent).
- public.briefing_push_cron_tick() reads the due rows and posts them to the briefing-push edge function over pg_net with the shared secret header 'X-Briefing-Push-Secret', in batches of 200 rows per request. Fail closed: no pg_net or no secret means no send and no consumed slot.
- cron.schedule('briefing-push-tick', '*/15 * * * *', 'select public.briefing_push_cron_tick();') inside a do block guarded on the pg_cron extension (097 pattern), so it is safe to re-apply.
- Slots, all computed in the room time zone: on_create (created in the last 60 min, non-host, unclaimed only), t168h (7 days before the event day at 18:00), t48h (3 days before at 18:00), morning_of (earlier of 09:00 on the day and played_at - 3h, floored at 07:00), host_headcount (the t48h slot, to each host).
- Skip rules: a slot is due when its time is in (p_now - 20 min, p_now]; t168h and t48h are skipped within 24h after created_at; morning_of within 2h after created_at; t48h within 24h of t168h.
- Eligibility: active membership, room notifications enabled, event not muted, not hidden, event unsettled and in the future, rsvp not declined, no ledger row yet, the member has an active device token.
- The mute table is event_rsvps.notifications_muted (added 066, fixed 078), not a table of its own.
- Gate: bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases passed, parse-check pass=64). No function directory touched, so no deno gate this step. The SQL itself was parsed with pglast (the real PostgreSQL grammar) in a throwaway venv outside the repo: the whole file and the briefing_push_due body both parse clean. No postgres is installed on this machine, so the migration was not executed.
- Deliberate choices, all recorded here for TARS:
  1. host_headcount rides the t48h slot and therefore inherits that slot's skip rules. When t48h is skipped (the event was created less than 24h before the slot) there is no headcount either, because the host knows the headcount of a night they just created. The other reading, send the headcount anyway, is one line to change.
  2. Hosts are eligible for t168h, t48h and morning_of like any other member, because the brief's eligibility list has no host exclusion (only on_create says non-host). The client behaves the same way today. The consequence is that a host who has claimed gets a logistics push at the t48h slot AND the headcount at the t48h slot. That double ping is the one taste decision in this step; flipping it means excluding hosts from the t48h member slot.
  3. The host headcount inherits the whole eligibility list, so a host who has room notifications off (the default, since 066) gets no headcount. That is the brief's rule applied uniformly.
  4. briefing_push_secret() is NOT granted to authenticated. Migration 104 revoked EXECUTE on the same shape of reader (question_turn_push_secret) from the app roles precisely because it hands the push secret to anyone who can call it. This is a deliberate deviation from the blanket rule 6, and it is the one function in the lane that breaks it.
  5. briefing_push_due IS granted to authenticated per rule 6, so it is scoped with rpc_caller_trusted() or is_room_member(room_id, current_user_id()): the cron and the service role see every room, an app user sees only the rooms they are in. A tick an app user triggers also carries that user's JWT, so it only covers their own rooms.
  6. The cron payload carries the due rows; the edge function writes the ledger row before it sends (brief step 3), which is what makes a repeated tick a no-op.
  7. The due window is 20 minutes against a 15 minute cron, so every slot is caught by exactly one tick. on_create has its own 60 minute window so a creation that lands between two ticks is not missed.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
