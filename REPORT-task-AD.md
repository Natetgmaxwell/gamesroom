---
type: report
title: "Task AD — the night ends itself (derive-at-read autoclose)"
created: 2026-11-12
tags:
  - autoclose
  - settled-at
  - night-phase
  - state-machine
  - supabase
related:
  - '[[AGENTS]]'
  - '[[STATE-MACHINES]]'
  - '[[REPORT-task-B]]'
---

# Task AD — the night ends itself (derive-at-read autoclose)

Lane AD. Restructures the **unapplied** migration 120 in place: the end of a
night is known the moment the night is booked (`played_at + auto_close_hours`),
so reads derive the effective settle time and the hourly janitor demotes to a
daily hygiene writer that nothing depends on.

Nothing here is applied to the live database. Live apply is Nathan-gated.

---

## Summary

**The rule.** A night ends at `played_at + the room's auto_close_hours`, and
that value is known the moment the night is booked. So the reads derive it.
The **effective settle** is the host's own `settled_at` when there is one, and
otherwise `played_at + auto_close_hours` once the clock has reached it. The
physical column is a writer's copy of that fact, not the source of it.

**What that changes.** An expired night that nobody settled used to read
`stranded` — "the window is gone and nobody wrote the column". It now reads
`recap` if it ended inside the last 24 h and `past` if it ended before that,
with no writer having run. The hourly janitor that used to be the only thing
that could end such a night is demoted to hygiene: daily at 03:17, and nothing
waits on it.

**The files**

| file | what |
|---|---|
| `Supabase/migrations/120_night_ends_itself.sql` (replaces the never-applied `120_stale_close_cron.sql`) | rewrites `night_phase`, the settled leg of `get_active_event__inner`, and `get_recent_settled_event` to read the effective settle; drops the janitor's schedule from `'17 * * * *'` to `'17 3 * * *'` |
| `Supabase/tests/120_probes.sql` | replaced: the probe set now pins the derive, and keeps the janitor's own probes because the janitor is still a writer |
| `GamesRoom/Services/NightPhase.swift` | `NightPhaseResolver.phase` rewritten to the migration-120 rule, branch for branch |
| `TestsP1.swift` | the pinned table extended (five new rows) and the `stranded` rows repointed to `recap` |
| `main.swift` | one assertion repointed (the MascotEngine footer for a night that used to read `stranded`) |
| `docs/STATE-MACHINES.md` | §1 "Night phase" rewritten: the effective settle is the rule, `stranded` is unreachable by design, the cron is hygiene |
| `REPORT-task-AD.md` | this document |

**The consumer ledger** — every read of `events.settled_at` in
`Supabase/migrations/*.sql`. AD1 established the list; this is where each one
ended up. The full table, with the read itself and the reasoning, is §1.2.

| consumer | outcome | why |
|---|---|---|
| `public.night_phase` (115:68) | **changed** (120) | it is the phase; the recap/past branches now read the effective settle, and `stranded` is the unreachable final branch |
| `public.get_active_event__inner`, settled leg (115:178) | **changed** (120) | recency keys on the effective settle, and the effective value is returned as `settled_at` so the client renders unchanged |
| `public.get_recent_settled_event` (107:317) | **changed** (120) | the same, behind the same membership gate and the same hidden-member filter |
| `public.glad_can_send` (119:125) | **changed for free** | it calls `night_phase`; no edit to 119 |
| `check_one_upcoming_event_per_room` trigger (115:869/884/899) | left alone | provably identical: it only ever looks at rows with `played_at > now()`, and the effective settle cannot be set for such a row |
| `auto_close_stale_events` (115:819) | left alone | a writer, not a recency read; it stamps the same derived value, so it stays consistent with the reads |
| `settle_event` write guard (107:242/258/263) | left alone | "is it already settled?" is not a phase — but see §1.3, item 3 |
| question box (097:746, 111:300, 118:297) | left alone | a "settled?" predicate with no recency window — see §1.3, item 4 |
| `question_box_cron_tick` (097:833) | left alone | which nights the tick advances |
| newcomer-anchor push count (105:180, 110:230) | left alone | a **count** of settled nights, not a phase — see §1.3, item 1 |
| briefing push sweep (109:155) | left alone | which nights get a briefing — see §1.3, item 5 |
| `glad_you_came_queue_push` (119:260/264) | left alone | it reads the settle time directly, and 119 is outside this lane's whitelist — see §1.3, item 2: the one real hole the rule opens |
| `cron_close_unscanned_attestations` (040:77) | left alone | recency-shaped, but in an applied migration outside the whitelist — see §1.3, item 6 |
| `seat_deposits.settled_at`, `casino_withdrawals.settled_at` | out of scope | different tables, their own facts — see §1.4 |

**Verification.** `bash .maestro/fastgate.sh` → `FASTGATE: PASS`
(630 cases). The migration and the probe file both parse (pglast); the phase
table was diffed old against new over 120 input combinations; the Swift twin
and a model of migration 120 were compared over 990 input combinations with 0
mismatches. The probes have **never been executed** against a database — this
lane has none. See §3.

**Still open for the orchestrator.** In short: the stale `stranded` rows in
`Supabase/tests/115_probes.sql:145-146`; the fake store
(`InMemoryRoomStore`), which does not derive; the stale `stranded` doc
comments; `NightPlan`'s now-dead host affordance for settling an over-window
night; and the six consumers that the derive rule leaves reading the physical
column. The full list is §2.

