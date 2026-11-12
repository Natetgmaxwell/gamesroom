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

## 1. Facts (AD1)

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
  `cron_close_stale` already write (`115:820`, `120:99`), so the derived value
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
| Live definition | `Supabase/migrations/120_stale_close_cron.sql:76-112` (**unapplied**) |
| Signature | `public.cron_close_stale() returns integer` |
| Security | `security definer`, `set search_path = public` (80-81); `revoke all … from public, anon, authenticated` (114) — no app role may run it |
| Body | stamps `settled_at = e.played_at + make_interval(hours => v_room.auto_close_hours)` for every live room's unsettled, expired nights (99-102); then one global `public.close_stale_attestations()` call (108) |
| Schedule | `cron.schedule('gr-stale-close', '17 * * * *', …)` (125) — **hourly at minute 17**, inside the pg_cron guard (122-129) |
| Idempotent | yes — `and e.settled_at is null` (101) means a second run closes nothing (probes `120.s`) |

**The change:** the body stays exactly as it is — it stamps the same derived
value the reads now derive — and the schedule drops from hourly to **daily at
03:17** (`'17 3 * * *'`). Nothing waits on it any more: the reads do not
depend on a writer having run, so the janitor is hygiene (it keeps the physical
column tidy for the queries in §1.3 that still read it directly), not the
correctness path.

### 1.6 The Swift twin

`NightPhaseResolver` is a **single type**, in `GamesRoom/Services/NightPhase.swift`
(not a file of its own). `grep -rn "NightPhaseResolver" GamesRoom/` → 20 hits,
all call sites plus the type itself. The rule is at `NightPhase.swift:102-110`:

```swift
static func phase(_ facts: NightFacts) -> NightPhase {
    guard let playedAt = facts.playedAt else { return .none }
    if let settledAt = facts.settledAt {
        return settledAt > facts.now.addingTimeInterval(-recapWindow) ? .recap : .past
    }
    if playedAt > facts.now { return .upcoming }
    let windowEnd = playedAt.addingTimeInterval(TimeInterval(facts.autoCloseHours) * 3_600)
    return facts.now < windowEnd ? .live : .stranded
}
```

`recapWindow = 86_400` (83), `defaultAutoCloseHours = 8` (87). The doc comment
at 89-101 spells out the branch order the SQL must match. The `stranded` case
is at 109.

The client-side mirror of the *recap query* is
`GamesRoom/Services/InMemoryRoomStore.swift:1080-1088`
(`fetchRecentSettledEvent`), which filters on a non-null `settledAt` inside
the 24 h window — the in-memory twin of `get_recent_settled_event`. It reads
`event.settledAt`, the value the server now returns *already derived*, so the
live store is unchanged; the fake store is a fake of the server's answer, and
its rows carry whatever the fake seeded.

Table tests: `TestsP1.swift:29-99` (`runP1NightPhaseTests`) — 13 rows over a
pinned clock (`now = Date(timeIntervalSince1970: 1_800_000_000)`, line 30).
Rows 3, 7, 10 and 11 are exact-boundary rows ("exactly at `played_at +
auto_close_hours` is `.stranded`", line 57). `TestsGladYouCame.swift:117`
enumerates every `NightPhase` case including `.stranded`.

**No XCUITest or screenshot-sweep seed asserts the `stranded` rendering** —
`grep -rn "stranded" --include="*.swift"` over the whole repo returns no hit
under `GamesRoomUITests/`. The `stranded` case therefore has no UI test to
repoint, and no UI test is edited in this lane.

### 1.7 The change list this lane will make

| step | file | change |
|---|---|---|
| AD2 | `Supabase/migrations/120_night_ends_itself.sql` (new; `120_stale_close_cron.sql` removed in the same commit) | rewrite `night_phase`, `get_recent_settled_event`, `get_active_event__inner`; keep `cron_close_stale`'s body, move its schedule to `'17 3 * * *'`; header comment states WHY (the end time is known at booking; the stamp is hygiene) |
| AD3 | `Supabase/tests/120_probes.sql` | replace with the derive-at-read probe set |
| AD4 | `GamesRoom/Services/NightPhase.swift` + `TestsP1.swift` | mirror the effective settle in `NightPhaseResolver.phase`; extend the table test |
| AD5 | `docs/STATE-MACHINES.md` (Night phase section only) + this report | the doc, and the finished report |

### 1.8 What AD2 changed, and what it found

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

---
