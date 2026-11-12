# STATE cc-ad
Base: 0ed187927d4fd5d6e10ca3f18a901d448c8692be  Branch: cc/autoclose-derived
Rewrite after every step. When all ticked, replace NEXT line with: ALL STEPS DONE
ALL STEPS DONE
- [x] AD1 settled_at consumer facts
- [x] AD2 migration 120 rebuilt — night ends itself
- [x] AD3 probes — no-tick recap
- [x] AD4 Swift resolver mirror + tests
- [x] AD5 doc + report

AD5 DONE (commit ae35754 "AD5: state-machines doc + report"). What AD5 built:

- docs/STATE-MACHINES.md §1 "Night phase" is rewritten. It now says:
    * `stranded` is UNREACHABLE BY DESIGN since migration 120 — the night ends
      itself, so an expired night reads `recap` or `past` with no writer having
      run. It stays in the vocabulary (one of the seven SQL values) as a safety
      fallback on both sides. (The old text said "at or past that line it is
      `.stranded`", which is now false.)
    * the EFFECTIVE SETTLE is the rule: the host's own `settledAt` when there
      is one, otherwise `playedAt + autoCloseHours` once `now` has reached it —
      the end of a night is known at booking time, so no writer has to stamp
      the column for the night to have ended.
    * the branch order exactly: `playedAt > now` -> `.upcoming`; `.live` needs
      NO effective settle and `now < playedAt + autoCloseHours` (so a night the
      host settled early reads `.recap`, never `.live`); an effective settle
      inside 24 h -> `.recap`, older -> `.past`.
    * the server twin now points at Supabase/migrations/120_night_ends_itself.sql
      (it named 115) and says both readers key recency on the effective settle
      and RETURN it as `settled_at`.
    * a new **Hygiene** line: `public.cron_close_stale()` stamps that same
      derived value into the physical column, daily at 03:17 ('17 3 * * *');
      nothing waits on it and the reads are right before it has ever run.
    * the pin is repointed from `P1: exactly at played_at + auto_close_hours is
      .stranded` to `... is .recap`, plus `P1: a night whose true end was 24h
      ago is .past`.
    * the Never line gained: never key recency on the physical `settled_at`
      column — it stays null until somebody writes it, so the effective settle
      is the only thing that says when a night ended.
  The other fifteen sections of the doc were read and needed NO change: their
  "never" lines are about their own machines, not about the phase rule, and
  their pins still exist and still pass. The one that mentions `stranded` is
  §12 (Night plan) — `P1: a stranded night asks the host to settle it` still
  exists and still passes, because it pins `NightPlan.plan` against a
  `.stranded` input directly and `NightPlan` still handles that case; it is the
  RESOLVER that can no longer produce one. The brief scopes this file to the
  Night phase section, so §12 was not touched.

- REPORT-task-AD.md now reads as one finished document rather than a step log:
    * a new **Summary** at the top: the rule in one paragraph, the files
      changed, the CONSUMER LEDGER (every read of `events.settled_at` in
      Supabase/migrations/*.sql with changed / left-alone / why), verification,
      and a pointer to the open list;
    * the stale forward references are fixed — §1.6 (the Swift twin) now quotes
      the CURRENT migration-120 body with the current line numbers (the old
      NOTE pointing at AD4 is gone), §1.5 points at the new file and its new
      line numbers, §1.7 is the change list the lane MADE (past tense);
    * the section headings read as a finished document (§1.8 Migration 120,
      §1.9 the probe set, §1.10 the Swift twin, §1.11 the state-machines doc);
    * a new **§2 What is still open for the orchestrator** (7 items) and a new
      **§3 How this lane was verified** (the check table).

- Verification for AD5: `bash .maestro/fastgate.sh` -> FASTGATE: PASS
  (630 cases, 74/74 SwiftUI parse-checks). Nothing but docs changed in this
  commit.

THE LANE IS DONE. All five step commits are on the branch:
    660614b AD1: settled_at consumer facts
    a5a74c1 AD2: migration 120 rebuilt — night ends itself
    964ae60 AD3: probes — no-tick recap
    8afc175 AD4: Swift resolver mirror + tests
    ae35754 AD5: state-machines doc + report

STILL OPEN FOR THE ORCHESTRATOR (none of it is in this lane's whitelist; the
full list is REPORT-task-AD.md §2):
  1. Supabase/tests/115_probes.sql:145-146 still assert 'stranded' at 8h and
     9h — they read 'recap' under 120, so they will FAIL. Repoint them.
  2. The fake store does not derive: InMemoryRoomStore.fetchActiveEvent
     (1053-1075) keeps its now-dead '.stranded' leg at 1068, and
     fetchRecentSettledEvent (1080-1088) still filters on a PHYSICAL settledAt.
     In the fake an expired never-settled night is invisible; on the server it
     IS the recap.
  3. Stale doc comments that still describe 'stranded' as live:
     V0State.swift:24-26 and :41, MascotEngine.swift:249, NightPlan.swift:24
     and :107-109, RoomStore.swift:398, NextNight.swift:101.
  4. NightPlan's '.stranded' branch (121-123) was the only place that offered
     the host a 'settle the night' action for a night that ran past its window.
     It is dead now. A LIVE night still offers .settleNight (124 ->
     hostClosing); an over-window night simply ends and reads as a recap.
     Nathan should confirm that is wanted.
  5. The consumers that still read the physical column: the newcomer-anchor
     COUNT (105:180, 110:230) and the glad-you-came push queue (119:260/264 —
     the one real behavioural hole the derive rule opens: glad_can_send now
     lets a member send for a night that expired without a stamp, but the
     queue trigger still skips it, so the push never goes out). Plus
     settle_event stamping now() on an already-expired night (107:258/263),
     the question box (097/111/118), the briefing sweep (109:155) and the
     attestation sweep (040:77/78).
  6. Live apply is Nathan-gated and was NOT done. The probes have never been
     executed against a database — this lane has none. Run both
     120_probes.sql and the repointed 115_probes.sql against a replica before
     120 is applied anywhere.
