# Games Room — Codebase Audit

> **Snapshot note (2026-08-11, integration t_a4d83930):** this audit
> captured the tree at `a9c8e63` (pre W-04..W-06). Findings 4–9 are
> since closed: CalendarService.removeEvent has call sites (W-04),
> migration conventions documented (W-08), and the stale docs
> (`docs/audit.md` retired, `docs/v0.8-vision-checklist.md`,
> `tests/README.md`, `IMPLEMENTATION_PLAN.md` refreshed). Live counts
> are now 75/75 Foundation tests, 36/36 parse-checks, validator green;
> the requirement-coverage map is `PLAN.md` §2.

2026-08-11 · task t_08c978bb · audited at `main` HEAD `a9c8e63`, working tree clean.
Read-only audit — no code was modified. All verification gates were run live during this audit.

> **Supersedes** `docs/audit.md`, which captured the pre-V0.8 tree at `2cba2fb`
> and is explicitly marked SUPERSEDED inside itself. This report reflects the
> current tree: V0.8 + all V0.9 roadmap slices (W1.1–W1.6, W2.1–W2.8, W3.2, W3.3)
> + T0.3/T0.4/T1.1–T1.4 from the implementation plan.

**Audience.** A fresh engineer who has never seen this repo. Goal: understand
the stack, the layout, what is built, what is broken or gated, and where to
make changes next.

---

## 1. TL;DR

- **Product.** Invite-only iOS app for in-person games nights. One host per
  room, 8–12 members, physical presence. Plans the night, runs a credit
  ledger, stays quiet during play. Commercialised fork of the private Felt
  Faction program (Nathan + Connor).
- **Stack.** Native iOS/iPadOS 26+ app: Swift 6, SwiftUI throughout, no
  third-party UI deps. Backend is Supabase (Postgres + GoTrue auth + PostgREST
  RPCs, `supabase-swift` 2.54.1 SPM). Apple Sign-In only. WidgetKit +
  ActivityKit (Glance / Live Activity / Watch), Core ML on-device vision,
  EventKit calendar auto-add. No web layer, no Cloudflare, no React Native.
- **State.** V0.8 feature-complete + all V0.9 slices code-complete. 65/65
  Foundation tests, 34/34 parse-checks, pbxproj validator green (all re-verified
  live 2026-08-11). The remaining work is Xcode-host gated (first real build,
  TestFlight), plus four gated decisions.
- **The one big gap.** No Xcode.app on the build host. The app has never had a
  real `xcodebuild` build or device pass. Everything is verified by a
  Foundation-only test binary + syntax parse-checks + a pbxproj structural
  validator. The CI lane (`.github/workflows/ci.yml`) exists but has never run
  (no remote configured).
- **Repo has no git remote.** `git remote -v` is empty. CI is dead until a
  remote is added.

---

## 2. Stack summary

| Layer            | Choice                                                                 |
|------------------|------------------------------------------------------------------------|
| Language         | Swift 6, strict concurrency (`@MainActor` services)                    |
| UI               | SwiftUI, no UIKit, no third-party UI deps                              |
| Minimum OS       | iOS/iPadOS 26.0 (`MinimumOSVersion` in `Info.plist`)                   |
| Build            | Xcode 27 project (`GamesRoom.xcodeproj`), 3 targets (app, widgets, watch) |
| Auth             | Apple Sign-In → GoTrue `signInWithIdToken`                             |
| Backend          | Supabase Postgres + PostgREST RPCs (49 migrations, 001–051)            |
| SDK              | `supabase-swift` 2.54.1 (SPM)                                          |
| Local state      | `@AppStorage` / `UserDefaults` only. No Core Data, no SQLite           |
| Notifications    | `UserNotifications` via `NotificationDispatcher`                        |
| Calendar         | EventKit (`CalendarService`, host toggle, default off)                 |
| Vision           | On-device Core ML segmentation (locked F-CAS-02: recall 0.975, precision 1.000) |
| Widgets          | WidgetKit Glance (1-min refresh) + ActivityKit Live Activity + Watch app |
| Mascot LLM       | z.ai glm-4.6 over URLSession (VISION.md says Apple Foundation Models — gated) |
| CI               | `.github/workflows/ci.yml` (macos-latest, 3 gates) — never executed    |

**Project idiom — `ponytail:` comments.** The codebase flags deliberate
workarounds / sharp edges with `ponytail:` comment markers instead of
TODO/FIXME (there are zero TODO/FIXME/HACK/XXX markers in `GamesRoom/`).
Grep `ponytail` to see the debt list.

