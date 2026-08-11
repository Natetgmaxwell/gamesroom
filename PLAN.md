# Games Room — Implementation Plan (VISION.md → first release)

> **Goal:** Close every gap between `VISION.md` and the tree at `main`
> (`a9c8e63`), then ship the first TestFlight build.
>
> **Current state (verified live 2026-08-11, integration t_a4d83930):**
> W-04..W-06 + W-07/W-08 all landed on `main`. 75/75 Foundation tests,
> 36/36 parse-checks, pbxproj validator green. No Xcode.app on this
> host — the app has never had a real build. No git remote — CI has
> never run.
>
> **How to read this plan:** §2 maps every vision requirement to a status
> and a verification. §3 is the work — three priorities, each item
> executable start-to-finish. §6 shows the order. Run §7's gate commands
> after every item.

---

## 1. What exists (audited, do not rebuild)

Stack: Swift 6 / SwiftUI, iOS 26+, Supabase (49 migrations, ~25 RPCs),
Core ML on-device vision, WidgetKit + Live Activity + Watch, EventKit,
z.ai mascot LLM. Services are `@MainActor`; views → services → `RoomStore`
protocol (live + in-memory impls). Tests are Foundation-only via
`main.swift` (no Xcode needed).

Shipped and green: rooms/join codes, seasons + close, seat deposits,
host-only scoring + team mode, 4 packs + store shell, casino withdraw →
per-member scan → settle (vision locked F-CAS-02: recall 0.975,
precision 1.000), score-correction indicator, leaderboard + round
breakdown, multi-room switcher with LIVE badge, notifications 3×3,
mascot 25-voice + LLM broadcast/recap, calendar auto-add (T1.1),
photo discard-by-default + opt-in keep (T1.2), app icon v3 (T1.3),
ui-polish pass (T1.4), CI workflow file (T0.3).

## 2. Requirement coverage map

Status tags: **DONE** (code + gate green), **DEVICE** (code-complete,
needs Xcode-host pass), **GAP** (vision requires it, tree lacks it),
**GATED** (blocked on a named decision).