---

## 1. The rule and the consumer facts (AD1)

### 1.1 The rule being introduced

**Effective settle time** — for an event row `e` in a room `r`:

```sql
eff_settled_at = coalesce(
    e.settled_at,
    case when p_now >= e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
         then e.played_at + make_interval(hours => coalesce(r.auto_close_hours, 8))
    end
)
```

Two readings of the same fact:

| | |
|---|---|
| **Physical** `events.settled_at` | what the *writer* stamped. `null` for a night nobody settled. The host's own settle stamp, or the janitor's. |
| **Effective** settle | when the night *actually* ended. Known at booking time; no writer required. The physical stamp, when present, wins — the host's own settle time is the truth about their night. |

Consequences that the rest of this document relies on:

- A night is **effectively settled** exactly when `p_now >= played_at + window`.
  The derived value is then `played_at + window` — the true end time, not
  `now()`. This is the same stamp `auto_close_stale_events` and
  `cron_close_stale` already write (`115:820`, `120:359`), so the derived value
  and the physical stamp agree by construction.
- **`stranded` becomes unreachable.** Under the old rule, a night that started,
  was never settled, and is past its window was `stranded` (115:86). Under the
  new rule that same night has a non-null effective settle, so it lands on
  `recap` or `past` instead. `stranded` stays in the enum (both sides) as a
  safety fallback, but no input reaches it.
- **`live` and `upcoming` are unaffected.** A night with a null physical stamp
  has a null effective settle only while `p_now < played_at + window`, which is
  exactly the union of the old `live` and `upcoming` branches.
- The **host's own stamp is respected**: `coalesce(e.settled_at, …)` puts the
  real stamp first, so a night the host settled at 23:10 reads `recap` from
  23:10, not from `played_at + window`.

### 1.2 Every read of `events.settled_at` in `Supabase/migrations/*.sql`

`grep -rn "settled_at" Supabase/migrations/*.sql` → 136 hits. 23 of them are the
**column on another table** (`casino_withdrawals.settled_at`,
`seat_deposits.settled_at`) and are **not** in scope — see §1.4. The rest break
down as follows.

#### A. Live functions whose semantics ARE phase-recency — these change

