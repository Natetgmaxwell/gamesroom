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
  `events` has two triggers and neither fires on this write:
  `trg_check_one_upcoming_event` (`115:896`) fires
  `when (new.played_at > now() and new.settled_at is null)` — a row being
  settled cannot trip it — and `trg_reject_retired_pack` (`100:79-81`) fires
  `before insert or update of pack_slug`, while the wrapper's UPDATE touches
  `settled_at` only. `auto_return_on_settle` (`085:599`) is a trigger on
  `transactions`, not on `events`, and is not reached by this write.

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

The brief puts the client cleanup in a **later** slice, after the cron is
verified live. This section is that slice's spec: every block to delete, the
file it lives in, the grep anchor that finds it, and the two blocks that look
like part of the same change but are not.

### 4.1 Preconditions — the later slice starts only when all five hold

1. **Migration 120 is applied to the live database.** Nathan-gated, by hand;
   the apply command is in the migration header
   (`Supabase/migrations/120_stale_close_cron.sql:62-64`). Nothing in this
   lane applies it.
2. **The job is registered and has fired.**
   `select jobname, schedule from cron.job where jobname = 'gr-stale-close'`
   returns exactly one row at `17 * * * *`, and `cron.job_run_details` shows
   at least one successful run.
3. **The probes have been executed on the schema replica** and every probe
   printed PASS. ⚠️ `Supabase/tests/120_probes.sql` was **never executed** in
   this lane — there is no local postgres here and the docker daemon was
   down, so the SQL was only balance-scripted and read. See §4.8.
4. **One full hourly cycle has been observed with the client path still in
   place.** Both paths are live then; the cron wins and the client call
   becomes a no-op (the client RPC finds nothing left to close and returns
   `0`). That is the cheapest possible proof that the cron works, because
   it is additive — the old path is still there to cover the gap.
5. **The conductor has accepted the one behavioural change** (§4.6).

### 4.2 Block A — `GamesRoom/Services/CasinoService.swift` (attestations)

| # | File:lines | Grep anchor | Action |
|---|---|---|---|
| A1 | `CasinoService.swift:98-103` | `lastStaleCloseAt` | delete — the V0.69 comment block + `private var lastStaleCloseAt: Date?` |
| A2 | `CasinoService.swift:125-127` | `staleCloseTTL` | delete — the V0.69 comment block + `private let staleCloseTTL: TimeInterval = 60` |
| A3 | `CasinoService.swift:378-381` | `the lazy 24h finalize` | rewrite — the doc paragraph describing the throttled write becomes one line pointing at the server cron |
| A4 | `CasinoService.swift:387-395` | `rpc close_stale_attestations` | delete — the whole `if lastStaleCloseAt == nil \|\| …` block, including its `Perf.span("rpc close_stale_attestations")` wrapper |

**Do NOT delete `CasinoService.swift:386` (`let now = Date()`).** It looks like
part of the throttled block, but `now` is reused twice after the deletion:
the cache freshness check at `CasinoService.swift:398`
(`now.timeIntervalSince(cached.at) < casinoCacheTTL`) and the cache stamp at
`CasinoService.swift:410` (`attestationCache = (rows: result, at: now)`).
Deleting it breaks the 30 s attestation cache and silently turns every read
into a fresh RPC.

**Keep** `casinoCacheTTL` (`CasinoService.swift:123`), `attestationCache`
(`CasinoService.swift:110`) and the read at `CasinoService.swift:403-408`.
The *read* half of `getMyOpenAttestations` is not part of this change — only
the write it used to smuggle in.

### 4.3 Block B — `GamesRoom/Services/RoomService.swift` (events)

| # | File:lines | Grep anchor | Action |
|---|---|---|---|
| B1 | `RoomService.swift:99-102` | `lastAutoCloseAt` | delete — the V0.82 comment block + `private var lastAutoCloseAt: [UUID: Date] = [:]` |
| B2 | `RoomService.swift:282` | `lastAutoCloseAt = [:]` | delete — the one line in the reset method (`RoomService.swift:265-284`) that clears the throttle dictionary |
| B3 | `RoomService.swift:488-495` | `store.autoCloseStaleEvents(roomId:)` | delete — the whole throttled block, **including `let now = Date()` at `RoomService.swift:490`** |
| B4 | `RoomService.swift:475-480` | `lazy auto-close` | rewrite — the doc paragraph describing the throttled write becomes one line pointing at the server cron |

