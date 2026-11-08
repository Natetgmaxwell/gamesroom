# STATE S2B

STATE: step 5 of 7 done. Next: step 6 (112 RLS + mascot-voice).

Step 5 (S2B.5: question box waits for the table and stops when the night does)
committed as 431d604.
- Supabase/migrations/111_question_box_timing.sql (new). Not applied to live.
- SQL only. No edge function directory was touched, so the deno extra gate
  had nothing new to check (ran anyway: anchor-nudge-push 22 ok,
  briefing-push 31 ok, question-turn-push 10 ok, deno check clean on the
  three).
- The failure it kills (audit 01-notifications #14, #15 and the reader half
  of #18): the opener card is created the moment played_at arrives, so the
  host's phone buzzes at 7:30:00 exactly while the host is at the door and
  the table is empty; the rotation then asks the members who claimed a seat
  and never came; and if the host forgets to settle, the box keeps pushing
  time-sensitive reader cards into the small hours.

The SQL (111), four functions
- public.question_box_arrivals(p_event_id) (new). Who is at the table:
  a withdrawal on the event (transactions.session_id = event and kind =
  'casino_withdrawal') or a checked-in seat deposit
  (seat_deposits.returned_at is set, status <> 'forfeited'). Active room
  members only. A caller guard: trusted callers (cron, service role) see
  every room, an app user sees only the rooms they are in. Same shape as
  106's is_room_member / rpc_caller_trusted and 110's anchor_push_due.
- public.question_box_rotation(p_event_id). The bank branch is untouched:
  the members who withdrew, in withdrawal order. The no-bank fallback is
  now the arrived members in arrival order, instead of everyone who
  claimed a seat.
- public.question_box_advance(p_event_id, p_now). Started from the LIVE
  body. Four rules added:
    1. the opener waits for three arrivals, or played_at + 30 minutes,
       whichever comes first;
    2. no turns once p_now > played_at + rooms.auto_close_hours;
    3. no turns once nothing has been read or passed for 60 minutes;
    4. a reader with no active device token is skipped, the next one in
       the rotation is asked.
  Everything else is the live body: the cadence, the one-live-card rule,
  the draw order (member questions, then host questions, then the house
  deck), the trigger-driven push.
- public.question_box_host(p_room_id). Started from the LIVE body. The
  live resolution first (the room's host, else the longest-standing active
  host), then the reachability rule (a host with an active iOS device
  token is preferred), then the live host again when no host has a token.

Deliberate choices, all recorded here for TARS:
  1. "No turn was read or passed in the last 60 min" is read literally: the
     newest read or pass on ANY turn of the event. So the box stops an
     hour after the last answer, and it wakes up again if somebody answers
     the card that is still open (that answer is then the newest read).
     The other reading - "the open card is an hour old" - would have kept
     handing the card to a new reader every cadence until an hour after
     the card was created. The brief's wording is the literal one.
  2. The opener is never blocked by the token rule. If it were, a host
     with no push token would kill the Question Box for the night. So the
     token rule is applied as a preference between hosts (a host with a
     token beats a host without), and the last resort is the live host,
     who still sees the card in the app and can answer it for the reader.
  3. The token test matches the push exactly: is_active AND platform =
     'ios', because question-turn-push/index.ts loads tokens with both
     filters. A member with only a stale or non-iOS token is not asked.
  4. The arrivals use seat_deposits.returned_at, NOT the
     transactions.kind = 'seat_deposit_return' ledger row. check_in_seat
     only writes that ledger row when the deposit amount is greater than
     zero, so a waived (zero) deposit - a broke member the host waived -
     would have gone missing as an arrival. returned_at is set by all
     three arrival paths: the "I'm here" tap, the host's waiver for
     somebody who arrived unscanned, and the automatic return when a play
     transaction proves they were there.
  5. A forfeit is not an arrival: status = 'forfeited' is excluded
     (forfeit sets forfeited_at, not returned_at).
  6. The reader cursor is written as the position AFTER the chosen reader,
     not the position of the chosen reader. The live body adds 1, which is
     the same thing when nobody is skipped. An earlier draft wrote the
     chosen position and would have asked the same reader forever; the
     loop was simulated in Python before the SQL was written (check111.py)
     and the arithmetic is checked there.
  7. The internal family keeps the lockdown from 104: question_box_advance,
     question_box_rotation and question_box_host are revoked from public,
     anon and authenticated, and granted to service_role. The new arrivals
     helper is grantable to the app because it checks the caller. The
     definer chain still works: question_box_tick (granted to
     authenticated) calls advance as postgres, so the revoked EXECUTE
     does not bite it. That is the same argument 104 makes.
  8. question_box_host got TIGHTER than live: live had the default PUBLIC
     execute. It is now service_role only, like the rest of the family. No
     client calls it (grepped GamesRoom/ and Supabase/functions/).
  9. search_path: the live bodies use `set search_path to ''`; the house
     rule for this lane says `set search_path = public`. 111 follows the
     house rule and fully qualifies every name, so the behaviour is the
     same and the rule is met.
  10. One index was added: transactions (session_id, kind). The arrivals
      read the ledger by session and there was no index for that shape
      (the live rotation query had the same gap). create index if not
      exists, inside the migration transaction.
  11. The cron was not touched. The 'question-box-tick' job from 097 (every
      minute) drives the advance, so the opener appears within a minute of
      the third arrival. The cron still scans events up to 24 hours old;
      the advance returns null for anything past the auto-close mark, so
      that is wasted work at worst.

Two consequences TARS should know about:
  - A room with no bank and no seat deposits (seat_deposit_trigger = 'off')
    has no arrival signal at all: the opener waits the full 30 minutes and
    the rotation is empty, so the box runs the opener only. That is what
    the brief asks for (arrivals are the only gate) but it is a behaviour
    change for those rooms.
  - A member with no active device token is never asked while somebody
    else can be reached. If nobody in the rotation has a token, no interval
    turn is created at all: the box goes quiet rather than pushing into
    the void.

Gates:
  - bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases passed,
    parse-check pass=64).
  - deno check on the three function directories this lane owns: clean.
    deno test: anchor-nudge-push 22 passed, briefing-push 31 passed,
    question-turn-push 10 passed, 0 failed.
  - The SQL was parsed with pglast (20 statements, every function body
    balances, every statement starts with a keyword). No postgres on this
    machine: the migration is written, never applied.

