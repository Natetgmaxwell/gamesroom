---
type: report
title: "Task B — server-side stale close (pg_cron)"
created: 2026-11-11
tags:
  - janitor
  - pg-cron
  - stale-close
  - supabase
related:
  - '[[AGENTS]]'
  - '[[STATE-MACHINES]]'
---

# Task B — server-side stale close (pg_cron)

Replaces the client-side lazy janitor writes with a scheduled server job.
Lane scope: SQL + probes + this report. **No Swift file is touched here**, and
**nothing is applied to the live database** — live apply is Nathan-gated.

---

## 1. Facts (B1)

### 1.1 `public.auto_close_stale_events(p_room_id uuid) → integer`

| | |
|---|---|
| Live definition | `Supabase/migrations/115_state_machine_guards.sql:787` (supersedes `080_auto_close_stale_events.sql:37` and `081_auto_close_hours.sql:47`) |
| Signature | `public.auto_close_stale_events(p_room_id uuid) returns integer` |
| Schema | `public` |
| Language | `plpgsql` (volatile) |
| Security | `security definer`, `set search_path = public` |
| Grants | `revoke all on function public.auto_close_stale_events(uuid) from public, anon;` + `grant execute … to authenticated, service_role;` (`115:832-833`) |
| Return | `integer` — the number of `events` rows closed (`get diagnostics v_closed = row_count`, `115:827-828`) |
| Scope | **per-room** — takes `p_room_id`, writes only that room's events |

**Guards, in order**

1. `v_caller := public.current_user_id();` — if null →
   `raise exception 'Not authenticated' using errcode = '42501'`
   (`115:794-799`). `public.current_user_id()` is
   `NULLIF(current_setting('request.jwt.claims', true)::json->>'sub','')::uuid`
   (`005_fix_rls_recursion.sql:31-38`) — it reads the JWT `sub` claim out of
   the session GUC, so with **no JWT in the session it is NULL**.
2. Member gate — the caller must own a `public.room_memberships` row for
   `p_room_id`, else
   `raise exception 'Not a member of this room' using errcode = '42501'`
   (`115:801-807`).

**What it stamps** (`115:819-825`)

```sql
update public.events e
   set settled_at = e.played_at + make_interval(hours => r.auto_close_hours)
  from public.rooms r
 where e.room_id = p_room_id
   and e.settled_at is null
   and e.played_at < now() - make_interval(hours => r.auto_close_hours)
   and r.id = p_room_id;
```

- Stamps `events.settled_at` at **played_at + the room's `auto_close_hours`** —
  the moment the night stopped being live — **not `now()`**. A month-old
  stranded night therefore reads `past`, never a fresh `recap`
  (`115:813-818`; the phase rule is `public.night_phase`, `115:68`).
- The window rides the room row: `rooms.auto_close_hours integer not null
  default 8` (`081_auto_close_hours.sql:31`).
- Only unsettled rows qualify (`settled_at is null`), and only nights whose
  window has passed (`played_at < now() - window`) — so it is idempotent and
  leaves a night that is still inside its window untouched.

**Cron consequence (decides the step-2 design).** Guards 1–2 make this
function **uncallable from a pg_cron session**: cron runs as `postgres` with
no JWT, so `current_user_id()` is NULL and the call raises `42501` before a
single row is touched. A wrapper therefore cannot simply
`perform public.auto_close_stale_events(id)` per room; the write has to be
done by the wrapper itself as SECURITY DEFINER (the repo precedent is
`public.question_box_cron_tick`, `097_question_box.sql:820`, which does its
own update rather than calling a client-facing RPC).

### 1.2 `public.close_stale_attestations() → integer`

| | |
|---|---|
| Live definition | `Supabase/migrations/061_rpc_contract_audit.sql:446` (mirrors `029_casino_self_attest.sql:263`) |
| Signature | `public.close_stale_attestations() returns integer` — **no parameters** |
| Schema | `public` |
| Language | `sql` |
| Security | `security definer`, `set search_path = public` |
| Grants | `grant execute on function public.close_stale_attestations() to authenticated;` (`061:462`) — there is **no matching `revoke … from public`**, and `104_lockdown_internal_functions.sql` does not list this function, so PUBLIC's default EXECUTE grant still stands |
| Return | `integer` — the number of attestation rows closed |
| Scope | **global** — no room parameter, no room filter, no auth guard |

**Semantics** (`061:452-459`)