---

## 3. Directory map

```
games-room/                                  # repo root (no git remote)
├── .archive/2026-07-31-pre-v0.8/            # frozen V0.7.1 reference (gitignored)
├── .designs/                                # 117 icon/room-page design assets (tracked)
│   ├── app-icons/ app-icons-v2/ app-icons-v3/ room-page/
├── .github/workflows/ci.yml                 # CI lane (T0.3) — never run
├── .hermes/plans/                           # V0.8 redesign brief
├── GamesRoom.xcodeproj/                     # Xcode project (3 targets)
├── GamesRoom/                               # ← app source (83 .swift files)
│   ├── Auth/                                #   SignInView
│   ├── Models/                              #   40+ pure Codable value types
│   ├── Packs/                               #   pack contract + 4 packs + scoring
│   ├── Services/                            #   12 service classes (see §5)
│   ├── Views/                               #   17 views + Components/ (6)
│   ├── GamesRoomApp.swift                   #   @main entry point
│   ├── Theme.swift                          #   design tokens (80/20/10)
│   ├── Info.plist / Config.xcconfig / entitlements / Assets.xcassets
├── GamesRoomWatch/                          # Watch app target (2 files)
├── GamesRoomWidgets/                        # Widget + Live Activity target (1 file)
├── Supabase/migrations/                     # 49 SQL migrations, 001–051
├── Tools/CasinoVisionProbe/                 # SPM package: vision probe (done, locked)
├── docs/                                    # 16 markdown docs (see §8)
├── scripts/
│   ├── verify-xcode-project.py              # pbxproj structural validator
│   └── parse-check-swiftui.sh               # syntax-only SwiftUI parse gate
├── tests/README.md                          # test-runner doc (doc-only dir)
├── build-and-run-tests.sh                   # Foundation test runner
├── main.swift                               # ← Foundation test cases (65)
├── games-room-tests                         # compiled test binary (gitignored)
├── VISION.md                                # consolidated product vision (tracked)
└── IMPLEMENTATION_PLAN.md                   # V0.9 → first-release plan
```

**Surprise worth knowing:** `main.swift` at repo root is the *Foundation test
entry point*, not an iOS binary's `main`. The real app entry is
`GamesRoom/GamesRoomApp.swift`. The test runner compiles Models + Packs +
StorageKeys + main.swift into one macOS CLI binary to work without Xcode.

---

## 4. Entry points & build/run commands

| Command | Purpose | Status |
|---|---|---|
| `open GamesRoom.xcodeproj` | Full Xcode build (scheme `GamesRoom`) | Needs Mac with Xcode 27 — **never run on this host** |
| `./build-and-run-tests.sh` | Foundation tests + parse-check | **65/65 pass** (verified) |
| `python3 scripts/verify-xcode-project.py` | pbxproj structure validator | **exit 0** (verified) |
| `bash scripts/parse-check-swiftui.sh` | Syntax-only SwiftUI/Services gate | **34/34 pass** (verified) |
| `swift run` in `Tools/CasinoVisionProbe` | Vision probe corpus/metrics | Done, locked (see `docs/casino-vision-probe-report.md`) |

App entry: `GamesRoomApp` owns 4 `@StateObject` services (Auth, Room, Casino,
Scoring) and injects them as `@EnvironmentObject`. Forces `.preferredColorScheme(.dark)`.

Test entry: `main.swift` `TestRunner` — 65 `runner.run("...")` cases covering
PackRegistry, PackScoringResolver, ScoreSnapshot, LiveActivityRule, JSON
round-trips, PhotoHash, decoders.

---

## 5. Service layer (12 services)

| Service | File | Owns |
|---|---|---|
| `AuthService` | `Services/AuthService.swift` | currentUser, signIn/out, display name |
| `RoomService` | `Services/RoomService.swift` | rooms, events, RSVPs, leaderboard, journal, packs |
| `CasinoService` | `Services/CasinoService.swift` | balances, withdrawals, scans, attestations |
| `ScoringService` | `Services/ScoringService.swift` | host round submission (team mode, breakdown) |
| `MascotEngine` | `Services/MascotEngine.swift` | 25-voice templates + LLM (z.ai) voice |
| `NotificationDispatcher` | `Services/NotificationDispatcher.swift` | 3×3 cadence × RSVP matrix pushes |
| `CalendarService` | `Services/CalendarService.swift` | EventKit add/update/remove (T1.1) |
| `ScoreSnapshotStore` | `Services/ScoreSnapshotStore.swift` | App Group snapshot for widgets |
| `ScoreLiveActivityDriver` | `Services/ScoreLiveActivityDriver.swift` | Live Activity start/update/end |
| `SupabaseClient` | `Services/SupabaseClient.swift` | client provider (keys via Info.plist) |
| `StorageKeys` | `Services/StorageKeys.swift` | UserDefaults key registry |
| `RoomStore` (protocol + 2 impls) | `Services/RoomStore.swift` | `LiveRoomStore` (Supabase RPCs) / `InMemoryRoomStore` (default, seeded 3 rooms) |

