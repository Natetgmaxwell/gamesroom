# STATE cc-ad
Base: 0ed187927d4fd5d6e10ca3f18a901d448c8692be  Branch: cc/autoclose-derived
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: AD3 probes — no-tick recap
- [x] AD1 settled_at consumer facts
- [x] AD2 migration 120 rebuilt — night ends itself
- [ ] AD3 probes — no-tick recap
- [ ] AD4 Swift resolver mirror + tests
- [ ] AD5 doc + report

AD1 DONE (commit 660614b "AD1: settled_at consumer facts"). Facts written to the top of
REPORT-task-AD.md. Summary of what AD1 established, for the next steps:

- The effective settle rule: eff_settled_at = coalesce(e.settled_at,
  case when p_now >= e.played_at + make_interval(hours => coalesce(r.auto_close_hours,8))
  then e.played_at + that window end end). The physical stamp wins, so the host's own
  settle time is respected. `stranded` becomes unreachable (kept as a safety fallback);
  `live`/`upcoming` are unchanged.

- Consumers that CHANGE (phase-recency), all rewritten inside the new 120:
  A1 115:68-88   public.night_phase(played_at, settled_at, auto_close_hours, now)
  A2 115:178-196 get_active_event__inner — the SETTLED leg (192-195 recency+order by,
                180 returns settled_at)
  A3 107:317-335 get_recent_settled_event — (331-334 recency+order by, 319 returns)
  A4 119:125     glad_can_send — calls night_phase, changes for free, no edit to 119.

- Consumers LEFT ALONE (not phase-recency):
  B1 115:869/884/899 check_one_upcoming_event_per_room trigger — provably identical
      (it only looks at rows with played_at > now(); the effective settle cannot be set
      for such a row).
  B2 115:819-825 auto_close_stale_events (a writer; stamps the same derived value).
  B3 107:242/258/263 settle_event (write guard "already settled").
  B4 097:746/756, 111:300/310, 118:297/308 question_box_advance ("is it settled?").
  B5 097:833 question_box_cron_tick.
  B6 105:180, 110:230 newcomer-anchor push — a COUNT of settled nights.
  B7 109:155 briefing push.
  B8 119:260/264 glad_you_came_queue_push — reads the settle time directly.
  B9 040:77-78 cron_close_unscanned_attestations — recency-shaped but in an applied
      migration outside the whitelist.

- STOP-AND-REPORT list (all outside this lane's whitelist, none edited, all in the
  report): the anchor-push COUNT (105/110), the glad push queue hole (119:260/264 —
  the one real behavioural hole the derive rule opens), settle_event stamping now()
  on an already-expired night (107:258/263), the question box (097/111/118), the
  briefing sweep (109:155), the attestation sweep (040:77/78).

- Same-named columns on OTHER tables — out of scope: public.seat_deposits.settled_at
  (DDL 043:30; writes 043/085/113/114/115) and public.casino_withdrawals.settled_at
  (041:166-171). Neither is touched.

- Writer being demoted: public.cron_close_stale() (old 120:76-112). Body stays (it stamps
  played_at + the room's window — the same value the reads derive); the SCHEDULE goes
  from '17 * * * *' to '17 3 * * *'. pg_cron guard + SECURITY DEFINER + revoke pattern
  stay exactly as the old 120 had them.

- Swift twin: NightPhaseResolver is a single type in GamesRoom/Services/NightPhase.swift
  (rule at :102-110; recapWindow 86_400 at :83; defaultAutoCloseHours 8 at :87).
  Table tests: TestsP1.swift:29-99 (runP1NightPhaseTests), pinned now at :30, exact
  boundary rows at :57. No XCUITest / screenshot seed asserts the `stranded` rendering
  (grep over the whole repo finds no hit under GamesRoomUITests/) — nothing to repoint.

- The change list is in REPORT-task-AD.md §1.7.

AD2 DONE (this commit: "AD2: migration 120 rebuilt — night ends itself"). What AD2
built, and what AD3 must know:

- Supabase/migrations/120_stale_close_cron.sql is REMOVED (never applied).
  Supabase/migrations/120_night_ends_itself.sql replaces it, same number, new name.

- The file rewrites, in this order:
  1. public.night_phase(played_at, settled_at, auto_close_hours, now) — same
     signature, same IMMUTABLE + p_now discipline. Body now derives the effective
     settle in a CTE and branches:
        none | upcoming | live (requires NO effective settle) | recap | past
        | else 'stranded' (unreachable safety fallback).
     The physical stamp wins, so an early-settled night still reads 'recap'
     (115.a pins that row).
  2. public.get_active_event__inner — the settled leg only. It now selects
     eff.settled_at (a LATERAL cross join computes the effective settle once)
     instead of e.settled_at, filters on eff.settled_at, and orders by
     eff.settled_at desc. The live leg and the future leg are byte-for-byte
     unchanged; the hidden-member filter is unchanged. The returned settled_at
     IS the effective value, so the client renders unchanged.
  3. public.get_recent_settled_event — same rewrite; the membership gate
     (rpc_caller_trusted or is_room_member) and the hidden-member filter are
     byte-for-byte unchanged.
  4. public.cron_close_stale — body unchanged (SECURITY DEFINER, search_path,
     revoke, pg_cron guard all unchanged); the schedule is now '17 3 * * *'
     (daily at 03:17) and the function comment says hygiene, not correctness.

- The phase table after 120 (what the probes and the Swift twin must agree on):
     played_at null                              -> none
     played_at > now                            -> upcoming
     no effective settle and now < played+window -> live
     effective settle inside the last 24 h        -> recap
     effective settle older than 24 h            -> past
     (stranded: unreachable)
     At exactly played_at + window the night reads 'recap', NOT 'stranded'.

- FLAG (already in REPORT-task-AD.md §1.8): Supabase/tests/115_probes.sql:145-146
  assert 'stranded' at 8 h and 9 h. They are now 'recap' and are STALE. The file
  is outside the whitelist — not edited; the orchestrator repoints it.

- Verification for AD2: the SQL parses clean (pglast, 18 statements) and the phase
  table was diffed old vs new over 120 input combinations — the only differences
  are (a) expired never-stamped nights stranded -> recap/past (the point of the
  lane) and (b) a future night carrying a physical stamp -> upcoming, which is
  unreachable (settle_event refuses to settle a night that has not started).
  Gate: FASTGATE: PASS (625 cases).

- For AD3: Supabase/tests/120_probes.sql is replaced by the derive-at-read probe
  set (a-h in the brief). The old probe bodies still apply for the janitor
  (i..t); the schedule probe must now expect '17 3 * * *' (the old one expected
  '17 * * * *'), and the headline probe must show a never-stamped night 8h01m past
  its start reading as 'recap' through get_recent_settled_event AND night_phase,
  with settled_at = played_at + window and NO janitor call.
