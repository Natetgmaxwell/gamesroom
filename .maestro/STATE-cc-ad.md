# STATE cc-ad
Base: 0ed187927d4fd5d6e10ca3f18a901d448c8692be  Branch: cc/autoclose-derived
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: AD2 migration 120 rebuilt — night ends itself
- [x] AD1 settled_at consumer facts
- [ ] AD2 migration 120 rebuilt — night ends itself
- [ ] AD3 probes — no-tick recap
- [ ] AD4 Swift resolver mirror + tests
- [ ] AD5 doc + report

AD1 DONE (commit a7b3364 "AD1: settled_at consumer facts"). Facts written to the top of
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
  040:77-78 cron_close_unscanned_attestations — recency-shaped but in an applied
     migration outside the whitelist.

- STOP-AND-REPORT list (all outside this lane's whitelist, none edited, all in the
  report): the anchor-push COUNT (105/110), the glad push queue hole (119:260/264 —
  the one real behavioural hole the derive rule opens), settle_event stamping now()
  on an already-expired night (107:258/263), the question box (097/111/118), the
  briefing sweep (109:155), the attestation sweep (040:77/78).

- Same-named columns on OTHER tables — out of scope: public.seat_deposits.settled_at
  (DDL 043:30; writes 043/085/113/114/115) and public.casino_withdrawals.settled_at
  (041:166-171). Neither is touched.

- Writer being demoted: public.cron_close_stale() (120:76-112). Body stays (it stamps
  played_at + the room's window — the same value the reads derive); the SCHEDULE goes
  from '17 * * * *' to '17 3 * * *'. pg_cron guard + SECURITY DEFINER + revoke pattern
  stay exactly as the old 120 had them.

- Swift twin: NightPhaseResolver is a single type in GamesRoom/Services/NightPhase.swift
  (rule at :102-110; recapWindow 86_400 at :83; defaultAutoCloseHours 8 at :87).
  Table tests: TestsP1.swift:29-99 (runP1NightPhaseTests), pinned now at :30, exact
  boundary rows at :57. No XCUITest / screenshot seed asserts the `stranded` rendering
  (grep over the whole repo finds no hit under GamesRoomUITests/) — nothing to repoint.

- The change list is in REPORT-task-AD.md §1.7.
