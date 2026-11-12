# STATE cc-ad
Base: 0ed187927d4fd5d6e10ca3f18a901d448c8692be  Branch: cc/autoclose-derived
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
NEXT: AD5 doc + report
- [x] AD1 settled_at consumer facts
- [x] AD2 migration 120 rebuilt — night ends itself
- [x] AD3 probes — no-tick recap
- [x] AD4 Swift resolver mirror + tests
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

AD3 DONE (this commit: "AD3: probes — no-tick recap"). What AD3 built, and
what AD4 must know:

- Supabase/tests/120_probes.sql is REPLACED. The old file tested the janitor
  (the hourly tick was the correctness path); the new file tests the DERIVE
  and keeps the janitor's own probes (it is hygiene, but it is still a
  writer, so it must stamp the same value the reads derive).

- Brief letter -> probe id:
    (a) 120.a-headline-no-tick / -phase / -read / -active
    (b) 120.b-phase-live / -no-recap-yet / -active-live
    (c) 120.c-phase-upcoming / -no-recap / -active-upcoming
    (d) 120.d-host-stamp-phase / -host-stamp-wins / -order-by-effective-settle
    (e) 120.e-phase-past / -no-recap
    (f) 120.f-non-member-gated / -member-sees / -hidden-filter
        / -hidden-filter-control
    (g) 120.u-cron-job-count + 120.v-cron-job-shape  (old ids reused; the
        shape probe now expects '17 3 * * *', not '17 * * * *')
    (h) 120.i-* .. 120.t-*  (the old janitor sweep probes, reused verbatim)
  The janitor's SECURITY contract (the old 120.a .. 120.h) is reused too,
  renumbered 120.sec1- .. 120.sec8- so it does not collide with the new
  derive probes.

- The headline (a) proves the whole lane: a never-stamped night 8h01m past
  its start reads 'recap' through night_phase AND through
  get_recent_settled_event AND through get_active_event; the returned
  settled_at is played_at + 8h; and the physical column is still NULL --
  no writer ran.

- (d) pins the ordering rule that the old code could not express: in one
  room, a host-settled night (stamp now-2h) and a never-stamped night
  (true end now-1m) -> the never-stamped one is the recap, because recency
  keys on the EFFECTIVE settle. Under the old rule the never-stamped night
  was not a candidate at all.

- One probe that is not in the brief: 120.derive-write-agrees -- it reads
  the derived end BEFORE the janitor runs, runs the janitor, and asserts the
  janitor wrote exactly that value. That is the invariant the lane rests on.

- Two structural choices worth knowing:
    * Every block RE-ANCHORS its own fixtures against now() before it
      asserts anything. now() is the transaction timestamp, so the fixture
      and the assertions inside one block see the same clock, however long
      the file took to get there. The margins the brief asks for (8h01m
      past, 7h59m past) are exact inside a block, not approximate.
    * The derive probes run BEFORE the janitor probes: the janitor stamps
      every expired night in the replica, so running it first would write
      the very column probe (a) asserts is NULL.
  The janitor block also clears the JWT claims (to '{}', NOT '' --
  current_user_id() casts the claims to json and '' is not json) so the
  sweep really does run the way pg_cron runs it.