```sql
with closed as (
  update public.settlement_attestations
     set closed_at = now()
   where closed_at is null
     and now() > opened_at + interval '24 hours'
  returning id
)
select count(*)::integer from closed;
```

- Stamps `settlement_attestations.closed_at` at **`now()`** — unlike function
  1 there is no anchor other than the row itself.
- Guard: `closed_at is null` and the row has been open for more than 24 h
  (`opened_at timestamptz not null default now()`, `029_casino_self_attest.sql:32`).
- Idempotent: a second call matches nothing.
- Because it is global and guard-free, a cron job calls it **once**, not once
  per room.

### 1.3 Client cadence today (pull-driven, both sides)

**Events — `RoomService`**

- `GamesRoom/Services/RoomService.swift:102` — `private var lastAutoCloseAt:
  [UUID: Date] = [:]` (V0.82): a **per-room** dictionary of last-fire times.
- `GamesRoom/Services/RoomService.swift:282` — `lastAutoCloseAt = [:]` on
  reset, so a reset re-arms the first fire.
- `GamesRoom/Services/RoomService.swift:482` — `func loadActiveEvent(roomId:
  force:) async -> Event?`.
- `GamesRoom/Services/RoomService.swift:488-495` — inside `loadActiveEvent`:
  fires `store.autoCloseStaleEvents(roomId:)` when
  `lastAutoCloseAt[roomId] == nil || now.timeIntervalSince(lastAutoCloseAt[roomId]!) > 60`
  — **at most once per 60 s per room**. The timestamp is written *before* the
  call and failures are swallowed (`try?`), so a failed RPC still burns the
  window.
- `GamesRoom/Services/RoomStore.swift:431-437` — `autoCloseStaleEvents(roomId:)`
  → `rpc("auto_close_stale_events", params: ["p_room_id": roomId.uuidString])`;
  the returned count is discarded by the caller.

**Attestations — `CasinoService`**

- `GamesRoom/Services/CasinoService.swift:103` — `private var lastStaleCloseAt:
  Date?` (V0.69): a single **process-wide** timestamp, not per-room.
- `GamesRoom/Services/CasinoService.swift:127` — `private let staleCloseTTL:
  TimeInterval = 60`.
- `GamesRoom/Services/CasinoService.swift:382-395` — `getMyOpenAttestations()`
  fires `rpc("close_stale_attestations")` when
  `lastStaleCloseAt == nil || now.timeIntervalSince(lastStaleCloseAt!) > staleCloseTTL`
  — **at most once per 60 s for the whole app**, failures swallowed by
  `try?`. The read itself is then TTL-cached for 30 s
  (`casinoCacheTTL`, `CasinoService.swift:123`).

**Consequence.** Both finalizers are *side effects of a read*. A room nobody
opens never finalizes its stranded night; an attestation nobody looks at stays
open past 24 h. That is the gap this lane closes.

### 1.4 Migration-chain facts that constrain step 2

- **118 is already taken on this branch.** `Supabase/migrations/118_question_box_depth.sql`
  exists (and `119_glad_you_came.sql` after it). `Supabase/migrations/README.md`
  rule 2 forbids renumbering and rule 3 says "take the highest existing number
  and increment", so the next free number is **120**. The brief names
  `118_stale_close_cron.sql`; that number cannot be used. Recorded, not
  guessed — see §5.
- **`cron.schedule` already exists in the chain.** Job names in use:
  `briefing-push-tick` (`109_briefing_push.sql:415`), `question-box-tick`
  (`097_question_box.sql:848`), `anchor-push-tick`
  (`110_anchor_push_waking_hours.sql:423`), `close_unscanned_attestations_15min`
  (`040_get_my_open_withdrawal_and_sweep.sql:102`). The name the brief
  specifies, `gr-stale-close`, is **not** among them — no collision.
- **The guarded-schedule idiom is already established**: `if exists (select 1
  from pg_extension where extname = 'pg_cron') then perform cron.unschedule(…);
  perform cron.schedule(…); else raise notice …; end if;` —
  `097:846-850`, `109:413-417`, `110:421-425`, `040:101-108`.
- **The lockdown precedent for a scheduler-only function** is
  `104_lockdown_internal_functions.sql`: revoke from `public, anon,
  authenticated`, grant to `service_role` only; and
  `097_question_box.sql:843` (`revoke all on function
  public.question_box_cron_tick() from public;`).
- `public.rooms.deleted_at timestamptz` (`052_room_delete.sql:35`) marks a
  soft-deleted room — the same "eligible rooms" filter
  `question_box_cron_tick` uses (`r.deleted_at is null`, `097:833`).