| # | file:line | consumer | how it reads `settled_at` | plan |
|---|---|---|---|---|
| A1 | `115_state_machine_guards.sql:68-88` | `public.night_phase(p_played_at, p_settled_at, p_auto_close_hours, p_now)` | `p_settled_at is not null and p_settled_at > p_now - interval '24 hours'` → `recap`; `p_settled_at is not null` → `past` (lines 80-82) | **REWRITE in 120** — the settle input becomes the effective settle. `stranded` (line 86) stays as a safety fallback and becomes unreachable. |
| A2 | `115_state_machine_guards.sql:178-196` | `public.get_active_event__inner(p_room_id)` — **settled leg** | `e.settled_at is not null` (192) `and e.settled_at > now() - interval '24 hours'` (193) `order by e.settled_at desc` (195); returns `e.settled_at` as the row's `settled_at` (180) | **REWRITE in 120** — recency keyed on the effective settle, and the *effective* value returned as `settled_at` so the client renders unchanged. |
| A3 | `107_night_lifecycle.sql:317-335` | `public.get_recent_settled_event(p_room_id)` — the recap section | `e.settled_at is not null` (331) `and e.settled_at > now() - interval '24 hours'` (332) `order by e.settled_at desc` (334); returns `e.settled_at` (319) | **REWRITE in 120** — same treatment as A2. The membership gate (314) and the hidden-member filter (333) stay byte-for-byte. |
| A4 | `119_glad_you_came.sql:125` | `public.glad_can_send(p_event_id, p_from, p_to)` | `public.night_phase(e.played_at, e.settled_at, r.auto_close_hours, now()) = 'recap'` | **CHANGES FOR FREE** — it consumes `night_phase`, so rewriting A1 changes it. No edit to 119 (and 119 is not in this lane's whitelist). |
| A5 | `040_get_my_open_withdrawal_and_sweep.sql:77-78` | `public.cron_close_unscanned_attestations()` | `e.settled_at is not null and e.settled_at + interval '24 hours' < now()` | **FLAGGED, LEFT ALONE** — 040 is not in the whitelist. See §1.3. |

#### B. Live functions whose semantics are NOT phase-recency — left alone

| # | file:line | consumer | the read | why it is not phase-recency |
|---|---|---|---|---|
| B1 | `115_state_machine_guards.sql:869`, `:884`, `:899` | `public.check_one_upcoming_event_per_room()` (the one-upcoming-night trigger) | `new.settled_at is not null` (869); `e.settled_at is null` (884); `when (new.played_at > now() and new.settled_at is null)` (899) | It is a **write-time** guard over *pending* nights. **Provably identical under the new rule**: the trigger only ever looks at rows with `played_at > now()`, and the effective settle is non-null only when `now >= played_at + window`, which cannot both hold. Left alone — no behaviour change either way. |
| B2 | `115_state_machine_guards.sql:819-825` | `public.auto_close_stale_events(p_room_id)` | writer: `and e.settled_at is null and e.played_at < now() - make_interval(hours => r.auto_close_hours)` | A **writer**, not a recency read. It still stamps exactly the derived value (`played_at + window`), so it stays consistent with the derived settle. Left alone. |
| B3 | `107_night_lifecycle.sql:242`, `:258`, `:263` | `public.settle_event(p_room_id, p_event_id)` | reads `v_settled_at`; raises `not_live` if `v_settled_at is not null or v_played_at > now()` (258); stamps `settled_at = now()` (263) | A **write guard**: "this night is not already settled". Not recency. Left alone — but see §1.3, item 3. |
| B4 | `097_question_box.sql:746`, `:756`; `111_question_box_timing.sql:300`, `:310`; `118_question_box_depth.sql:297`, `:308` | `public.question_box_advance(p_event_id, p_now)` | `if v_e.settled_at is not null or v_e.played_at > p_now then return null;` | A **"is it settled?"** predicate with no recency window: turns stop when the night is closed. Left alone; flagged in §1.3, item 4. |
| B5 | `097_question_box.sql:833` | `public.question_box_cron_tick()` | `and e.settled_at is null` | Which nights the tick advances. Not recency. Left alone; flagged. |
| B6 | `105_anchor_push.sql:174-180`; `110_anchor_push_waking_hours.sql:224-230` | the newcomer-anchor push | `count(*) … and e.settled_at is not null` — "after three **settled** nights the newcomer has their own footing" | A **count of settled nights**. Not a phase; a quantity that would change if the derived settle were substituted (an expired, never-stamped night would start counting). Left alone; flagged in §1.3, item 1. |
| B7 | `109_briefing_push.sql:155` | the briefing push | `where e.settled_at is null` | Which nights get a briefing. Not recency. Left alone; flagged in §1.3, item 5. |
| B8 | `119_glad_you_came.sql:260`, `:264` | `public.glad_you_came_queue_push()` | `public.glad_push_deliver_at(e.settled_at, r.time_zone)` (260) and `and e.settled_at is not null` (264) | It schedules the push **from the settle time**, and gates on a settled night. Left alone (119 is not in the whitelist) — but this is the one real hole the new rule opens; flagged in §1.3, item 2. |

#### C. Superseded definitions — dead in the migration chain, not live

These are earlier bodies of functions that a later migration replaces. They are
listed so the grep is complete, and they are **not** edited (rule 1 of
`Supabase/migrations/README.md`: never edit an applied migration).

| file:line | what it was | superseded by |
|---|---|---|
| `060_get_active_event_full_shape.sql:50` | `get_active_event` body | `106` → `107` → `115` |
| `063_get_active_event_unsettled.sql:31`, `:35` | `get_active_event` body | `106` → `107` → `115` |
| `087_calendar_persistence_and_member_toggle.sql:315`, `:320` | `get_active_event` body | `106` → `107` → `115` |
| `090_per_event_hidden_members.sql:155`, `:160` | `get_active_event` body | `106` → `107` → `115` |
| `092_multipack_events.sql:114` | `get_active_event` body | `106` → `107` → `115` |
| `080_auto_close_stale_events.sql:61`, `:63`; `081_auto_close_hours.sql:73`, `:76` | `auto_close_stale_events` writer | `115:787` |
| `107_night_lifecycle.sql:104`, `:117` | `get_active_event__inner` **live** branch | `115:101` |
| `107_night_lifecycle.sql:136`, `:154` | `get_active_event__inner` future branch | `115:101` |
| `107_night_lifecycle.sql:166-169` | `get_active_event__inner` **settled** branch | `115:101` |
| `033_v0_8_event_rsvps_and_arc.sql:44` | the DDL that added the column | — (history) |

Note on the live branch of `get_active_event__inner` (`115:122-144`): it filters
`e.settled_at is null` (140) **and** `e.played_at > now() - make_interval(hours => coalesce(r.auto_close_hours, 8))` (141). The second filter is the *negation* of the effective-settle condition, so an effectively-settled night can never reach the live branch, and the live branch's returned `settled_at` is correctly null. **No change needed** — and none is made, because the brief says keep every existing gate exactly as it is.

### 1.3 Consumers that are NOT phase-recency — the STOP-and-REPORT list

These are the consumers that derive at read would change the *meaning* of, or
that this lane cannot reach inside its whitelist. None of them is edited in
this lane; each is listed for the orchestrator.

1. **`105_anchor_push.sql:180` and `110_anchor_push_waking_hours.sql:230` — a
   count, not a phase.** Both count the newcomer's nights with
   `e.settled_at is not null` to decide when the newcomer stops being nudged
   ("first three settled nights"). Substituting the effective settle would make
   a night that expired without a host ever settling it *count* — a change in
   the quantity the rule is about, not a fix of a stale read. **Left unchanged.**
2. **`119_glad_you_came.sql:260`, `:264` — the push queue reads the settle
   time directly.** `glad_you_came_queue_push` inserts into
   `public.glad_push_queue` with `deliver_at = glad_push_deliver_at(e.settled_at, r.time_zone)`
   and the gate `e.settled_at is not null`. Under the new rule a night can be
   in its recap window **without** a physical stamp (it expired and nobody
   settled it), and `glad_can_send` (A4) will now let a member send a
   "glad you came" for it — but the queue trigger will then skip it, so the
   recipient's push never goes out. **Left unchanged** (119 is outside the
   whitelist); this is the one genuine behavioural hole the derive-at-read rule
   opens, and it needs a follow-up migration that computes the effective settle
   in the trigger.