Convention: views → services → protocol store → live/in-memory impls. Default
is in-memory so previews and no-network builds run. Each live-store method's
docstring names its RPC + migration.

---

## 6. Feature inventory (verified against tree + checklist + verification report)

**Shipped and green:**

- Auth: Apple Sign-In only; nonce intentionally omitted (GoTrue base64url vs hex mismatch, tracked upstream supabase/auth#2378).
- Rooms: create/join, 6-char single-use join codes, host/member roles, room switcher, last-viewed resume.
- Events: create/edit, RSVP (claimed/declined/unclaimed), briefing, decline re-entry (migration 046).
- Scoring: seasons + close (migration 048), seat deposits (043), team mode + round breakdown (049), score-correction badge (042), member event edit (050), chapter lines + season subtitle (051).
- Casino pack: per-member scan (040), withdrawals, attestations, 24h unscanned → P&L 0, pack payouts (047), seat grid.
- Packs: 4 packs (Casino, CAH, Monopoly Deal, Pluto Chess), pack-as-platform schema (041), store shell + how-to bodies, two-level install.
- Vision: on-device Core ML chip scan (`ChipScanSheet`), photo discard-by-default + opt-in keep (T1.2), hash + snapshot always.
- Widgets: Glance + Live Activity (suppressed during play) + Watch target, App Group snapshot channel, Live Activity driver wiring (024898a).
- Notifications: 3×3 matrix, permission prompt at join.
- Mascot: 25-voice templates + LLM broadcast/recap (z.ai), footer-caption constraint.
- Calendar: EventKit auto-add honoring host toggle, default off (T1.1).
- Icon: v3 GR monogram "The Ring" full size set wired (T1.3).
- CI: 3-gate macOS lane committed (T0.3).
- Polish: T1.4 audit — no design-bar violations found.
- Legal/docs: privacy policy, legal posture, app-store metadata, TestFlight notes, deployment guide.

**Gated / env-blocked (not gaps — decisions the plan forbids resolving silently):**

- T0.1 first Xcode build + device pass, T0.2 TestFlight upload — need a Mac with Xcode 27.
- T2.1 mascot matrix Wave 5 — gated on Q-TONE + Q-LLM-PROVIDER.
- T2.2 paid packs / StoreKit — gated on Q-PAID-PACKS.
- T2.3 cloud-vision hybrid — monitor only, after T0.2.
- Q-HOST-FEEDBACK — beta account count for first TestFlight cycle.

---

## 7. Data model (Supabase, 49 migrations 001–051)

Core tables: `users`, `rooms` (mascot config, V0.26 toggles, host journal),
`room_memberships` (role, points, season score, team), `join_codes`, `events`,
`packs`, `transactions` (the ledger), `casino_withdrawals`,
`casino_settlement_attestations`, `session_scans`, `round_submissions`,
`event_rsvps`, `room_packs`, `room_system_events`, `seat_deposits`, `seasons`.

RPC surface: ~25 RPCs (`get_my_rooms`, `create_room`, `redeem_join_code`,
`get_active_event`, `get_briefing_summary`, `get_room_leaderboard`,
`upsert_event_rsvp`, `create_event`, `update_room`, `update_host_journal`,
`withdraw_casino_chips`, `record_round_score`, `close_season`,
`set_member_team`, `get_event_rounds`, `record_member_scan` (legacy), …).
Each is traceable: live-store docstrings name RPC + defining migration.

iOS side: 40+ pure `Codable` models in `GamesRoom/Models/`, with defensive
decoders (legacy-column fallbacks on `Room`, `RedeemedRoom`).

---

## 8. Known issues & gaps (verified 2026-08-11)

**Blockers / high signal:**

1. **No Xcode.app on this host — T0.1/T0.2 never executed.** The first real
   `xcodebuild` build and device pass is still the unverified moment of truth.
   The verification report's own defect history proves the blind spot:
   CalendarService API mismatch (c2e2fc4) and icon pixel-size errors (1cfc162)
   both would have failed a real build.
2. **No git remote.** `git remote -v` empty. CI (`.github/workflows/ci.yml`)
   is committed but cannot run until a remote exists.
3. **Mascot LLM provider mismatch.** VISION.md §5.3/§8 mandate Apple Foundation
   Models; the tree calls z.ai glm-4.6. Gated on Q-TONE / Q-LLM-PROVIDER (T2.1).
4. **Calendar row lifecycle incomplete.** `CalendarService.removeEvent` exists
   but nothing calls it — no delete/settle surface in the Swift tree
   (`delete_event` RPC exists in migrations 022 with zero call sites). Calendar
   rows live until the host removes them manually. Documented in the
   verification report as a known limitation.
5. **Migration numbering gaps.** 009, 010, 037, 038 do not exist (001–051 with
   gaps; `011a`, `012a`, `022_v0.12` suffixes). Cosmetic, but worth a
   conventions note for future migration authors.

**Stale docs (drift):**

6. `docs/audit.md` — superseded (pre-V0.8 snapshot). This file replaces it as
   the live audit; consider archiving or deleting the old one.
7. `docs/v0.8-vision-checklist.md` — status column is stale for the W2.x
   slices (several rows say "—" or "deferred" for features now code-complete),
   and its verification section claims 36/36 tests (actual: 65).
8. `tests/README.md` — says "33 total" test cases; actual is 65.
9. `IMPLEMENTATION_PLAN.md` header status block — last updated mid-run; the
   T1.x rows are now DONE (only T0.1/T0.2 + Wave 2 remain).

**Worth knowing (not bugs):**

10. `record_member_scan` (migration 030) is the pre-V0.8 camera path — still
    callable but not surfaced in the UI. Keep until the attestation dispute
    surface is migrated.
11. `plutil -lint` on `AppIcon.appiconset/Contents.json` fails — host
    limitation (plutil expects plist, file is valid JSON by design). Do not
    "fix".
12. `Config.xcconfig` is gitignored (real Supabase keys). Missing xcconfig
    leaves literal placeholder keys — the Info.plist path is the source of
    truth.
13. Build artifacts `build/`, `games-room-tests` are gitignored; `.archive/`
    and `.hermes/` ignored too.
14. No TODO/FIXME markers anywhere by convention — debt lives in
    `ponytail:` comments. Grep them.

---

## 9. Recommended areas to change (next work)

Ordered by leverage:

1. **Get an Xcode host + git remote (T0.1/T0.2 + CI activation).** This is the
   single highest-value action: first real build, device pass on camera /
   Live Activity / Watch, TestFlight upload. Push to a remote to light up CI.
   Everything else below is secondary until the app has been built for real.
2. **Resolve the four gated decisions** (Q-TONE, Q-LLM-PROVIDER, Q-PAID-PACKS,
   Q-HOST-FEEDBACK) — they unlock T2.1/T2.2 and the beta invite list. Defaults
   exist in `IMPLEMENTATION_PLAN.md` §4.
3. **Close the CalendarService remove hook** once any delete/settle surface
   exists (one-line change per verification report).
4. **Fix stale docs** (#6–#9 above): refresh checklist statuses + test counts,
   update tests/README count, retire old `docs/audit.md`.
5. **Mascot matrix Wave 5 (T2.1)** after Q-TONE: complete the 75-cell matrix,
   settle the LLM provider, add season-end voice.
6. **Paid packs (T2.2)** after Q-PAID-PACKS: `StoreService` with
   Product/Transaction purchase + restore.
7. **Monitor on-device vision confidence** after beta (T2.3): cloud-vision
   hybrid only if recall/precision falls short in the field.
8. **Housekeeping:** note the migration-numbering convention (no renumbering —
   additive only), consider tracking or deleting leftover scripts (the
   V0.7→V0.8 pbxproj merge scripts were already removed; only the two live
   validators remain).

---

## 10. Verification baseline (re-run live during this audit)

```
./build-and-run-tests.sh            → 65 passed, 0 failed
bash scripts/parse-check-swiftui.sh → 34/34 pass
python3 scripts/verify-xcode-project.py → exit 0
git status                          → clean at a9c8e63
```

Xcode-host gates remain manual: no Xcode.app on this host.

End of audit.