| Req | Requirement | Status | Work item | Verify by |
|---|---|---|---|---|
| US-01 | 6-char single-use join code | DONE | — | Foundation tests (`main.swift` join-code cases) |
| US-02 | One-time redeem, "code already used" | DONE | — | Foundation tests (optimistic lock cases) |
| US-03 | Unlimited host codes | DONE | — | Foundation tests |
| US-04 | Deleting room expires all codes | **DONE** (W-04) | Foundation tests (deleteRoom expiry) + device D-13 |
| US-05 | Multi-room switch, last-opened default | DONE | — | Device pass D-1 |
| US-06 | LIVE badge on active room | DONE | — | Device pass D-1 |
| US-07 | Host/member only, no tiers | DONE | — | Code review (roles enum) |
| US-08 | Season name/length, carry + reset | DONE | — | Foundation tests + device D-2 |
| US-09 | Host-triggered next season, no parallels | DONE | — | Device pass D-2 |
| US-10 | Running total + per-game breakdown + **previous-seasons comparison** | **DONE** (W-05) | Foundation tests + device D-3 |
| US-11 | Everyone's scores (spectator) | DONE | — | Device pass D-3 |
| US-12 | Host is only scorer, can play | DONE | — | Device pass D-4 |
| US-13 | "Host correcting" 30s indicator + dot | DONE | — | Foundation test (Theme 60s) + device D-4 |
| US-14 | Seat deposits required per event | DONE | — | Device pass D-5 |
| US-15 | Refund on attend, forfeit on no-show | DONE | — | Device pass D-5 |
| US-16 | invited → confirmed → attended/no_show | DONE | — | Foundation tests (state flow) |
| US-17 | Install packs per room from store | DONE | — | Device pass D-6 |
| US-18 | Pack = config (scoring_ui, score_compute) | DONE | — | Foundation tests (PackRegistry) |
| US-19 | Switch packs mid-session | DONE | — | Device pass D-6 |
| US-20 | Tap total → recent entries → edit/delete | DONE | — | Device pass D-4 |
| US-21 | Member withdraws N points at start | DONE | — | Device pass D-7 |
| US-22 | Scan own stack, "Looks right / Off by X", re-scan | DONE | — | Device pass D-7 (camera) |
| US-23 | Host sees per-member scans, resolves, Finalize | DONE | — | Device pass D-8 |
| US-24 | 24h no-scan → P&L 0 + flag | DONE | — | Foundation test (sweep) |
| US-25 | Photo discarded, hash + snapshot kept | DONE | — | Foundation test (PhotoHash) + device D-7 |
| US-26 | Host overrides per-room chip color map | **DONE** (W-06) | Foundation tests + device D-7 |
| US-27 | Mascot broadcast/briefing/recap/**season-end**, host override | **GATED** (season-end missing; Q-TONE) | W-09 | Gate: Q-TONE answered |
| US-28 | 48h pre-session briefing | DONE | — | Foundation tests (cadence) |
| US-29 | Host toggles (broadcast/briefing/calendar/prefs/narration) | DONE | — | Device pass D-9 |
| US-30 | Member social preferences, host-seen | DONE | — | Device pass D-9 |
| US-31 | System notifications, thread-id = room_id | DONE | — | Device pass D-10 |
| US-32 | Mute via iOS system settings only | DONE | — | Code review (one channel) |
| AC-01 | Host labour ≈ 3 taps | DEVICE | W-01 | Device pass D-11 (timed flow) |
| AC-02 | One CTA per state | DONE | — | T1.4 audit already passed; re-check W-04/W-05 |
| AC-03 | Placement rule (who/when/how-often) | DONE | — | T1.4 audit; re-check W-04/W-06 |
| AC-04 | Join-code contract | DONE | — | Foundation tests |
| AC-05 | No parallel seasons; end rolls deposits | DONE | — | Foundation tests + device D-2 |
| AC-06 | Deposit refund/forfeit, deflationary | DONE | — | Device pass D-5 |
| AC-07 | Live Activity/Watch refresh ≤ 1 min | DEVICE | W-01 | Device pass D-12 |
| AC-08 | Correction indicator, no edit history | DONE | — | Foundation test + device D-4 |
| AC-09 | RPC derives room_id from events.id | DONE | — | Code review (migration 025) |
| AC-10 | RPC failures: what/why/what-to-do, sheet stays | DONE | — | Foundation tests (error paths) + device D-8 |
| AC-11/12/13 | Vision confidence gates (0.85, 10/10 probe) | DONE | — | Probe report locked; carry MAE ~6 chips |
| AC-14 | On-device only, no photo persistence | DONE | — | Code review (no network in vision path) |
| AC-15 | Per-member settlement RPC contract | DONE | — | Device pass D-8 (idempotency, 24h, finalize) |
| AC-16/17 | Pack schema v1 | DONE | — | Foundation tests (PackScoringResolver) |
| AC-18 | Verification gates green | DONE | — | §7 commands (75/75 tests, 36/36 parse-checks, validator exit 0, re-verified 2026-08-11) |

Non-goals: no violations found in the tree. Guard: W-04 must not add
edit-history; W-06 must not add a "vision model settings panel" (non-goal
15) — color map only; nothing may add network vision calls.

## 3. Work items

### P0 — Ship gates (unblock everything)

#### W-01 — First Xcode build + device pass

**Objective:** prove the app builds and renders on a Mac with Xcode 27.

**Files:** none (verification; fixes land as findings with tests).

**Steps:**
1. `xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`.
2. Build for a physical device (camera + Live Activity need one).
3. Manual pass D-1…D-12 (checklist in §7).
4. Every defect found gets a fix commit + test where testable.

**Acceptance:** simulator + device builds succeed; all 12 device items pass;
gates §7 green after fixes.

**Depends:** nothing. **Blocks:** W-02.

#### W-02 — TestFlight upload

**Objective:** ship build 0.1.0 (1) to TestFlight.

**Steps:** archive + upload from Xcode Organizer; paste
`docs/testflight-release-notes.md` into "What to Test"; invite the
Q-HOST-FEEDBACK accounts.

**Acceptance:** build visible with notes; testers can install.

**Depends:** W-01, Q-HOST-FEEDBACK.

#### W-03 — Activate CI

**Objective:** the committed workflow (`.github/workflows/ci.yml`) runs on
every push.

**Steps:**
1. `git remote add origin <repo-url>`; `git push -u origin main`.
2. Confirm the Actions run goes green (3 gates: `build-and-run-tests.sh`,
   `verify-xcode-project.py`, `parse-check-swiftui.sh`).

**Acceptance:** CI green on first push after W-04..W-06 land.

**Depends:** nothing (parallel to W-01/W-02).

### P1 — Vision gaps (runnable on this host)

#### W-04 — Room deletion expires join codes (US-04) + calendar remove hook

**Objective:** host can delete a room; codes die; calendar rows die with
it (closes AUDIT finding 4: `CalendarService.removeEvent` has zero call
sites).

**Files:**
- Create: `Supabase/migrations/052_room_delete.sql`
- Modify: `GamesRoom/Services/RoomStore.swift` (protocol + live + in-memory)
- Modify: `GamesRoom/Services/RoomService.swift` (`deleteRoom(roomId:)`)
- Modify: `GamesRoom/Views/RoomSettingsSheet.swift` (host-only destructive
  button — confirm dialog, `chair.fill` semantics, placement per AC-03)
- Modify: `GamesRoom/Services/CalendarService.swift` (call `removeEvent`
  for the room's events before delete)
- Modify: `main.swift` (Foundation test on the in-memory impl)

**Step 1 — failing test:** in-memory `deleteRoom` expires open join codes
and removes the room from `getMyRooms`; `deleteRoom` on a non-host throws.

**Step 2 — run:** `./build-and-run-tests.sh` → new cases FAIL.

**Step 3 — implement:**
- Migration: `delete_room(p_room_id)` — security definer; verifies caller
  is host via `room_memberships`; sets `rooms.deleted_at = now()` (soft
  delete preserves the ledger for disputes — do NOT hard-delete the
  ledger); deletes remaining `join_codes`; RLS filters deleted rooms.
- Swift: `RoomService.deleteRoom` → RPC; host-only button in
  `RoomSettingsSheet`; call `removeEvent` per event before delete.

**Step 4 — run:** `./build-and-run-tests.sh` → 65 + new cases PASS;
`bash scripts/parse-check-swiftui.sh` → 34/34; `python3
scripts/verify-xcode-project.py` → exit 0.

**Step 5 — commit:** one commit, migration + code + test.

**Acceptance:** US-04 verified by test + device D-13 (delete room → code
rejected on redeem attempt; calendar row gone).

**Depends:** nothing. Note: shares `RoomSettingsSheet.swift` with W-06 —
land W-04 before W-06 or rebase carefully.

#### W-05 — Previous-seasons comparison (US-10)

**Objective:** the "improving over time" view — this season vs prior
seasons.

**Files:**
- Create: `Supabase/migrations/053_season_history.sql`
- Modify: `GamesRoom/Services/RoomStore.swift` (protocol + both impls)
- Modify: `GamesRoom/Services/RoomService.swift` (`seasonHistory(roomId:)`)
- Modify: `GamesRoom/Views/RoomDetailView.swift` (new section next to
  RoundBreakdownSection; shows prior seasons: name, dates, caller's total
  + rank, delta vs current season)
- Modify: `main.swift` (in-memory test: two seasons → history rows
  ordered, deltas correct)

**Step 1 — failing test:** in-memory `seasonHistory` returns prior seasons
with correct totals and delta vs active season.

**Step 2 — run:** tests → FAIL.

**Step 3 — implement:**
- Migration: `get_season_history(p_room_id)` — rows: `season_id`, `name`,
  `started_at`, `ended_at`, plus per-member totals for the caller's rank
  (reuse the leaderboard aggregation shape from migration 031).
- Swift: service + store methods; UI section renders only when ≥ 1 prior
  season exists.

**Step 4 — run:** gates → all green (65 + new).

**Step 5 — commit.**

**Acceptance:** US-10 fully verified by test + device D-3.

**Depends:** nothing.

#### W-06 — Host chip-color-map override UI (US-26)

**Objective:** surface the existing `upsert_casino_config` RPC
(migration 014) — data layer is done, zero UI exists.

**Files:**
- Modify: `GamesRoom/Services/RoomStore.swift` (protocol + live:
  `updateCasinoConfig` → `upsert_casino_config`; in-memory stub)
- Modify: `GamesRoom/Services/CasinoService.swift` (thin wrapper)
- Modify: `GamesRoom/Views/RoomSettingsSheet.swift` (Casino section:
  standard-presets toggle + per-color value editor for `ChipColor` cases)
- Modify: `main.swift` (pure test: `CasinoConfig.value(for:)` respects
  `standardPresets` vs `chipColorMap`)

**Step 1 — failing test:** config with `standardPresets == false` maps a
custom `chipColorMap` entry; `true` ignores the map.

**Step 2 — run:** tests → FAIL.

**Step 3 — implement:** config editor sheet; save via
`CasinoService.updateCasinoConfig`; load current config on open
(`get_casino_config`).

**Step 4 — run:** gates → all green.

**Step 5 — commit.**

**Acceptance:** US-26 verified by test + device D-7 (scan reflects the
custom map). Constraint: color map only — no model-settings panel
(non-goal 15).

**Depends:** nothing (see W-04 note on shared file).

#### W-07 — Doc drift + commit parent outputs

**Objective:** kill the stale-docs debt (AUDIT findings 6–9) and land the
uncommitted VISION.md/AUDIT.md.

**Files:**
- Delete: `docs/audit.md` (superseded by root `AUDIT.md`)
- Modify: `docs/v0.8-vision-checklist.md` (refresh W2.x statuses; test
  count 36 → 65)
- Modify: `tests/README.md` (33 → 65)
- Modify: `IMPLEMENTATION_PLAN.md` (status block: 65/65 + 34/34,
  T0.3/T0.4/T1.x DONE, remaining = T0.1/T0.2/Wave 2; point at this PLAN.md)
- Commit: `VISION.md` (rewritten by vision task) + `AUDIT.md` (new) +
  `PLAN.md` (this file)

**Steps:** edit → `git add` the touched docs + VISION.md + AUDIT.md +
PLAN.md → one commit `docs: refresh drift, land vision + audit + plan`.

**Acceptance:** tree clean; no doc references an outdated test count.

**Depends:** after W-04..W-06 so IMPLEMENTATION_PLAN.md's status block
stays accurate.

#### W-08 — Migration conventions note

**Objective:** document the numbering convention (AUDIT finding 5 — gaps
009/010/037/038, `011a`/`022_v0.12` suffixes).

**Files:** Create: `Supabase/migrations/README.md`.

**Steps:** one page: additive-only, no renumbering, gaps are historical,
suffix pattern for same-version fixes, every RPC names its migration in
the Swift docstring.

**Acceptance:** file committed; next migration author has the rule.

**Depends:** nothing.

### P2 — Gated (do NOT silently resolve)

#### W-09 — Mascot matrix Wave 5 (US-27 season-end voice)

**Objective:** when Q-TONE lands: settle Q-LLM-PROVIDER (Apple Foundation
Models per VISION §5.3 vs current z.ai), add season-end narration, finish
the 75-cell matrix. Voice stays the footer caption.

**Files:** `MascotEngine.swift`, `MascotPersonality.swift`,
`MascotPoliticalIdeology.swift`.

**Depends:** Q-TONE, Q-LLM-PROVIDER.

#### W-10 — Paid packs / StoreKit (feature 16)

**Objective:** when Q-PAID-PACKS lands: `StoreService` (Product/Transaction
purchase + restore); purchase gates pack install; free packs unchanged.

**Files:** create `StoreService.swift`; modify `PackStoreView.swift`.

**Depends:** Q-PAID-PACKS.

#### W-11 — Cloud-vision hybrid (feature 8, v2-only)

**Objective:** no code. Re-evaluate only if on-device confidence falls
short in beta (T2.3).

**Depends:** W-02 (needs beta feedback).

## 4. Backend/data changes

| Change | Where | Work item |
|---|---|---|
| `delete_room` RPC + deleted_at soft delete + code expiry | migration 052 | W-04 |
| `get_season_history` RPC | migration 053 | W-05 |
| `upsert_casino_config` / `get_casino_config` — exists, no change | migration 014 | W-06 (client only) |
| Migration conventions doc | `Supabase/migrations/README.md` | W-08 |

No schema change to existing tables in W-04/W-05 beyond additive columns
(`rooms.deleted_at`) — RLS filters deleted rooms.

## 5. Frontend/UI changes

| Change | Where | Work item |
|---|---|---|
| Host "Delete room" destructive button (confirm dialog) | `RoomSettingsSheet.swift` | W-04 |
| Previous-seasons section (total + rank + delta) | `RoomDetailView.swift` | W-05 |
| Casino config editor (presets toggle + per-color values) | `RoomSettingsSheet.swift` | W-06 |

Placement constraints: delete is host-only, lives in room settings (never
next to claim-seat); season history is a member-visible read surface;
config editor is host-only. One CTA per state (AC-02) — re-run the T1.4
audit lens after these land.

## 6. Dependencies & milestones

```
M1 "First real build"   W-01 → W-02   (needs Xcode 27 host)
M2 "Vision complete"    W-03 ∥ W-04 → W-05 ∥ W-06   (this host, now)
M3 "Housekeeping"       W-07 (after W-04..W-06), W-08 (any time)
M4 "Gated waves"        W-09 (Q-TONE+Q-LLM-PROVIDER), W-10 (Q-PAID-PACKS),
                        W-11 (after W-02)
```

Order on this host: W-04 → W-05 → W-06 → W-07 + W-08 (W-04 before W-06
because they share `RoomSettingsSheet.swift`). W-03 remote push after
W-04..W-06 land so CI's first run is the real gate.

## 7. Verification

**Gate commands (after every code item):**

```bash
./build-and-run-tests.sh             # 75 + new cases, 0 failed
bash scripts/parse-check-swiftui.sh  # 36/36 pass
python3 scripts/verify-xcode-project.py  # exit 0
plutil -lint <any touched plist>     # OK
```

**Device checklist (W-01, on an Xcode 27 host):**
- D-1 room switcher + LIVE badge; D-2 season close → next season;
- D-3 leaderboard + round breakdown + season history; D-4 host scoring +
  correction indicator; D-5 seat deposit refund/forfeit; D-6 pack store +
  mid-session pack switch; D-7 withdraw → scan → custom color map;
  D-8 host scan board → Finalize; D-9 host toggles + member prefs;
  D-10 notification grouping (thread-id); D-11 timed 3-tap host flow;
  D-12 Glance 1-min refresh + Live Activity suppressed during play;
  D-13 delete room → code rejected + calendar row removed.

**Per-requirement traceability:** every US/AC row in §2 names its
verification — Foundation test, gate command, code review, or device item.
Nothing ships without its row's check passing.

## 8. Open questions — do NOT resolve silently

| ID | Question | Default |
|---|---|---|
| Q-TONE | Brand voice (gates W-09) | Ship existing template voice |
| Q-LLM-PROVIDER | Apple Foundation Models vs z.ai (W-09) | Keep z.ai until Q-TONE lands |
| Q-PAID-PACKS | Per-pack ~$5 (gates W-10) | StoreKit shell stays inert |
| Q-HOST-FEEDBACK | Beta account count (gates W-02) | 2–3, recruited by Nathan |
| Q-V0.9-PUBLICITY | TestFlight changelog post? | Silent |

## 9. Verification baseline (re-run live 2026-08-11, integration t_a4d83930)

```
./build-and-run-tests.sh            → 75 passed, 0 failed
bash scripts/parse-check-swiftui.sh → 36/36 pass
python3 scripts/verify-xcode-project.py → exit 0
git status                          → clean after W-07 commit (VISION.md, AUDIT.md,
                                      PLAN.md landed)
```

Carried risks (do not re-litigate): vision count MAE ~6 chips,
low-contrast stacks on dark felt (F-CAS-02 locked); real-photo probe
waived — device pass D-7 is the first real-camera signal.