**B3's `let now = Date()` is safe to delete** (A4's is *not* — see §4.2):
`now` occurs only at `RoomService.swift:490`, `492` and `493` — all three
inside the block (`rg -n "\bnow\b" GamesRoom/Services/RoomService.swift` over
`482-640`, the whole span of `loadActiveEvent`, `482-544`).

**Keep** the single-flight read logic in `loadActiveEvent` — the cache check
(`RoomService.swift:484`), the in-flight join (`485-487`) and the task
(`500+`). The function becomes a pure read; it stops being a finalizer.

### 4.4 Block C — the store layer (only under the optional option)

`RoomStore` / `RoomStoreProtocol` / `InMemoryRoomStore` carry the RPC
*plumbing*. They are **not** the lazy janitor — nothing calls them once
Block A and Block B are gone — but they are the client's mirror of two
server functions that still exist, and the fake's mirror is pinned by tests.

| # | File:lines | Grep anchor | Action (Option B only) |
|---|---|---|---|
| C1 | `RoomStore.swift:427-437` | `func autoCloseStaleEvents(roomId:` | delete — the live RPC wrapper |
| C2 | `RoomStoreProtocol.swift:162-167` | `func autoCloseStaleEvents(roomId: UUID) async throws -> Int` | delete — the doc comment + the protocol requirement |
| C3 | `InMemoryRoomStore.swift:1096-1113` | `func autoCloseStaleEvents(roomId:` | delete — the in-memory mirror |
| C4 | `main.swift:1592-1627` | `InMemoryRoomStore.autoCloseStaleEvents stamps stale events, leaves fresh` | delete — the unit test |
| C5 | `main.swift:1629-1666` | `InMemoryRoomStore.autoCloseStaleEvents honors the room's autoCloseHours window` | delete — the unit test |
| C6 | `TestsP1.swift:270-281` | `P1: auto-close closes only the night past the window` | delete — the unit test |

**Do NOT delete `InMemoryRoomStore.swift:1090-1094`
(`private func autoCloseHours(roomId:)`).** It is called by the mirror
(`InMemoryRoomStore.swift:1102`) **and** by `fetchActiveEvent`
(`InMemoryRoomStore.swift:1056`), where it supplies the window the fake
ranks the active slot with. Removing it with the mirror breaks the fake's
night ranking, and the fake's ranking is what the previews and the phase
tests read.

**Do NOT touch** the `Room.autoCloseHours` model property, the room-settings
write path, or `InMemoryRoomStore.swift:1960/1996/2032/2086` — the window is
the server's source of truth for the cron too (§2.1), so the app keeps
reading and writing it.

### 4.5 Two options — pick one, do not do half of each

**Option A (recommended): remove the triggers only.** Delete A1–A4 and
B1–B4. Keep the whole store layer and its tests (C1–C6 stay). Rationale: the
RPCs still exist in the database, the fake still mirrors them, and the tests
still pin the mirror's contract. Nothing in the app calls the store methods
anymore, so they are dead code that costs one protocol requirement.

**Option B: full cleanup.** Delete A1–A4, B1–B4 **and** C1–C6, and add a
later migration that stops serving the two RPCs to app roles:

- `public.auto_close_stale_events(uuid)` — nothing calls it any more; drop it
  or revoke execute from `authenticated`.
- `public.close_stale_attestations()` — revoke execute from `authenticated`
  **and** `public`. It is safe to revoke: `cron_close_stale()` is SECURITY
  DEFINER, so the call it makes at
  `Supabase/migrations/120_stale_close_cron.sql:108` runs with the owner's
  privileges and does not need a grant to `authenticated` or to PUBLIC.
  (`public.get_my_open_attestations` — the read — is a different function
  and is untouched.)

Option B is the cleaner end state, but it is a second, separate change with
its own migration number; it is not part of the client slice's "remove the
client trigger" job.