- Live apply is Nathan-gated: migrations carry their own apply command in the
  header and are applied by hand/TARS. This lane applies nothing.

---

## 2. Wrapper design

`Supabase/migrations/120_stale_close_cron.sql` adds one function and one
guarded schedule.

### 2.1 `public.cron_close_stale() → integer`

```sql
create or replace function public.cron_close_stale()
returns integer
language plpgsql
volatile
security definer
set search_path = public
```

SECURITY DEFINER, `search_path = public`, matching the house shape of every
other cron entry point (`109_briefing_push.sql:336`,
`110_anchor_push_waking_hours.sql:366`,
`097_question_box.sql:820`). It returns the number of rows it closed —
events plus attestations — so the cron log line is a count, not a bare
`select`.

**The events half is the wrapper's own UPDATE, not a call into
`auto_close_stale_events`.** §1.1 established why: that function is
per-room and member-gated, and the gate is `current_user_id()`, which reads
`request.jwt.claims` — a GUC a cron session does not have. Calling it from
cron raises `42501` before touching a row. So the wrapper loops
`select id, auto_close_hours from public.rooms where deleted_at is null`
and runs the *body* of `auto_close_stale_events` per room
(`115:819-825`), unchanged in substance:

```sql
update public.events e
   set settled_at = e.played_at + make_interval(hours => v_room.auto_close_hours)
  where e.room_id = v_room.id
    and e.settled_at is null
    and e.played_at < now() - make_interval(hours => v_room.auto_close_hours);
```

Two properties are carried over deliberately, because they are the reason
the client path produced the right *story*, not just the right row:

- **The stamp is `played_at + auto_close_hours`, not `now()`.** A night
  stranded for a week closes at the hour it actually went stale, so it
  reads `past` rather than a `recap` that looks like it settled a second
  ago (`115:813-818`; phase rule `public.night_phase`, `115:68`).
- **The window rides the room row**, so the host's Room Settings choice
  stays the single source of truth (`rooms.auto_close_hours`, `081:31`).

The `settled_at is null` and `played_at < now() - window` predicates make
it idempotent, exactly as the client path was.

**The attestation half is one call.**
`public.close_stale_attestations()` is global and guard-free (§1.2), so the
wrapper calls it **once** — not once per room — and adds its count to the
return value. It stamps `closed_at = now()` on attestations open more than
24 h, which is what `CasinoService.getMyOpenAttestations` triggered.

**Eligibility: live rooms only** (`rooms.deleted_at is null`). A
soft-deleted room is out of `get_my_rooms`, so the client path never
reached it either; the sweep covers the same rows the replacement covers.
Same filter `question_box_cron_tick` uses (`097:833`).

### 2.2 The grants

```sql
revoke all on function public.cron_close_stale() from public, anon, authenticated;
```

The repo rule is that every SECURITY DEFINER function ends with that
revoke, and this one is stricter than most: it is revoked from
`public, anon` **and** `authenticated`, so no app role can drive the
janitor at all. `service_role` is deliberately not granted either — the
only caller is the pg_cron scheduler, which runs as `postgres` and needs
no grant (the function is owned by the migration's role). This mirrors the
`question_box_cron_tick` precedent (`097:843`) and the `104_lockdown`
posture.

Note this is a **new** function, so `104_lockdown_internal_functions.sql`
(which lists the internal functions by name) does not cover it and does not
need to change.

### 2.3 The schedule

```sql
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'gr-stale-close';
    perform cron.schedule('gr-stale-close', '17 * * * *', 'select public.cron_close_stale();');
  else
    raise notice '120: pg_cron not installed; gr-stale-close not scheduled. ...';
  end if;
end $$;
```

The guard is the house idiom (`097:846-850`, `109:413-417`, `110:421-425`,
`040:101-108`): pg_cron is not installed on every database, and a
migration that calls `cron.schedule` unconditionally fails the whole apply
where the extension is absent. With the guard, the migration applies
cleanly anywhere and the function still exists for manual invocation. The
unschedule-by-job-name first makes a re-apply replace the job rather than
queue a second one.

The job name `gr-stale-close` is new — the four names already in the chain
are `briefing-push-tick`, `question-box-tick`, `anchor-push-tick` and
`close_unscanned_attestations_15min` (§1.4).

### 2.4 What it deliberately does NOT do

- **No Swift edit.** The client still fires both lazy calls; this lane only
  adds the server-side safety net. §4 lists what a later slice removes.
- **No live apply.** The migration carries its own apply command in the
  header and is applied by hand/TARS under Nathan's approval.
- **No change to the two existing functions.** `auto_close_stale_events`
  and `close_stale_attestations` keep their current signatures, guards and
  grants; the client path still works. The wrapper is additive.
- **No settlement side effects.** `settled_at` is the only column written.
  `events` has one trigger — `trg_check_one_upcoming_event` (`115:896`) —
  and it only fires `when (new.played_at > now() and new.settled_at is
  null)`, so a row being settled cannot trip it. `auto_return_on_settle`
  (`085:599`) is a trigger on `transactions`, not on `events`, and is not
  reached by this write.

## 3. Why hourly at minute 17

**Hourly.** The two things being finalized are not urgent and not
interactive:

- A stranded night's window is measured in hours (`auto_close_hours`,
  1–72, default 8 — `081:31-42`). The oldest meaningful lag between "the
  night went stale" and "the app shows it closed" is therefore already
  measured in hours, and `night_phase` (`115:68-88`) buckets anything
  more than 24 h old as `past` regardless. Hourly adds at most one hour
  to a delay that is already measured in hours.