3. **`107_night_lifecycle.sql:258` — `settle_event` on an expired night.**
   The guard is `v_settled_at is not null or v_played_at > now()`, so a night
   that expired 3 hours ago and was never settled can still be settled by the
   host, and `settled_at` is then stamped `now()` — three hours *later* than
   the night's true end. Under the new rule that night is already effectively
   settled at `played_at + window`, so the host's stamp would move it. The
   physical stamp wins (`coalesce(e.settled_at, …)`), so a night settled late
   reads `recap` from the late stamp rather than from its true end. **Left
   unchanged** (107 is an applied migration); worth a follow-up that stamps
   `played_at + window` when the night has already expired.
4. **`097` / `111` / `118` question box — a "settled?" predicate.** Turns stop
   when `v_e.settled_at is not null`. An expired, never-stamped night still has
   a null physical stamp, so the question box keeps offering turns for a night
   that ended hours ago. Deriving the settle here would close them at the
   right time. **Left unchanged** (three applied migrations, outside the
   whitelist).
5. **`109_briefing_push.sql:155` — the briefing sweep.** It selects
   `e.settled_at is null`, so an expired, never-stamped night still receives a
   briefing. **Left unchanged** (applied migration, outside the whitelist).
6. **`040_get_my_open_withdrawal_and_sweep.sql:77-78` — attestation sweep.**
   `e.settled_at is not null and e.settled_at + interval '24 hours' < now()`
   closes attestations for nights that have been settled for a day. This one
   *is* a recency read, so it is the one place where the derived settle would
   legitimately change behaviour (an attestation for a night that ended two
   days ago would close on schedule rather than never). **Left unchanged**
   (040 is an applied migration; the file is not in the whitelist).
7. **`107:75-76` — the dropped predecessors.** `get_active_event` and
   `get_active_event__inner` are dropped and recreated by 107 and redefined by
   115; the live bodies are the ones listed in §1.2.

### 1.4 Same-named columns on other tables — out of scope, do not touch

| table | where | what it means |
|---|---|---|
| `public.seat_deposits.settled_at` | DDL `043:30`; writes `043:169`, `043:174`, `085:363`, `085:498`, `085:569`, `085:624`, `113:104`, `114:101`, `115:480` | when the **deposit** was returned / forfeited / waived. Its own ledger fact; the night's end time has nothing to do with it. |
| `public.casino_withdrawals.settled_at` | `041:166-171`; referenced in the comments at `089:76-78` and `095:1912-1914` | when the **withdrawal bracket** was closed. Same: its own fact. (On live, the table has neither `event_id` nor `settled_at` — `089`.) |

Neither is an `events.settled_at` consumer. Neither is touched.

### 1.5 The writer being demoted: `public.cron_close_stale()`

| | |
|---|---|
| Live definition | `Supabase/migrations/120_night_ends_itself.sql:336-374` — the function body is unchanged from `120_stale_close_cron.sql:76-112`, which was **never applied** and has been removed |
| Signature | `public.cron_close_stale() returns integer` |
| Security | `security definer`, `set search_path = public` (341-342); `revoke all … from public, anon, authenticated` (374) — no app role may run it |
| Body | stamps `settled_at = e.played_at + make_interval(hours => v_room.auto_close_hours)` for every live room's unsettled, expired nights (357-361); then one global `public.close_stale_attestations()` call (368) |
| Schedule | was `cron.schedule('gr-stale-close', '17 * * * *', …)` — **hourly at minute 17**; now `cron.schedule('gr-stale-close', '17 3 * * *', …)` — **daily at 03:17**, still inside the pg_cron guard |
| Idempotent | yes — `and e.settled_at is null` (360) means a second run closes nothing (probes `120.s`) |

**The change:** the body stays exactly as it is — it stamps the same derived
value the reads now derive — and the schedule drops from hourly to **daily at
03:17** (`'17 3 * * *'`). Nothing waits on it any more: the reads do not
depend on a writer having run, so the janitor is hygiene (it keeps the physical
column tidy for the queries in §1.3 that still read it directly), not the
correctness path.

### 1.6 The Swift twin

`NightPhaseResolver` is a **single type**, in `GamesRoom/Services/NightPhase.swift`
(not a file of its own). `grep -rn "NightPhaseResolver" GamesRoom/` → 20 hits,
all call sites plus the type itself. The rule is at `NightPhase.swift:130-143`:

```swift
static func phase(_ facts: NightFacts) -> NightPhase {
    guard let playedAt = facts.playedAt else { return .none }
    if playedAt > facts.now { return .upcoming }
    let windowEnd = playedAt.addingTimeInterval(TimeInterval(facts.autoCloseHours) * 3_600)
    let effectiveSettledAt = facts.settledAt ?? (facts.now >= windowEnd ? windowEnd : nil)
    if let settledAt = effectiveSettledAt {
        return settledAt > facts.now.addingTimeInterval(-recapWindow) ? .recap : .past
    }
    return facts.now < windowEnd ? .live : .stranded
}
```

That body is the **migration-120** rule — AD1 found the old 115 rule here and
AD4 rewrote it; §1.10 has the diff and the test table that pins it. The file's
header comment (lines 10-13) now names migration 120 as the twin, and the
`NightPhase.stranded` doc (lines 55-61) says the case is unreachable by
design.

`recapWindow = 86_400` (95), `defaultAutoCloseHours = 8` (99). The doc comment
at 101-129 spells out the branch order the SQL must match.

