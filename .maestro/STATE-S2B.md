# STATE S2B

STATE: step 4 of 7 done. Next: step 5 (111 Question Box timing).

Step 4 (S2B.4: anchor push waits for waking hours) committed as 284bb7f.
- Supabase/migrations/110_anchor_push_waking_hours.sql (new). Not applied to live.
- Supabase/functions/anchor-nudge-push/{handler.ts,index.ts,handler_test.ts} (modified).
  The function dir is tracked under the LOWERCASE path (see gotchas).
- The failure it kills (audit 01-notifications #13): a newcomer claims at 11:40pm and the
  inviter's phone lights up with a time-sensitive "Sam's coming Friday. Are you?" - at an
  hour the inviter cannot act on it, through a Focus mode they chose, for a night days away.

The SQL (110)
- public.queue_anchor_nudge is replaced. Every rule from 105 is unchanged (claimed seat for
  the newcomer, first three nights only, inviter an ACTIVE member, both switches on, inviter
  not already seated, event not started, once per newcomer per event, fail closed on no
  pg_net / no vault secret). Two things are new:
    1. the row is written with push_status 'queued' and the push is posted only when the
       ROOM's local clock is inside 09:00-20:00. Outside the window the row stays queued and
       the cron delivers it at the next window.
    2. a claim inside the last 24 hours is not queued at all: played_at - 24h is the
       delivery deadline, and inside a day of the night there is no time to act on the nudge.
- public.anchor_push_in_window(p_room_id, p_at): 09:00 to 20:00 in rooms.time_zone
  (migration 108). Half open: 09:00 is inside, 20:00 is not. Read per room, never UTC and
  never a hardcoded Australian zone.
- public.anchor_push_due(p_now): the queued rows that are deliverable now - inside the
  window, the night not started, played_at - 24h not passed, the room not deleted. Capped
  at 200 rows a tick. Trusted callers see every room, an app user only their own rooms
  (the same guard shape as 109's briefing_push_due).
- public.anchor_push_cron_tick(): expires the rows whose T-24h mark has passed, then posts
  the due rows to the edge function over pg_net with the vault secret. No pg_net or no
  secret means no send and the rows stay queued for the next tick.
- cron job 'anchor-push-tick' every 15 minutes.
- public.anchor_push_post(event_id, newcomer_user_id): the one place that knows how to
  post to the edge function. Used by the trigger (inside the window) and the cron.

The edge function
- The row is CLAIMED before the send: a conditional UPDATE queued -> sending. The trigger
  and the cron can both post the same row, and only the request that wins the claim may
  send it. That is the only new state; the ledger key still stops a second queue.
- The disabled check comes BEFORE the claim, so a function that is off does not take the
  row: it stays queued and the cron retries it once the feature is switched on.
- The seat re-check at send time: the inviter's RSVP is re-read before the send, and a
  nudge for an inviter who has claimed a seat since the queue is dropped (skipped_seated).
  Only the inviter is asked about, never the newcomer.
- The interruption level is "active", not "time-sensitive". The nudge is for a night days
  away, so it must not break through Focus or Sleep.
- The weekday is read in the room's own zone (rooms.time_zone). The hardcoded
  Australia/Brisbane is gone from this function. An unreadable or unknown zone falls back
  to UTC, never to Australia/Brisbane.
- push_status values now: queued -> sending -> sent / failed / no_device /
  skipped_started / skipped_seated, plus expired from the cron.
- Gates: bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases passed, parse-check pass=64).
  deno check Supabase/functions/anchor-nudge-push/ -> clean. deno test -> 22 passed, 0 failed
  (was 15). deno lint -> 2 no-import-prefix findings, the two pre-existing https imports
  (esm.sh, deno.land) that were there before this step.

Deliberate choices, all recorded here for TARS:
  1. The trigger still posts immediately when the room is inside its waking hours; only the
     out-of-window case queues for the cron. The brief says "the trigger queues instead of
     sending when the room-local time is outside 09:00-20:00", so inside the window the
     push is not delayed by up to 15 minutes.
  2. The edge function claims the row rather than the sender flipping a status. A trigger
     post and a cron post for the same row can both be in flight; the conditional UPDATE
     is the arbiter, and it lives where the send lives.
  3. The T-24h deadline is applied twice: at queue time (a claim inside the last 24 hours
     is not queued) and at delivery time (a row that waited outside the window too long is
     expired, not sent late). The alternative reading - deliver it anyway, just late - is
     what the deadline exists to prevent.
  4. The seat re-check lives in the edge function, not in the SQL. "Send time" is where the
     window is; SQL only decides when the row may travel.
  5. A queued row whose edge function is disabled stays queued and is retried every tick.
     That is a change from 105, where the ledger row was consumed by the first post even
     if nothing was sent. It is the right way round now that the delivery is deliberately
     later than the trigger.
  6. The room's clock comes from rooms.time_zone. The zone is validated in the runtime
     (Intl), and anything unknown falls back to UTC rather than to a plausible-looking
     Brisbane.
  7. One existing test was rewritten, not deleted: "the room zone is Brisbane, the only
     clock available" asserted the hardcoded constant that this step removes. It is now
     "the room's clock is the room's own zone" and it asserts the UTC fallback. Seven new
     tests cover the claim, the seat re-check, the interruption level, the room's zone and
     the fallback.
  8. anchor_nudges now gets `grant all on table ... to service_role` (it did not have one).
     The edge function writes with a conditional UPDATE now, and the service role has to be
     able to do that.
  9. The new SECURITY DEFINER functions are granted to authenticated + service_role
     (anchor_push_in_window, anchor_push_due, anchor_push_cron_tick), mirroring 109.
     anchor_push_post is revoked from public, anon AND authenticated: a member must not be
     able to fire a push at somebody.
  10. The 600 second apns-expiration is inherited from question-turn-push/apns.ts, which is
     outside ALLOWED FILES for this lane, so it could not be changed here. It now bites
     differently: the nudge is deliberately delivered at 9am, and a device that is
     unreachable for ten minutes (commute, lift, no signal) loses the nudge for good. The
     briefing-push copy of apns.ts uses 24 hours for exactly this reason. Flagged for TARS:
     either the shared apns.ts grows a per-payload expiry, or anchor-nudge-push gets its
     own copy like briefing-push did.

Gotchas for the next step (5, 111 Question Box timing)
- Start from the LIVE bodies: public.question_box_advance and public.question_box_host in
  docs/audit/2026-11-08/live-functions.sql, never from 097.
- The repo index has BOTH Supabase/ (120 files) and supabase/ (5 files: functions/
  anchor-nudge-push/*, migrations/103_brought_by.sql, migrations/105_anchor_push.sql).
  On this case-insensitive disk they are the same directory, but `git add Supabase/...`
  does NOT stage the lowercase-tracked files. Add them with the exact lowercase path
  (git add supabase/functions/anchor-nudge-push/handler.ts) or they stay unstaged.
- No postgres on this machine. The SQL is validated with pglast in the throwaway venv
  (/var/folders/.../T/opencode/sqlvenv, python check110.py) and written, never applied.
- Migrations are written, NEVER applied. No supabase db push/query/link, no deploys.
- git checkout -- GamesRoom.xcodeproj/project.pbxproj before every commit (xcodegen dirties it).
- 111 needs 110's anchor behaviour? No. It is independent of 108-110, but it reads
  rooms.time_zone (108) for the arrival rules if it needs a local clock.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