- Recorded deviations (also in REPORT-task-AD.md §1.9):
    * Probe style: raise notice, not the brief's `select 'PROBE … ' || case
      … end`. A bare SELECT inside a DO block is discarded by plpgsql, so
      the notice form is the one that carries a multi-step probe; every
      probe still prints exactly one 'PROBE <id> PASS|FAIL …' line. This is
      the same deviation lane B recorded for the previous version of this
      file -- it is not new.
    * Probe ids: the brief's letters are the derive probes; (g) and (h)
      reuse the old ids so the diff is readable.

- Verification for AD3: the file parses clean (pglast, 29 statements) and
  every assertion was checked against a model of the AD rules (night_phase,
  the two readers, the janitor sweep) -- 31 modelled assertions, 0 that
  would fail. The probes have STILL never been executed against a live or
  replica database: this lane has no database. Gate: FASTGATE: PASS (625
  cases).

- For AD4: the Swift twin is NightPhaseResolver in GamesRoom/Services/
  NightPhase.swift (the rule at :102-110, recapWindow 86_400 at :83,
  defaultAutoCloseHours 8 at :87). It must mirror the effective-settle
  logic: the effective settle is the host's stamp when there is one, else
  played_at + the window once `now` has reached it; 'live' additionally
  requires NO effective settle (so an early-settled night reads recap);
  'stranded' stays as the unreachable safety fallback. The table tests
  live in TestsP1.swift:29-99 (runP1NightPhaseTests, pinned now at :30,
  exact boundary rows at :57) -- the pinned 'stranded' rows there are now
  'recap' and must be repointed in the same commit.

AD4 DONE (this commit: "AD4: Swift resolver mirror + tests"). What AD4 built,
and what AD5 must know:

- GamesRoom/Services/NightPhase.swift is rewritten to the migration-120 rule.
  The resolver body is now branch for branch the SQL's:
      none | upcoming | live | recap | past | stranded (unreachable)
  The effective settle is `facts.settledAt ?? (now >= playedAt + window
  ? playedAt + window : nil)`; 'live' still requires NO effective settle (so
  an early-settled night reads recap); 'stranded' is the last branch and is
  unreachable -- a nil effective settle means the clock has not reached the
  window end, so 'live' took the row. The header comment now names
  migration 120 as the twin, and NightPhase.stranded's doc says
  unreachable-by-design.

- TestsP1.swift:29+ extended. The pinned 'stranded' rows are now 'recap'
  (exactly at the window end, one second past it, a nine-hour-old night, the
  autoCloseHours rows). ONE row also moved for the branch order: 'a settled
  night in the future' was .recap under 115 and is .upcoming under 120
  (upcoming runs before the settle branches). FIVE rows added: the true end
  exactly 24h ago -> .past (this is what pins the derived value against
  `now()`), one second inside the recap window -> .recap, a two-day-old night
  -> .past, the host's stamp wins over the derived end -> .recap, an old host
  stamp still wins over a fresher derived end -> .past.

- The twins were checked MECHANICALLY: the resolver was extracted verbatim
  into a throwaway harness in /tmp (not committed) and run over 990 input
  combinations (18 played offsets x 11 settled offsets x 5 windows, every
  exact boundary included). Swift-vs-SQL120 mismatches: 0. Rows reaching
  'stranded' under the new rule: 0. The old Swift rule and the old SQL rule
  (115) were also run over the same grid and agreed with each other on all
  990 rows, so the change is symmetric: the twins moved together, and only
  in the two classes AD2 documented.

- FOUR tests elsewhere derived a phase and expected 'stranded'. They could not
  be left alone (the gate has to be green) and were repointed to the new
  truth: TestsP1's 'a stranded night outranks the next scheduled night' (the
  next scheduled night takes the active slot now), TestsP1's two '.inPlay'
  rows (-> .justSettled), and main.swift's MascotEngine.footerKind row
  (-> .postPlayRecap). The main.swift edit is outside the brief's "list lines
  only" whitelist; it is there because the gate must not go red.

- STOP-AND-REPORT (in REPORT-task-AD.md 1.10, all left unchanged):
    * The fake store does not derive. InMemoryRoomStore.fetchActiveEvent
      (1053-1075) still has its now-dead '.stranded' leg at 1068, and
      fetchRecentSettledEvent (1080-1088) still filters on a PHYSICAL
      settledAt. So in the fake an expired never-settled night is invisible
      (neither the active slot nor a recap); on the server it IS the recap.
      Out of the whitelist -> not edited.
    * Stale doc comments that still describe 'stranded' as a live state:
      V0State.swift:24-26 and :41, MascotEngine.swift:249,
      NightPlan.swift:24 and :107-109, RoomStore.swift:398,
      NextNight.swift:101.
    * The product consequence, unasked for: NightPlan's '.stranded' branch
      (121-123) was the only place that offered the host a 'settle the
      night' action for a night that ran past its window. It is dead now.
      A LIVE night still offers .settleNight (124 -> hostClosing), but an
      over-window night simply ends and reads as a recap. Nathan should
      confirm that is wanted.
    * Supabase/tests/115_probes.sql:145-146 is still stale (115-probe flag).

- No UI test, screenshot seed or migration was touched in AD4. TestsP1.swift
  was already in build-and-run-tests.sh and main.swift, so no registration
  line changed. Gate: FASTGATE: PASS (630 cases, --compile).

- For AD5: docs/STATE-MACHINES.md -- its Night phase section. It must say:
  the effective settle is the rule (the host's stamp, else played_at +
  auto_close_hours once the clock has reached it); 'stranded' is
  unreachable-by-design and kept only as a safety fallback on both sides; the
  cron is hygiene at '17 3 * * *' and nothing waits on it; the Swift twin is
  NightPhaseResolver in GamesRoom/Services/NightPhase.swift. Read the
  section first -- it may also carry the 'stranded' branch that AD4 made
  dead, and the machines that consumed it (V0State, NightPlan, MascotEngine,
  NextNight) may need their 'never do' lines re-pointed. Then finish
  REPORT-task-AD.md: the consumer list from AD1 with which consumers changed
  and which were left alone and why (1.2, 1.3, 1.5, 1.8-1.10 already carry
  most of it -- check it reads as one finished document).