The client-side mirror of the *recap query* is
`GamesRoom/Services/InMemoryRoomStore.swift:1080-1088`
(`fetchRecentSettledEvent`), which filters on a non-null `settledAt` inside
the 24 h window — the in-memory twin of `get_recent_settled_event`. It reads
`event.settledAt`, the value the server now returns *already derived*, so the
live store is unchanged; the fake store is a fake of the server's answer, and
its rows carry whatever the fake seeded. **The fake does not derive** — see
§1.10, item 1.

Table tests: `TestsP1.swift:29-…` (`runP1NightPhaseTests`) over a pinned clock
(`now = Date(timeIntervalSince1970: 1_800_000_000)`, line 30) — the clock is
pinned because the SQL twin is `IMMUTABLE` and takes `p_now`. The table now has
27 rows, several of them exact boundaries ("exactly at `played_at +
auto_close_hours` is `.recap`", line 67). `TestsGladYouCame.swift:117`
enumerates every `NightPhase` case including `.stranded`.

**No XCUITest or screenshot-sweep seed asserts the `stranded` rendering** —
`grep -rn "stranded" --include="*.swift"` over the whole repo returns no hit
under `GamesRoomUITests/`. The `stranded` case therefore has no UI test to
repoint, and no UI test is edited in this lane.

### 1.7 The change list this lane made

| step | file | change |
|---|---|---|
| AD2 | `Supabase/migrations/120_night_ends_itself.sql` (new; `120_stale_close_cron.sql` removed in the same commit) | rewrite `night_phase`, `get_recent_settled_event`, `get_active_event__inner`; keep `cron_close_stale`'s body, move its schedule to `'17 3 * * *'`; header comment states WHY (the end time is known at booking; the stamp is hygiene) |
| AD3 | `Supabase/tests/120_probes.sql` | replaced with the derive-at-read probe set |
| AD4 | `GamesRoom/Services/NightPhase.swift` + `TestsP1.swift` (+ `main.swift`, one test assertion) | mirrored the effective settle in `NightPhaseResolver.phase`; extended the table test; repointed the four tests that pinned the now-unreachable `stranded` (§1.10) |
| AD5 | `docs/STATE-MACHINES.md` (Night phase section only) + this report | the Night phase section rewritten (§1.11); this report finished |

### 1.8 Migration 120 — what it changed

`Supabase/migrations/120_stale_close_cron.sql` is **removed** (it was never
applied) and replaced by `Supabase/migrations/120_night_ends_itself.sql`, which
rewrites three readers and demotes the janitor:

| function | change |
|---|---|
| `public.night_phase` | the recap/past branches read the **effective** settle; `stranded` stays as the final, unreachable `else` |
| `public.get_active_event__inner` | the settled leg keys on the effective settle and **returns** it as `settled_at`; the live and future legs are byte-for-byte unchanged |
| `public.get_recent_settled_event` | same, behind the same membership gate and the same hidden-member filter |
| `public.cron_close_stale` | body unchanged; the schedule moves from `'17 * * * *'` to `'17 3 * * *'`; SECURITY DEFINER, `search_path`, the revoke and the pg_cron guard are unchanged |

**The branch order.** The brief pins the order `none > upcoming > live >
recap > past`. Two details make that work:

- The `live` branch additionally requires **no effective settle**
  (`settled_at is null and now < played_at + window`). Without that clause a
  night the host settled *early* — played 2 h ago, settled 1 h ago, window 8 h
  — would read `live`, because it is still inside its window. `115.a` pins
  that row as `recap`, and it still reads `recap`: the effective settle is the
  host's stamp, so the night has ended.
- `stranded` is the final `else`, not a branch. It is **unreachable**: a null
  effective settle means `now` has not reached the window end, so the `live`
  branch took the row.

**The behavioural diff**, checked over the whole phase table (120 input
combinations of played/settled × window 8 h/24 h): exactly two classes change.

| input | old | new | why |
|---|---|---|---|
| expired, never stamped, ended inside 24 h | `stranded` | `recap` | **the point of the lane** — the night ended; it no longer waits for a janitor |
| expired, never stamped, ended more than 24 h ago | `stranded` | `past` | same |
| future night that carries a physical stamp | `recap`/`past` | `upcoming` | unreachable: `settle_event` refuses to settle a night that has not started (`107:258`), and `create_event` writes `settled_at = null` |

Everything else is unchanged, including the early-settle row (`recap`), the
7 h 59 m row (`live`), the exactly-at-the-boundary row (`stranded` → `recap`,
the one intended difference) and the host's own stamp (it wins).

> [!WARNING]
> **`Supabase/tests/115_probes.sql:145-146` is now stale.** It asserts
> `night_phase(now - 8 hours, null, 8, now) = 'stranded'` and the same at
> 9 hours. After this migration both read `recap` — the night's true end is
> inside the 24 h recap window — and the probe will report FAIL. The file is
> outside this lane's whitelist, so it is **not edited here**: the
> orchestrator repoints those two rows the way it repoints the UI tests.
> `TestsP1.swift` carries the same pinned row and is repointed in AD4.

### 1.9 The probe set — what it pins

`Supabase/tests/120_probes.sql` is replaced. The old file tested the
**janitor** (the hourly tick was the correctness path); the new file tests
the **derive**, and keeps the janitor's own probes because the janitor still
has to be a correct writer (it is hygiene, but it is still a writer).

**Brief letter → probe id**

| brief | probe id | what it pins |
|---|---|---|
| (a) | `120.a-headline-no-tick`, `-phase`, `-read`, `-active` | a never-stamped night 8 h 01 m past its start reads `recap` through `night_phase` **and** through `get_recent_settled_event` **and** through `get_active_event`; the returned `settled_at` is `played_at + 8 h`; the physical column is still `NULL` — no writer ran |
| (b) | `120.b-phase-live`, `-no-recap-yet`, `-active-live` | a night 7 h 59 m past its start is still `live`, is not a recap, and is still the live night on the room page |
| (c) | `120.c-phase-upcoming`, `-no-recap`, `-active-upcoming` | a night two days out is still `upcoming` |
| (d) | `120.d-host-stamp-phase`, `-host-stamp-wins`, `-order-by-effective-settle` | the host's own stamp is returned unchanged, and recency keys on the **effective** settle: a derived end (now − 1 m) outranks an older host stamp (now − 2 h) — under the old rule the derived night was not a candidate at all |
| (e) | `120.e-phase-past`, `-no-recap` | an expired night 40 h old reads `past`, never `stranded`, and is out of the recap window |
| (f) | `120.f-non-member-gated`, `-member-sees`, `-hidden-filter`, `-hidden-filter-control` | the membership gate still turns a non-member away, the member still gets the recap, and the hidden-member filter still hides the night from the member it names (with a control that empties the list) |
| (g) | `120.u-cron-job-count`, `120.v-cron-job-shape` | no job is registered without pg_cron; with pg_cron the job is `gr-stale-close` at **`'17 3 * * *'`** (was `'17 * * * *'`) calling `public.cron_close_stale()` |
| (h) | `120.i-*` … `120.t-*` | the old janitor probes, reused verbatim: it stamps `played_at + the room's window`, leaves a night inside its window, an already-settled night, a wider-window room's night and a soft-deleted room alone, closes the 25 h-old attestation, returns the number of rows it closed, and a second call changes nothing |

The janitor's **security** contract (the old probes `120.a` … `120.h`) is
reused too, renumbered `120.sec1-…` … `120.sec8-` so it does not collide with
the new derive probes: the function exists, it is `SECURITY DEFINER` with
`search_path=public`, its contract is documented, no app role holds an
execute grant, and the call itself is refused with 42501 under both
`authenticated` and `anon`.

**One new probe that is not in the brief:**
`120.derive-write-agrees` — it reads the derived end *before* the janitor
runs, runs the janitor, and asserts the janitor wrote **exactly** that
value. That is the invariant this lane rests on: deriving and stamping
agree by construction, so the physical column only ever catches up with what
the reads already said.

**Two things the file does that the old one did not.**

1. *It re-anchors its own fixtures.* Every block sets the timestamps it
   reads relative to `now()` before it asserts anything. `now()` is the
   transaction timestamp, so the fixture and the assertions inside one
   block see the same clock, however long the file took to get there. The
   margins the brief asks for (8 h 01 m past, 7 h 59 m past) are exact
   inside a block instead of approximate.
2. *It runs the derive probes before the janitor probes.* The janitor stamps
   every expired night in the replica, so running it first would write the
   very column probe (a) asserts is `NULL`.

**Deviations, recorded**

- **Probe style.** The brief asks for `select 'PROBE … ' || case … end`.
  The file uses `raise notice 'PROBE … %', case … end` — the style of the
  107/115/119 probe files, and the style lane B's version of this file
  already used (recorded there as a deviation). A bare `SELECT` inside a
  `DO` block is discarded by plpgsql, so the notice form is the one that
  carries a multi-step probe; every probe still prints exactly one
  `PROBE <id> PASS|FAIL …` line, and `grep PROBE` still finds them all.
- **Probe ids.** The brief's letters are the ids of the derive probes
  (`120.a-…` … `120.f-…`); (g) and (h) map onto the old `120.u`/`120.v` and
  `120.i`…`120.t`, which are reused under their old ids so the diff against
  the previous file is readable.
- **The probes have still never been executed** against a live or replica
  database — this lane has no database. What was verified here: the file
  parses (pglast, 29 statements) and every assertion was checked against a
  model of the AD rules (`night_phase`, the two readers and the janitor
  sweep) — 31 modelled assertions, 0 that would fail.

### 1.10 The Swift twin — the rule, the test table, the twin check

`GamesRoom/Services/NightPhase.swift` — the resolver body is now the mirror of
migration 120's `night_phase`, branch for branch:

```swift
guard let playedAt = facts.playedAt else { return .none }
if playedAt > facts.now { return .upcoming }
let windowEnd = playedAt.addingTimeInterval(TimeInterval(facts.autoCloseHours) * 3_600)
let effectiveSettledAt = facts.settledAt ?? (facts.now >= windowEnd ? windowEnd : nil)
if let settledAt = effectiveSettledAt {
    return settledAt > facts.now.addingTimeInterval(-recapWindow) ? .recap : .past
}
return facts.now < windowEnd ? .live : .stranded
```

The effective settle is the host's own stamp when there is one, and otherwise
the night's true end (`played_at + auto_close_hours`) once the clock has
reached it. `live` still requires **no** effective settle, so a night the host
settled early reads `recap`, never `live`. `stranded` is the last branch and is
**unreachable** — a nil effective settle means the clock has not reached the
window end, so the `live` branch took the row. It stays in the vocabulary
because the SQL keeps it as its own fallback.

The header comment and the `NightPhase.stranded` doc comment were updated in
the same commit: the file now says it mirrors migration **120** (not 115), and
`stranded` is documented as unreachable by design.

**The table tests** (`TestsP1.swift:29-…`, `runP1NightPhaseTests`, pinned clock
at line 30) were extended, not replaced. The pinned `stranded` rows are now
`recap` — they were the rows that said "the window is gone, nothing ran":

| row | was | now | why |
|---|---|---|---|
| exactly at `played_at + auto_close_hours` | `.stranded` | `.recap` | the effective settle lands exactly on `now` |
| one second past the window | `.stranded` | `.recap` | the night ended a second ago |
| a night nine hours old, never settled | `.stranded` | `.recap` | its true end was an hour ago |
| `autoCloseHours` moves the live line | `.stranded` | `.recap` | same, one row over |
| `autoCloseHours` 0, a just-started night | `.stranded` | `.recap` | the window is zero hours, so the night ended at once |
| a night in the future carrying a stamp | `.recap` | `.upcoming` | the branch order changed: `upcoming` runs before the settle branches (120) |

Five rows were **added** for the rule the lane introduces:

| row | pins |
|---|---|
| a night whose true end was 24 h ago | `.past` — the effective settle is `played_at + 8 h`, not `now()`, so a 32-hour-old night is past and never waited for a writer |
| one second inside that recap window | `.recap` |
| a night two days old, never settled | `.past` |
| the host's own stamp wins over the derived end | a night settled an hour ago reads `.recap`, not `.live` |
| an old host stamp still wins over a fresher derived end | settled 25 h ago on a 30-hour-old night reads `.past`, even though the derived end would be 22 h ago (inside the window) |

**The twins were checked against each other mechanically.** The resolver was
extracted verbatim into a throwaway harness (`/tmp`, not committed) and run
over a grid of 990 input combinations (18 played offsets × 11 settled offsets ×
5 auto-close windows, including every exact boundary: the window end, the
24-hour recap edge, `now` itself). The Swift answers were compared with a
model of migration 120's `night_phase`:

```
rows compared: 990
Swift-vs-SQL120 mismatches: 0
rows reaching 'stranded' under the new rule: 0
```

The same grid was also run against the **old** Swift rule and the **old** SQL
rule (115): they agreed with each other on all 990 rows, so the change is
symmetric — the twins moved together, and they moved together only in the two
classes AD2 documented (§1.8): an expired never-settled night stops being
`stranded`, and a future night carrying a physical stamp reads `upcoming`
instead of `recap`/`past` (unreachable: `settle_event` refuses to settle a
night that has not started).

#### What else AD4 had to repoint, and what was left alone

Four tests elsewhere in the tree derived a phase from facts and expected
`stranded`. `stranded` is now unreachable, so they could not be left alone —
the gate has to be green — and each one was repointed to the new truth:

| test | was | now |
|---|---|---|
| `TestsP1.swift` — a stranded night outranks the next scheduled night | the expired night took the active slot | the next scheduled night takes the active slot; the expired night is the recap on the server |
| `TestsP1.swift` — a stranded night is `.inPlay` | `.inPlay(event)` | `.justSettled(event)` |
| `TestsP1.swift` — a stranded night stays `.inPlay` even before the viewer plays | `.inPlay(event)` | `.justSettled(event)` |
| `main.swift` — `MascotEngine.footerKind` for a stranded night | `.settleRound` | `.postPlayRecap` |

The `main.swift` edit is outside the brief's "list lines only" whitelist for
that file. It is there because the MascotEngine test lives in `main.swift` and
the gate is not allowed to go red: the rule is "fix your change, never the
gate".

**STOP-AND-REPORT — left unchanged, for the orchestrator**

1. **The fake store does not derive.** `InMemoryRoomStore.fetchActiveEvent`
   (`GamesRoom/Services/InMemoryRoomStore.swift:1053-1075`) still has its
   `.stranded` leg at line 1068 — dead code now — and
   `fetchRecentSettledEvent` (1080-1088) still filters on a **physical**
   `settledAt`. So in the fake an expired never-settled night is invisible: it
   is neither the active slot nor a recap. On the server it **is** the recap
   (migration 120 returns it with the derived settle). The file is outside this
   lane's whitelist and was not edited.
2. **Stale doc comments that still describe `stranded` as a live state** (each
   is now a second copy of a rule the doc has to match):
   `GamesRoom/Models/V0State.swift:24-26` and `:41`,
   `GamesRoom/Services/MascotEngine.swift:249`,
   `GamesRoom/Services/NightPlan.swift:24` and `:107-109`,
   `GamesRoom/Services/RoomStore.swift:398`,
   `GamesRoom/Models/NextNight.swift:101`.
3. **The product consequence, unasked for and undecided.** `NightPlan`'s
   `.stranded` branch (`GamesRoom/Services/NightPlan.swift:121-123`) is the
   only place that offered the host a "settle the night" action for a night
   that ran past its window, and it is now dead. The host still gets
   `.settleNight` for a **live** night (`NightPlan.swift:124` → `hostClosing`),
   but a night that overran its window now simply ends and reads as a recap.
   That is the lane's intent ("the night ends itself"), but it removes the
   host's last say over an over-window night, so Nathan should confirm it is
   wanted.
4. `Supabase/tests/115_probes.sql:145-146` is still stale (§1.8).

No UI test, screenshot seed or migration was touched in AD4. `TestsP1.swift`
was already registered in `build-and-run-tests.sh` and `main.swift`, so no
registration line changed.

### 1.11 The state-machines doc (AD5)

`docs/STATE-MACHINES.md` §1 "Night phase" is the one section that names the
phase machine, so it is the one place that had to change. It was rewritten to:

- say that `stranded` is **unreachable by design** since migration 120 and
  stays in the vocabulary as a safety fallback on both sides — the old text
  said "at or past that line it is `.stranded`", which is now false;
- state the **effective settle** as the rule (the host's own stamp when there
  is one, otherwise `playedAt + autoCloseHours` once `now` has reached it) and
  why it is derivable — the end of a night is known at booking time;
- keep the branch order exact: `upcoming` first, `.live` needs **no** effective
  settle, an effective settle inside 24 h is `.recap` and older than that is
  `.past`;
- point the **server twin** at `120_night_ends_itself.sql` (it named 115) and
  say that both readers key recency on the effective settle and return it as
  `settled_at`;
- add a **Hygiene** line: `public.cron_close_stale()` stamps the same derived
  value daily at 03:17 (`'17 3 * * *'`), and nothing waits on it;
- repoint the **pin** from `P1: exactly at played_at + auto_close_hours is
  .stranded` to `... is .recap`, and add the derived-end row (`P1: a night
  whose true end was 24h ago is .past`);
- add to the **Never** line: never key recency on the physical `settled_at`
  column — it stays null until somebody writes it, so the effective settle is
  the only thing that says when a night ended.

The other fifteen sections were read and **needed no change**: their "never"
lines are about their own machines (the slot, the plan, the offer, the queue),
not about the phase rule, and their pins still exist and still pass. The one
that mentions `stranded` is §12 (Night plan), whose pin
`P1: a stranded night asks the host to settle it` still exists and still
passes — it pins `NightPlan.plan` against a `.stranded` input directly, and
`NightPlan` still handles that case; it is the *resolver* that can no longer
produce one (§1.10, item 3). Re-pointing that section is the orchestrator's
call, not this lane's: the brief scopes this file to the Night phase section.

---

## 2. What is still open for the orchestrator

Nothing below was edited by this lane. Each item is a place where the new rule
is *not* reflected, or where the product needs a decision.

1. **Stale probe rows.** `Supabase/tests/115_probes.sql:145-146` still assert
   `night_phase(now - 8 hours, null, 8, now) = 'stranded'` and the same at
   9 hours. Both read `recap` under migration 120, so those probes will report
   FAIL. The file is an applied migration's probe file and is outside this
   lane's whitelist.
2. **The fake store does not derive.** `InMemoryRoomStore.fetchActiveEvent`
   (1053-1075) keeps its now-dead `.stranded` leg at 1068, and
   `fetchRecentSettledEvent` (1080-1088) still filters on a **physical**
   `settledAt`. In the fake an expired never-settled night is invisible; on the
   server it is the recap. Outside the whitelist.
3. **Stale doc comments** that still describe `stranded` as a live state:
   `V0State.swift:24-26` and `:41`, `MascotEngine.swift:249`,
   `NightPlan.swift:24` and `:107-109`, `RoomStore.swift:398`,
   `NextNight.swift:101`. Each is now a second copy of a rule the doc has to
   match. Outside the whitelist.
4. **A dead host affordance, and a product question.** `NightPlan`'s
   `.stranded` branch (121-123) was the only place that offered the host a
   "settle the night" action for a night that ran past its window. It is dead.
   A live night still offers `.settleNight` (124 → `hostClosing`), but an
   over-window night now simply ends and reads as a recap. That is the lane's
   intent, but it removes the host's last say over an over-window night —
   Nathan should confirm it is wanted.
5. **The consumers that still read the physical column.** §1.3 lists all six
   with the reasoning; the two that need a follow-up migration are the
   newcomer-anchor **count** (105:180, 110:230 — a quantity, not a phase) and
   the **glad-you-came push queue** (119:260/264 — the one real behavioural
   hole: `glad_can_send` now lets a member send for a night that expired
   without a stamp, but the queue trigger still skips it, so the push never
   goes out).
6. **`settle_event` stamps `now()` on an already-expired night** (107:258/263):
   a night that expired three hours ago and was never settled can still be
   settled by the host, and the stamp lands three hours later than the night's
   true end — and the physical stamp wins. Worth a follow-up that stamps
   `played_at + window` when the night has already expired.
7. **Live apply is Nathan-gated and was not done.** This lane never touched a
   database.

---

## 3. How this lane was verified

| check | result |
|---|---|
| `bash .maestro/fastgate.sh` | `FASTGATE: PASS` — 630 cases, 74/74 SwiftUI parse-checks |
| `Supabase/migrations/120_night_ends_itself.sql` parses | yes (pglast, 18 statements) |
| `Supabase/tests/120_probes.sql` parses | yes (pglast, 29 statements) |
| old rule vs new rule, over the phase table | 120 input combinations; the only differences are the two intended classes (§1.8) |
| Swift twin vs a model of migration 120 | 990 input combinations (18 played offsets × 11 settled offsets × 5 windows, every exact boundary included); **0 mismatches**; 0 rows reached `stranded` |
| old Swift rule vs old SQL rule (115) on the same grid | 990/990 agreement — the twins moved together |
| the probe assertions, checked against a model of the AD rules | 31 modelled assertions, 0 that would fail |
| the probes, executed against a database | **never** — this lane has none |

The probes are the one thing that has not been run for real. Before migration
120 is applied anywhere, `Supabase/tests/120_probes.sql` and
`Supabase/tests/115_probes.sql` should both be run against a replica.

