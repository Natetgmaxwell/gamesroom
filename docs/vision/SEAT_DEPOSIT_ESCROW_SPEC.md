# Games Room — V0.85 Seat Deposit as Real Escrow (SPEC)

> Status: **locked** (2026-08-19). Replaces the V0.84 C3 no-show tax with
> the seat deposit: a real escrow charged at claim, returned on arrival,
> forfeited only on host-confirmed no-show. Option A (real escrow) chosen
> by user directive over Option B (virtual hold).
>
> Repo home: `docs/vision/SEAT_DEPOSIT_ESCROW_SPEC.md`.
>
> Feeds: [[originals/2026-08-13-games-room-friendship-substrate-spec]]
> (1.4: "deposit-forfeit is the commitment device"),
> [[originals/2026-08-13-games-room-v053-vision-memo]],
> [[concepts/games-room-carnegie-applied-playbook]] (C3: host decides,
> system never decides alone).

---

## The reframe

The V0.84 C3 no-show tax was the punishment half of the substrate's
commitment device. The seat deposit is the promise half. Same chips,
different psychology:

- **Tax** — needs enforcement. The system punishes absence.
- **Deposit** — needs only a reclaim. The member gets their chips back
  by showing up. Self-motivating, no nagging, no chase.

The reclaim tap IS the attendance check-in. The member wants to tap
(their chips return), so attendance records itself without the host
marking anyone.

## The workflow

1. **Claim** — member claims a seat → deposit (default 200 CC) leaves
   their balance into escrow. The seat is theirs because they put chips
   on it.
2. **Arrive** — member walks in, finds the chair card, taps **"I'm
   here"** → deposit returns instantly. That's the reclaim and the
   check-in.
3. **No-show** — at session start, the host sees the arrival card:
   *"3 of 5 arrived. Sam hasn't checked in — forfeit Sam's deposit?"*
   → **Forfeit** / **Skip (Sam texted)** / **Skip (Sam's away)**.
   Host decides. System never decides alone (locked C3 rule).
4. **Proof-fallback** — if a member never tapped check-in but has a
   settle transaction (they played), the deposit returns automatically
   at settle. Played = present, no forfeit.

## Attendance automation (the honest split)

| Layer | Automation | Why |
|---|---|---|
| The reclaim | One tap on the chair card | Self-motivating — member wants their chips back. No nagging. |
| Host's view | Automated — realtime arrival dashboard (migration 077 infra) | Host sees who's in without asking. |
| No-show detection | Automated — claimed + no check-in at session start = candidate list | Reuses `list_no_show_candidates` shape. |
| The forfeit decision | **Not automated — host taps** | Locked: the host always decides. Carnegie 4.5. |
| Full presence detection (BLE/geofence) | **Deliberately not built** | Geofence is creepy, BLE is flaky, both add complexity the substrate avoids. |

## Migration 085 — `seat_deposit_escrow.sql`

Reframes 082 (which stays as history). Live changes:

1. **Rename** `rooms.no_show_tax_*` → `rooms.seat_deposit_*`:
   - `seat_deposit_amount` (default 200)
   - `seat_deposit_trigger` — `escrow` / `off` (default `escrow`; the
     old `auto`/`prompt`/`manual` collapse into `escrow` + host
     forfeit-confirm)
   - `seat_deposit_grace_minutes` (default 10)
   - `seat_deposit_destination` — `next_pot` / `host_charity` / `split`
     (default `next_pot`)
2. **New table** `seat_deposits`:
   - `id uuid pk`
   - `event_id uuid` (FK events)
   - `member_id uuid` (FK room_memberships)
   - `amount int`
   - `status` — `held` / `returned` / `forfeited` / `waived`
   - `returned_at timestamptz null`
   - `forfeited_at timestamptz null`
   - `forfeited_by uuid null` (host user id)
   - `created_at timestamptz default now()`
   - unique `(event_id, member_id)`
3. **RPCs** (all host/member-guarded, idempotent):
   - `claim_seat_with_deposit(p_event_id)` — member; charges deposit
     into escrow, creates `seat_deposits` row `held`. Fails 42501 if
     balance < amount (host-waiver path: `claim_seat_waived`).
   - `check_in_seat(p_event_id)` — member; returns deposit, status
     `returned`. Idempotent (already returned = no-op).
   - `list_arrival_candidates(p_event_id)` — host; claimed + no
     check-in + no settle transaction at session start.
   - `forfeit_seat_deposit(p_event_id, p_member_id)` — host-only;
     status `forfeited`, chips into destination.
   - `waive_seat_deposit(p_event_id, p_member_id)` — host-only; status
     `waived`, deposit returns (broke-member path).
   - `auto_return_on_settle()` — trigger on settle transaction: any
     `held` deposit for that member+event returns automatically.
4. **Ledger rows** — `seat_deposit` / `seat_deposit_return` /
   `seat_deposit_forfeit` / `seat_deposit_waive` (replaces
   `no_show_tax` / `no_show_tax_waiver` kinds).

## iOS changes

- **`SeatDeposit.swift`** — reframe: `SeatDepositStatus` enum
  (held/returned/forfeited/waived), `SeatDepositCandidate`,
  `ArrivalPromptVoice` (mascot-voiced arrival card copy).
- **`Room.swift`** — four `seat_deposit_*` fields replace
  `no_show_tax_*` (decode fallbacks to defaults).
- **`RoomStore.swift` / `RoomService.swift` / `InMemoryRoomStore.swift` /
  `RoomStoreProtocol.swift`** — RPC wrappers for the six new RPCs;
  `updateRoom` carries the four renamed settings.
- **`RoomSettingsSheet.swift`** — "Seat deposit" section (amount,
  trigger, grace, destination).
- **`NoShowTaxPromptCard.swift`** → **`ArrivalCard.swift`** — host-only,
  session-start, per-candidate Forfeit / Skip (texted) / Skip (away).
- **Chair card** — gains the **"I'm here"** button (the reclaim).
- **Claim flow** — `claim_seat_with_deposit` replaces the plain RSVP
  upsert when `seat_deposit_trigger == escrow`.

## What NOT to build

- No BLE/geofence presence detection.
- No auto-forfeit — the host always confirms.
- No streak/shame mechanics — a forfeit is about the next pot, not a
  score against the member (substrate 1.3 line).
- No "you haven't checked in" nagging — the reclaim is self-motivating.

## Verification

1. `./build-and-run-tests.sh` + parse-check after every task.
2. `python3 scripts/verify-xcode-project.py` after pbxproj change.
3. Migration 085 applied live by the orchestrator (not the worker).
4. Live probe: claim → check-in → return; claim → no-show → host
   forfeit; claim → no-show → settle → auto-return.
5. FF-merge each task branch to main; push after the batch.
6. Definitive gate: `xcodebuild` on the Mac Studio (no Xcode on this
   host — document what was NOT verified).

## Sources

- Substrate 1.4: "deposit-forfeit is the commitment device" (locked).
- Carnegie playbook C3: host decides, system never decides alone.
- V0.53: the app stays below the table.
