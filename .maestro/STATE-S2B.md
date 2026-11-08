# STATE S2B

STATE: step 3 of 7 done. Next: step 4 (110 anchor push in waking hours).

Step 3 (S2B.3: briefing-push edge function (ships disabled)) committed as eb32e97.
- Supabase/functions/briefing-push/ (new, 6 files). Not deployed. Not applied to live.
  - plan.ts      the pure copy composer: no env, no network, no database.
  - handler.ts   the request handling, everything external arrives through Deps.
  - apns.ts      copied from ../question-turn-push/apns.ts, no import across function dirs.
  - index.ts     the wiring: Supabase client, env, the ledger write, the headcount query.
  - plan_test.ts, handler_test.ts  31 deno tests.
- The payload shape comes from 109's briefing_push_cron_tick: {"rows": [ {event_id,
  room_id, user_id, kind, rsvp_state, event_name, played_at, host_note, time_zone,
  mascot_name} ]}, one request per 200 rows, header X-Briefing-Push-Secret.
- The rows are trusted because the caller holds the shared secret. public.briefing_push_due
  already applied every eligibility rule (active membership, notifications on, not muted,
  not hidden, unsettled night in the future, not declined, slot not spent, active token),
  so the function never widens the audience of a row and only ever addresses row.user_id.
- The gate order: method (405) -> shared secret (401, fails closed when the secret is unset)
  -> rows array (400) -> BRIEFING_PUSH_ENABLED (200 {status:"disabled"}) -> work.
- Once-per-slot: the ledger row (event_id, user_id, kind) is written BEFORE the send. A
  duplicate insert (23505) means an earlier tick spent the slot, so nothing is sent. A slot
  that cannot be claimed is never sent either, because sending first and writing the row
  after would let the next tick push it again.
- Copy, title "{mascot_name}: {event_name}" on every slot:
    claimed        See you {weekday} at {time}. (+ " Host's note: {note}" when present)
    unclaimed t168h  {event_name} is next {weekday}. Your seat's waiting.
    unclaimed t48h   {weekday} at {time}. Still a seat with your name on it.
    morning_of      Tonight at {time}. There's still a seat.
    on_create       {event_name}, {weekday} {date} at {time}. Open the room to grab a seat.
    host_headcount  {claimed} in, {unanswered} haven't said. {weekday} {time}.
- The weekday, the time and the date are read in the room's zone (rooms.time_zone, 108),
  never in UTC and never in a hardcoded Australian zone. A night that is Friday in UTC is
  Saturday in Brisbane when it is 06:00, and the copy says Saturday.
- Interruption level "active" (not time-sensitive: that is the question turn's). Thread id
  briefing-{event_id}, so every slot of one night groups on one screen.
- Gates: bash .maestro/fastgate.sh -> FASTGATE: PASS (302 cases passed, parse-check pass=64).
  deno check Supabase/functions/briefing-push/ -> clean. deno test -> 31 passed, 0 failed.
  deno lint -> 5 no-import-prefix findings, the same shape as question-turn-push's 4.
- Deliberate choices, all recorded here for TARS:
  1. The auth gate comes before the enabled gate, so an unauthenticated probe is 401 even
     while the feature is off. That mirrors question-turn-push and it is why the rollout doc
     tells the operator to probe with the secret to see {status:"disabled"}.
  2. A host note containing the word "claim" is NOT appended to a claimed member's push.
     The rule in the brief is absolute (a claimed member never reads the word), so the note
     is left out rather than sent. Unclaimed slots never carry the note at all, because the
     brief gives their copy exactly and there is no note slot in it. The other reading, send
     the host's words whatever they say, is one line in plan.ts.
  3. A member with no active device token does NOT spend the slot: the token read happens
     before the ledger insert, so a member who registers a phone in the next few minutes
     still gets the push. The opposite reading (claim first, always) is also one line.
  4. The headcount counts the active roster minus the members hidden from the event. A
     declined member has said (they said no), so they are not in "haven't said". The
     headcount is read once per event per request and shared by the hosts of that event.
  5. An unreadable time zone falls back to UTC, not to Australia/Brisbane. rooms.time_zone
     is NOT NULL with a default, so this only fires on corrupt data.
  6. apns.ts is a copy with two changes from question-turn-push's: the collapse id comes
     from the payload (one banner per event+slot) and the expiration is 24 hours, because
     the question sender's 600 seconds is for a question that is stale after ten minutes and
     a briefing is not. A fix that lands in one apns.ts has to be ported to the other.
  7. The payload carries type "briefing_push", kind, event_id and room_id. The app does not
     route a briefing tap yet (audit 01-notifications #20), and that is Swift work this lane
     is not allowed to touch, so the payload carries the fields a tap handler would need.
  8. The rows are not re-checked against the database (no second eligibility pass). The
     secret is the gate, and the SQL is the eligibility. A second pass would be a second
     source of truth for the same rules.
- Still to come for this function to actually run: the vault secret briefing_push_secret,
  the deploy with --no-verify-jwt, and BRIEFING_PUSH_ENABLED="true". All of that is step 7
  (docs/S2B_SERVER_PUSH.md).

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2B.md (tick the checkbox there too).