- An attestation is closed only after it has been open **more than 24
  hours** (`061:456`). Running that check hourly instead of every 60
  seconds changes nothing a member can perceive — the row they would see
  is the same row either way; only the moment it flips from "open" to
  "closed" moves, and it moves by less than an hour on a 24-hour clock.

Meanwhile the *old* cadence was not hourly at all: the client fired these
writes at most once per 60 s per room (`RoomService.swift:488-495`) and at
most once per 60 s app-wide (`CasinoService.swift:382-395`) — but only
when somebody happened to open a screen. The server job is not a faster
version of that; it is the same work on a clock instead of on a screen
open. Once it exists, the client throttle is redundant (§4), so there is
no reason to run the server side faster than hourly.

**Minute 17.** Every hour at `:17`, not `:00`:

- The other jobs in this chain are bunched on the quarter hour or the
  hour (`*/15 * * * *` for `briefing-push-tick` and `anchor-push-tick`,
  `* * * * *` for `question-box-tick`). Landing on `:00` would put this
  job in the same instant as the busiest of them.
- `:17` is deliberately off every quarter boundary — `:15` is the
  busiest minute in the chain (`*/15`), `:00` is the next.
- Nothing in the product is time-critical at that granularity. A stale
  night that closes at `:17` instead of `:00` is still closed, and still
  closed with the *correct* `settled_at` (`played_at + window`), so the
  minute the job fires does not leak into what the user sees. That is the
  whole point of stamping with the room's window rather than `now()`.

The one-minute granularity of the cron spec is more than the job needs;
the point is to be *predictable and off-peak*, not to be precise.

## 4. Client removal plan (later slice)

*(written in B4 — no Swift file is touched by this lane)*

## 5. Open items for the conductor

- **Migration number — RENUMBERED 118 → 120.** `118` is occupied
  (`Supabase/migrations/118_question_box_depth.sql`), and `119` follows it
  (`119_glad_you_came.sql`). Per `Supabase/migrations/README.md` rule 3
  ("take the highest existing number and increment") the next free number
  is **120**, so this lane writes
  **`Supabase/migrations/120_stale_close_cron.sql`**, not the brief's
  `118_stale_close_cron.sql`. The brief's STOP-AND-REPORT item fired and
  was reported in B1; no conductor ruling arrived before B2, so the
  README rule decided it and the deviation is recorded here. The migration
  file's own header carries the same note.
- **Probes path — also renumbered.** The brief names
  `supabase/probes/118-stale-close-probes.sql`. This repo has no
  `supabase/probes/` directory: the probe convention is
  `Supabase/tests/<NNN>_probes.sql`, one file per migration
  (`Supabase/tests/115_probes.sql`, `Supabase/tests/119_probes.sql` —
  `118_probes.sql` also existed on the question-box branch). B3 therefore
  writes **`Supabase/tests/120_probes.sql`**, matching the established
  convention rather than creating a new directory. (The brief's lowercase
  `supabase/` also differs from the repo's capitalised `Supabase/`; the
  filesystem is case-insensitive here, but git tracks the capitalised
  form, so the capitalised paths are used throughout.)
- **Live apply is not done.** This lane writes SQL and probes only. The
  migration is applied by hand/TARS under Nathan's approval, using the
  command in the migration header.
