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

*(written in B2)*

## 3. Why hourly at minute 17

*(written in B2)*

## 4. Client removal plan (later slice)

*(written in B4 — no Swift file is touched by this lane)*

## 5. Open items for the conductor

- **Migration number.** `118` is occupied (`118_question_box_depth.sql`); the
  next free number per `Supabase/migrations/README.md` is `120`. The brief's
  file name `supabase/migrations/118_stale_close_cron.sql` cannot be used
  without a duplicate number. This lane does not renumber on its own.