Gotchas for the next step (6, 112 RLS + mascot-voice)
- The events policies live in two places. The read policy is 090:49-60
  ("members can read events", the exists() on room_memberships plus the
  hidden_from_user_ids check). The insert/update/delete policies are
  011:56-72 ("host can insert/update/delete events", all three keyed on
  rooms.created_by = current_user_id()). 112 has to drop and recreate all
  four.
- The brief for step 6 says the UPDATE and DELETE policies move to
  is_room_host(events.room_id, current_user_id()). It does not mention the
  INSERT policy, which also keys on rooms.created_by. Decide whether to
  move it too (is_room_host is the right shape for a promoted host) and
  write the decision down.
- The events read policy today does NOT filter membership_status, so a
  kicked or left member still reads the room's events. That is the whole
  point of the step: add m.membership_status = 'active'.
- deno check Supabase/functions/mascot-voice/ FAILS today, before any
  change: its index.ts imports `jsr:@supabase/supabase-js@2` and this
  machine's npm registry cache is empty, so deno cannot resolve
  `npm:@supabase/realtime-js@2.119.0` offline (scan-settle has the same
  problem). Rewriting that one import to
  `https://esm.sh/@supabase/supabase-js@2` - what anchor-nudge-push,
  briefing-push and question-turn-push already use - makes deno check
  pass. Verified in a scratch copy outside the repo.
- The git index tracks Supabase/functions/mascot-voice/index.ts under the
  UPPERCASE path (git add Supabase/... works for it), but
  supabase/functions/anchor-nudge-push/* and supabase/migrations/103,105
  are tracked under the LOWERCASE path. Add those with the exact
  lowercase path or they stay unstaged.
- Migrations are written, NEVER applied. No supabase db push/query/link,
  no deploys.
- git checkout -- GamesRoom.xcodeproj/project.pbxproj before every commit
  (xcodegen dirties it).

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