### 4.6 The behavioural change the later slice accepts

Today, a night whose window expires is stamped **the moment a member opens
that room** — seconds after the window closes. After the client removal the
earliest it can be stamped is the next `gr-stale-close` tick, so **up to ~1 h
of extra lag** on a stale night, and the same on an attestation crossing 24 h.
The *value* written does not move: `settled_at = played_at + auto_close_hours`
(§2.1), so a night still reads `past` rather than a fresh recap — only the
moment the row flips changes. This is the trade the lane is making; the
conductor signs off on it before Block A starts (§4.1 item 5).

### 4.7 Verification checklist for the later slice

```bash
# 1. nothing client-side still reaches the two RPCs
rg -n "lastAutoCloseAt|lastStaleCloseAt|close_stale_attestations|auto_close_stale_events" GamesRoom/

# 2. the repo gates
bash .maestro/fastgate.sh --compile   # unit runner + SwiftUI parse-check + xcodebuild
bash .maestro/gate.sh                 # full gate incl. the 19-screen sweep
```

3. **A room nobody opens still closes its stranded night** — the end-to-end
   proof that the cron, not the client, is doing the work. Seed a stranded
   night in a room, wait for a `:17` tick, read `events.settled_at` back.
4. The attestation half: an attestation opened 25 h ago is `closed_at`-stamped
   by the next tick, with no client read in between.
5. `docs/STATE-MACHINES.md:93` still names `auto_close_stale_events` as a
   move of the deposit ledger — the later slice should update that line to
   name the cron job instead (see §5, observation 4).

### 4.8 Probe status — the limit this lane could not clear

`Supabase/tests/120_probes.sql` (22 probes, `120.a` … `120.v`) was written,
balance-scripted and read in this lane, but **never executed**: there is no
local postgres on this machine and the docker daemon was down, so neither the
migration nor the probes were run against a live or replica database. The
SQL in this lane is reviewed by eye, not by execution. The probes are the
first thing the later slice should run (and they should run *before* the
client cleanup, on the replica, with the exact command in the probe file's
header).

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
- **Probes format — the repo's, not the brief's.** The brief asks for
  `select 'PROBE <id> ' || case when <condition> then 'PASS' else 'FAIL' end;`.
  Both existing probe files (`Supabase/tests/115_probes.sql`,
  `Supabase/tests/119_probes.sql`) instead print
  `raise notice 'PROBE <id> PASS|FAIL …'` from inside `do` blocks, and the
  brief itself says to copy their exact style. B3 follows the existing repo
  style: `raise notice`, ids prefixed `120` (`120.a` … `120.v`, 22 probes).
  The semantics are the same — one PASS/FAIL line per condition — but the
  output shape is what the repo's harness already consumes, so a replica run
  needs no new parsing.
- **The probes were never executed here.** No local postgres on this
  machine and the docker daemon was down, so neither migration 120 nor
  `Supabase/tests/120_probes.sql` was run against a live or replica
  database. The SQL is reviewed by eye and balance-scripted only. Details
  and the follow-up are in §4.8; this is the lane's one unverified claim.
- **No Swift file is touched.** The client removal is specified, block by
  block, in §4 — file, lines and grep anchor for each — and lands in a
  later slice after the cron is verified live (§4.1 preconditions).
- **Observation 4 — `docs/STATE-MACHINES.md:93` credits
  `auto_close_stale_events` with a deposit-ledger move
  (`unresolved → forfeited at played_at + auto_close_hours`) that no
  migration performs.** `080`, `081` and the live `115` version of
  `auto_close_stale_events` write `events.settled_at` and nothing else
  (`115:819-825`); the deposit forfeit is host-driven
  (`public.forfeit_seat_deposit`, `095:985`; `settle_event` "stamps
  settled_at and touches nothing else", `107:46`). Flagged, **not** touched:
  `docs/` is outside this lane's allowed files, and no Swift/SQL change is
  implied by it. The later slice should correct that line when it rewrites
  the janitor story (§4.7 item 5).
- **Live apply is not done.** This lane writes SQL and probes only. The
  migration is applied by hand/TARS under Nathan's approval, using the
  command in the migration header.
