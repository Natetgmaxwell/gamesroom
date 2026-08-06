# Games Room — Codebase Audit (V0.8)

> **Audience.** A fresh engineer who has never seen this repo. The
> report below should let them find their feet in under an hour:
> know the stack, know the file layout, know the data model, know
> what is wired and what is still stubbed.
>
> **Scope.** Snapshot of the working tree at audit time, against
> `main` (`2cba2fb fix: repair Xcode target and Apple sign-in
> capability`, head of git history). Supersedes the V0.7.1 archive
> under `.archive/2026-07-31-pre-v0.8/` (read-only history).
>
> **Companion docs.**
> - `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` — the
>   product / layout brief the code is built against.
> - `docs/vision.md` — the durable product vision (connection-as-product-fit,
>   social north star, ledger-as-arc).

---

## 1. TL;DR

- **Stack.** Native iOS / iPadOS app (Swift 6, SwiftUI, SwiftPM).
  iOS 26 minimum (`MinimumOSVersion = 26.0` in `Info.plist`).
  Backend is **Supabase** (Postgres + GoTrue auth + RPCs +
  `supabase-swift` 2.54.1 SPM dep). No web/JS layer, no Cloudflare,
  no React Native. Apple Sign-In only.
- **Build host.** Verified buildable on Mac Studio (Xcode 27,
  iPhone 17 Pro). Foundation-only tests run on hosts without
  Xcode via `build-and-run-tests.sh` — **21/21 pass.**
- **Current state.** V0.8 is **feature-complete on the V0.8 plan's
  P0/P1 surface** — onboarding, pack catalog, scoring, virtual-only
  Casino, pack shelf, roster, notifications, host journal.
  Camera/Vision pipeline is parked; virtual-only Casino is the
  shipping path. The pre-V0.8 chips via the old
  `record_member_scan` RPC are still callable but not surfaced in
  the V0.8 UI.
- **Two parallel backends.** `InMemoryRoomStore.shared` is the
  default `RoomStore` (no-infra path). `LiveRoomStore.shared`
  routes through `SupabaseClientProvider` (production). Same
  protocol, swappable at `RoomService.init`.
- **Two tab navigation only.** `Rooms` (default) and `Settings`.
  No third tab, no iPad split-view, no TV-out.

---

## 2. Top-level layout

```
games-room/
├── .archive/2026-07-31-pre-v0.8/      # Frozen V0.7.1 reference (read-only)
├── .designs/room-page/                 # Design source (currently empty)
├── .hermes/plans/                      # V0.8 brief (planning, not build)
├── .swiftpm/                           # Xcode user-side SPM cache
├── build/                              # Empty Build/ dir (Xcode scratch)
├── docs/
│   ├── audit.md                        # ← this file
│   └── vision.md                       # Product vision / substrate concepts
├── games-room-tests                    # Pre-built Foundation test binary
├── scripts/
│   ├── merge-v0-8-pbxproj.py           # Additive pbxproj merge helper (V0.8 build)
│   ├── rewrite-pbxproj.py              # Brutal-force V0.7→V0.8 pbxproj rewriter
│   └── verify-xcode-project.py         # pbxproj sanity check (see §11)
├── Supabase/
│   └── migrations/                     # 036 SQL migrations, 001-036
├── tests/
│   ├── README.md                       # Test-runner doc
│   └── main.swift                      # ← ACTUAL tests live at repo root
├── build-and-run-tests.sh              # Foundation test runner
├── main.swift                          # ← Foundation test cases (21 cases)
├── GamesRoom.xcodeproj/                # Xcode project (SwiftPM-wired)
└── GamesRoom/                          # ← App source
    ├── Auth/                           # SignInView
    ├── Assets.xcassets                 # AppIcon, AccentColor
    ├── GamesRoom.entitlements          # Sign in with Apple capability
    ├── GamesRoomApp.swift              # @main, owns 4 services
    ├── Info.plist                      # MinOS, usage strings, Supabase plist keys
    ├── Config.xcconfig                 # SUPABASE_URL + KEY (gitignored)
    ├── ContentView.swift               # Two-tab root: Rooms + Settings
    ├── Theme.swift                     # 80/20/10 design tokens, SectionCard
    ├── Models/                         # 34 pure-data models
    ├── Packs/                          # 4 pack definitions + scoring contract
    ├── Services/                       # 8 service classes (auth/room/casino/...)
    └── Views/                          # 12 views + Components/
```

> **Surprise.** `main.swift` at repo root is the **Foundation
> test entry point**, not an iOS binary's `main`. The build
> script compiles it together with `GamesRoom/Models/*.swift` and
> `GamesRoom/Packs/*.swift` into one CLI binary. See §10.

---

## 3. Framework & dependencies

| Layer            | Choice                                                                                                |
|------------------|-------------------------------------------------------------------------------------------------------|
| Language         | Swift 6                                                                                               |
| UI               | SwiftUI, `@ObservableObject` services, no UIKit                                                       |
| Concurrency      | `@MainActor` services, async/await throughout                                                          |
| Build            | Xcode 27, target `arm64-apple-macosx14.0` for tests, iOS 26 device target                              |
| Auth             | `AuthenticationServices` (Apple ID) → `signInWithIdToken` → Supabase GoTrue                          |
| Backend          | Supabase Postgres + PostgREST + RPCs                                                                  |
| SDK              | `supabase-swift` 2.54.1 (SPM)                                                                         |
| SPM transitive   | `swift-asn1`, `swift-clocks`, `swift-concurrency-extras`, `swift-crypto`, `swift-http-types`, `xctest-dynamic-overlay` |
| Local persistence| `@AppStorage` (`lastViewedRoomIdString`) and `UserDefaults` (sign-out cleanup). No Core Data, no SQLite. |
| Notifications    | `UserNotifications` via `NotificationDispatcher`                                                       |
| Camera/Vision    | **Parked.** `Info.plist` declares `NSCameraUsageDescription` but no AVCapture/Vision code is on the V0.8 path. |

> **ponytail (recurring project idiom).** The codebase uses a
> ponytail comment marker to flag workarounds / sharp edges that
> need future cleanup. Search for "ponytail:" in any file to see
> them. They are not TODO/FIXME — they are deliberate trackings.

---

## 4. Where things live

### 4.1 Source-tree conventions

| Path                         | Purpose                                                                 |
|------------------------------|-------------------------------------------------------------------------|
| `GamesRoom/Models/*.swift`   | Pure `Codable`/`Hashable` value types. No SwiftUI, no Supabase.         |
| `GamesRoom/Packs/*.swift`    | Pack contract + 4 V0.8 pack definitions + scoring resolver.              |
| `GamesRoom/Services/*.swift` | `@MainActor @ObservableObject` services + protocol-based stores.         |
| `GamesRoom/Views/*.swift`    | Top-level screens + sheets.                                             |
| `GamesRoom/Views/Components/`| Reusable sub-views (LeaderboardRow, MascotBubble, SeatGridView, TrajectorySparkline). |
| `GamesRoom/Auth/*.swift`     | Sign-in surface only.                                                   |
| `main.swift` (repo root)     | Foundation-only test cases (compiled in one shot by `build-and-run-tests.sh`). |
| `tests/README.md`            | Test-runner documentation. Path drift fixed in B1.4 — see `tests/README.md` for the canonical layout. |

### 4.2 Service layer (D1-D3 + scoring)

| Service           | File                              | Owns                                                                 |
|-------------------|-----------------------------------|----------------------------------------------------------------------|
| `AuthService`     | `Services/AuthService.swift`      | `currentUser`, `loadCurrentUser`, `signOut`, `updateDisplayName`.    |
| `RoomService`     | `Services/RoomService.swift`      | Rooms list, create/join, settings, RSVP upsert, event create, journal. |
| `CasinoService`   | `Services/CasinoService.swift`    | Balance read, withdraw, member-scan, attestations, transactions.     |
| `ScoringService`  | `Services/ScoringService.swift`   | Host-side round submission via `record_round_score` RPC.             |
| `MascotEngine`    | `Services/MascotEngine.swift`     | 25-voice template interpolation (5 personalities × 5 ideologies × 4 kinds). |
| `NotificationDispatcher` | `Services/NotificationDispatcher.swift` | 3×3 cadence×RSVP matrix, UNUserNotificationCenter wrapper. |

### 4.3 Store protocol abstraction (D2)

| Layer                | File                                                              | Implements                                                                 |
|----------------------|-------------------------------------------------------------------|----------------------------------------------------------------------------|
| `RoomStore` protocol | `Services/RoomStore.swift` (lines 65-178)                         | The contract: rooms list, create, join codes, members, active event, briefing, leaderboard, RSVP, event create, room settings update, host journal. |
| `LiveRoomStore`      | `Services/RoomStore.swift` (lines 192-498)                        | Routes every method through `SupabaseClientProvider.shared.rpc(...)`.      |
| `InMemoryRoomStore`  | `Services/RoomStore.swift` (lines 512-1069)                       | Seeded with 3 rooms (Carwoola Crew, Pluto Chess Sundays, Felt Faction). Default. |
| `ScoringStore` protocol | `Services/ScoringService.swift` (lines 43-56)                  | `recordRound(roomId:eventId:packSlug:roundIndex:entries:)`.                |
| `LiveScoringStore` / `InMemoryScoringStore` | same file                       | Supabase RPC and echo-back fakes.                                          |

The split is deliberate: views talk to `RoomService` / `ScoringService`,
those services talk to the protocol, the protocol has two impls
(live Supabase + in-memory). Default is in-memory so previews +
no-network builds run.

### 4.4 View layer (E1-E3)

| View                  | File                                | Role                                                              |
|-----------------------|-------------------------------------|-------------------------------------------------------------------|
| `ContentView`         | `ContentView.swift`                 | Two-tab `TabView` (Rooms, Settings). Auth gate via sheet.          |
| `RoomPage`            | `Views/RoomPage.swift`              | Persistent home: list + last-viewed hero + empty state.            |
| `RoomDetailView`      | `Views/RoomDetailView.swift`        | Three-slot stage. Houses BriefingSlot / WitnessSlot / CeremonialCard / StandingsSection / PackShelfReadOnly / MemberRosterReadOnly / MascotFooterCaption. |
| `SettingsPage`        | `Views/SettingsPage.swift`          | Wraps `AppSettingsView`.                                          |
| `AppSettingsView`     | `Views/AppSettingsView.swift`       | Display name + log-out.                                          |
| `SignInView`          | `Auth/SignInView.swift`             | Apple Sign-In sheet.                                              |
| `CreateRoomSheet`     | `Views/CreateRoomSheet.swift`       | Onboarding: create room with mascot + bonus.                     |
| `JoinRoomSheet`       | `Views/JoinRoomSheet.swift`         | Onboarding: redeem 6-char code.                                   |
| `AddEventSheet`       | `Views/AddEventSheet.swift`         | Host creates new event with pack picker.                          |
| `RoomSettingsSheet`   | `Views/RoomSettingsSheet.swift`     | Host-only room settings (mascot + operations + toggles + journal + share code + roster). |
| `HostScoreEntrySheet` | `Views/HostScoreEntrySheet.swift`   | Host records a single-winner round (CAH / Monopoly / Pluto Chess). |
| `WithdrawChipsSheet`  | `Views/WithdrawChipsSheet.swift`    | Member withdraws chips (P0.5 virtual-only Casino).                |
| `SettleCasinoSheet`   | `Views/SettleCasinoSheet.swift`     | Member returns chips → scoring.                                   |

### 4.5 Components (reusable sub-views in `Views/Components/`)

| Component             | Purpose                                                            |
|-----------------------|--------------------------------------------------------------------|
| `LeaderboardRow`      | One standings row. Includes trajectory sparkline on tap.           |
| `MascotBubble`        | Tap-target deep-dive into mascot voice (header-level).            |
| `SeatGridView`        | 2-3-2 seat grid used by Witness Slot.                              |
| `TrajectorySparkline` | Mini line chart of last-N deltas.                                  |

---

## 5. Data model

### 5.1 Supabase tables (from migrations 001-036)

| Table                     | Introduced       | Role                                                                  |
|---------------------------|------------------|-----------------------------------------------------------------------|
| `public.users`            | 001              | Profile row joined to GoTrue `auth.users`. Holds `display_name`.      |
| `public.rooms`            | 001, extended V0.6 / V0.8 / V0.26 / 036 | Room + mascot config + V0.26 feature toggles + `host_journal` (036). |
| `public.room_memberships` | 004              | Per-(room, user) role. + `points_balance` (017), + `season_score` (019). |
| `public.join_codes`       | 004              | 6-char codes minted by hosts, redeemed by invitees.                   |
| `public.events`           | 006              | Scheduled / in-play / settled games-night. + `pack_slug` (V0.8).      |
| `public.packs`            | 012              | Authoritative pack catalog; iOS registry mirrors this.                |
| `public.transactions`     | 012              | The ledger. Every score / withdraw / settlement writes here.          |
| `public.casino_withdrawals` | 025            | One row per chip withdrawal.                                          |
| `public.casino_settlement_attestations` | 029 | Dispute surface for per-member scans.                                |
| `public.session_scans`    | 029 / 030        | Vision output snapshots (legacy; parked in V0.8 UI).                 |
| `public.round_submissions`| 035              | One row per host-submitted round (idempotency on `(room,event,round)`). |
| `public.event_rsvps`      | 033              | Pre-play RSVP (claimed/declined/unclaimed).                           |
| `public.casino_withdrawals_v0_8` | (V0.8)   | Per-V0.8 withdrawal projection — actual table name in 025.            |

### 5.2 RPC surface (the iOS app's public contract)

| RPC                          | Migration | Called by                                       | Returns                       |
|------------------------------|-----------|-------------------------------------------------|-------------------------------|
| `get_my_rooms`               | 005 → 036 | `LiveRoomStore.fetchRooms()`                    | `[Room]`                      |
| `create_room`                | 022       | `LiveRoomStore.createRoom(...)`                 | `UUID`                        |
| `generate_join_code`         | 004 + 006 | `LiveRoomStore.generateJoinCode(roomId:)`       | `String` (6 chars)            |
| `redeem_join_code`           | 004 + V0.18 | `LiveRoomStore.redeemJoinCode(code:)`         | `RedeemedRoom`                |
| `get_room_members`           | 008       | `LiveRoomStore.fetchRoomMembers(roomId:)`       | `[Member]`                    |
| `get_active_event`           | 018       | `LiveRoomStore.fetchActiveEvent(roomId:)`       | `Event?`                      |
| `get_briefing_summary`       | 024       | `LiveRoomStore.fetchBriefing(eventId:)`         | `BriefingSummary?`            |
| `get_room_leaderboard`       | 022       | `LiveRoomStore.fetchLeaderboard(roomId:)`       | `[LeaderboardEntry]`          |
| `get_my_event_rsvp`          | 033       | `LiveRoomStore.fetchCurrentMemberRSVP(eventId:)`| `MemberRSVPState`             |
| `upsert_event_rsvp`          | 033       | `LiveRoomStore.upsertEventRSVP(eventId:state:)` | `MemberRSVP`                  |
| `create_event`               | 006 + V0.8 | `LiveRoomStore.addEvent(...)`                  | `UUID`                        |
| `update_room`                | 020 → 032 | `LiveRoomStore.updateRoom(...)`                 | `Room`                        |
| `update_host_journal`        | 036       | `LiveRoomStore.updateHostJournal(roomId:journal:)` | `Room`                     |
| `get_withdrawal_balance`     | (V0.27)   | `CasinoService.loadWithdrawalBalance(...)`      | `bigint`                      |
| `withdraw_casino_chips`      | 025       | `CasinoService.withdraw(...)`                   | `CasinoWithdrawal`            |
| `record_member_scan`         | 030 (legacy) | `CasinoService.submitMemberScan(...)`        | `bool` (then refetch)         |
| `close_stale_attestations`   | 029       | `CasinoService.getMyOpenAttestations()` (lazy)  | (no rows)                     |
| `getMyOpenAttestations`      | 029       | `CasinoService.getMyOpenAttestations()`         | `[OpenAttestationSummary]`    |
| `get_event_transactions`     | 024       | `CasinoService.getEventTransactions(eventId:)`  | `[EventTransaction]`          |
| `record_round_score`         | 035       | `LiveScoringStore.recordRound(...)`             | `ScoreSubmission`             |

> **Live RPC traceability.** Each `LiveRoomStore` / `LiveScoringStore`
> method's docstring names the live RPC and the migration that
> defines it. Grep `// live RPC is \`X\`` to find the wire.

### 5.3 iOS model layer (`GamesRoom/Models/`)

34 pure-data types. Highlights:

| Model                     | Notable fields                                                                |
|---------------------------|-------------------------------------------------------------------------------|
| `Room`                    | mascot {name, personality, ideology, apiKey}, `userRole`, V0.26 toggles, `hostJournal` |
| `Event`                   | `playedAt`, `startedAt`, `settledAt`, `hostFinalized`, `packSlug`              |
| `Member`                  | `displayName`, `role` (host / member)                                          |
| `MemberRSVP`              | `state` (claimed / declined / unclaimed), `respondedAt`                        |
| `BriefingSummary`         | `seatsLeft = max(0, total - claimed - declined)`                                |
| `LeaderboardEntry`        | `pointsBalance`, `seasonScore`, `trajectory: [SessionDelta]`                    |
| `CasinoWithdrawal`        | `pointsWithdrawn`, `withdrawnAt`                                              |
| `SettlementAttestation`   | `visionAmountPoints`, `claimedAmountPoints`, `disputed`, `attestedAt`         |
| `RedeemedRoom`            | `roomId`, `roomName` (falls back to `"Room"` if name missing)                  |
| `User`                    | `id`, `displayName`                                                            |
| `MascotPersonality` / `MascotPoliticalIdeology` / `DetectionSource` / `RoomRole` / `MemberRSVPState` / `SeasonStatus` / `AwardType` / `ChipColor` / `VisionProvider` / `Season` / `SeasonAward` / `CallForward` / `ChapterLine` / `OpenAttestationSummary` / `CasinoConfig` / `Session` / `SessionScan` / `SessionDelta` / `SocialPreference` / `VisionSnapshot` / `BoundingBox` / `DetectedStack` | various V0.5 / V0.6 / V0.7 / V0.27 / V0.29 surfaces |

`Room` and `RedeemedRoom` define explicit `init(from:)` decoders
that fall back to V0.8 defaults for missing legacy columns — the
app tolerates older `rooms` rows without V0.26 / `host_journal` /
V0.8 columns. (See `Room` decoder; `RedeemedRoom` falls back to
`"Room"` when `room_name` is missing.)

> **Format drift safety.** Both `iso8601` and
> `iso8601[.withFractionalSeconds]` are used depending on the
> server column. `Date` fields in `ScoreSubmission`,
> `Event`, `MemberRSVP`, `LeaderboardEntry` round-trip cleanly in
> tests.

---

## 6. Auth model

- **Provider.** Apple Sign-In only.
  `AuthenticationServices.SignInWithAppleButton` → credential
  identityToken → `SupabaseClientProvider.shared.auth.signInWithIdToken(credentials: .init(provider: .apple, idToken: ...))`.
- **Nonce intentionally omitted** (per `SignInView.swift` ponytail
  comment): GoTrue hashes nonces as hex while Apple encodes them
  as base64url — they never match. Tracked upstream at
  supabase/auth#2378.
- **Profile join.** `AuthService.loadCurrentUser()` joins the
  GoTrue session to the `public.users` row by id. Failures
  collapse to `currentUser = nil` (signed-out state).
- **Sign-out.** Clears `lastViewedRoomIdString` from
  `UserDefaults`, calls `auth.signOut()`, clears `currentUser`.
- **Entitlements.** `com.apple.developer.applesignin` present in
  `GamesRoom.entitlements`.
- **Plist keys.** `SUPABASE_URL` and `SUPABASE_ANON_KEY` flow
  through `Info.plist` → `Bundle.main` → `SupabaseClientProvider`.
  `Config.xcconfig` is the source of truth (gitignored).
  ponytail: `xcconfig` parses `//` as a line-comment marker, so
  any URL containing `//` would silently lose the host — the
  Info.plist path was adopted to dodge that.

---

## 7. UI model

### 7.1 The V0.8 three-slot stage (RoomDetailView)

`RoomDetailView` rotates by time-to-event via a `V0State` enum:

| State          | Trigger                                                      | Slot                    |
|----------------|--------------------------------------------------------------|-------------------------|
| `.loading`     | no data yet                                                  | (spinner)               |
| `.upcoming`    | playedAt > now + RSVP `.unclaimed`                           | Pre-play Briefing       |
| `.claimed`     | playedAt > now + RSVP `.claimed`                             | Pre-play Briefing (read-only) |
| `.declined`    | playedAt > now + RSVP `.declined` (terminal)                 | Pre-play Briefing (terminal) |
| `.inPlay`      | playedAt ≤ now + live + no withdrawals                       | At-play Witness Screen (Withdraw CTA) |
| `.settleRound` | playedAt ≤ now + `hostFinalized == true` + not all scanned  | At-play Witness Screen (Scan CTA) |
| `.justSettled` | `settledAt` within last 24h + no new event                   | Post-play Ceremonial Card |
| `.readStandings` | no active event + no recent settle                         | Quiet state             |

A `.tonightEvent` state from the brief is collapsed into
`.inPlay` here — the V0.8 implementation triggers the Withdraw
CTA the moment play begins (`playedAt ≤ now`) and skips an
intermediate "tonight, no withdrawals yet" branch.

### 7.2 Room page (RoomPage)

- List view + last-viewed hero card + empty state.
- Empty state branches on `isKnownHost`: hosts see "Create one
  to get started" + "Ask a friend for a join code" (both
  present). Members see "Create your own room" + "Ask a friend
  for a join code".
- `@AppStorage("lastViewedRoomIdString")` mirrors the most-recent
  room id so cold launch auto-resumes.
- Toolbar: host-only gear icon on the resolved last-viewed room
  opens `RoomSettingsSheet`.

### 7.3 Pack shelf

Read-only on the room page (`PackShelfReadOnly`). Tiles render
the four V0.8 packs with icon + description + chevron-right.
Tap navigates to a how-to guide placeholder — **the how-to body
itself is deferred to V0.9**; only the tap surface ships here.

### 7.4 Design tokens (Theme.swift)

| Group      | Tokens                                                                                                  |
|------------|---------------------------------------------------------------------------------------------------------|
| Palette    | `background`, `surface`, `primaryText`, `hairline`, `accent` — 5 colors, dark-mode-first.               |
| Typography | `display` (28pt serif), `title` (22pt semibold), `body` (17pt), `caption` (13pt), `footnote` (11pt).   |
| Layout     | `gutter` (32), `cardInset` (16), `gridCellMin` (320), `edgePadding` (16), `sectionSpacing` (24).        |
| SectionCard | `.standard` (no wash) / `.hero` (10% brass accent wash). One `.hero` per slot.                       |

No new components may be added to `Theme.swift` without a
deliberate reason (per file comment).

### 7.5 Helpers

- `.sectionCard(.standard | .hero)` — wraps a `VStack` with
  surface fill + hairline border + rounded corners.
- `.contentColumn(maxWidth:)` — wraps content in an iPhone-shaped
  column. iPhone fills the screen; iPad centers a 560pt column
  with black margin.

---

## 8. State management

- All services are `@MainActor @ObservableObject`. SwiftUI views
  inject via `@EnvironmentObject` from `GamesRoomApp` (the
  `@StateObject` owner).
- `RoomService` holds `@Published` caches keyed by id:
  `rooms`, `activeEventByRoom`, `briefingByEvent`,
  `leaderboardByRoom`, `rsvpByEvent`, `membersByRoom`.
  Cache writes happen on the main actor after `await`.
- `ScoringService` holds `lastSubmission` + `lastError` for
  the host-side dashboard.
- `CasinoService` holds `isLoading` + `lastError`.
- `AuthService` holds `currentUser`.
- All action methods on services set `lastError = nil` on
  success or `lastError = error.localizedDescription` on
  failure. The UI surfaces `lastError` as a transient banner
  (no public-shame framing per V0.8 brief §"no public shame").
- No Combine subscriptions. No `Observable` macro. Plain
  `@Published` + `@EnvironmentObject`.

---

## 9. Build & deployment

### 9.1 iOS app build (Xcode)

```
cd "/Users/nathanmaxwell/Documents/VS Code/games-room"
open GamesRoom.xcodeproj
# Or CLI:
xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Sign-in capability is wired in `project.pbxproj`
(`com.apple.SignInWithApple` in `SystemCapabilities`). The
`games-room` team identifier is set on both Debug and Release
configurations (per git log `17d9723 fix signing`).

### 9.2 Foundation-only test runner (no Xcode)

```
cd "/Users/nathanmaxwell/Documents/VS Code/games-room"
./build-and-run-tests.sh
```

Compiles `main.swift` + `GamesRoom/Models/*.swift` +
`GamesRoom/Packs/*.swift` into one Foundation binary. Skips
SwiftUI / Supabase / UserNotifications (which need the iOS SDK).

**Result:** 21/21 pass on the current binary
(`games-room-tests`, built 2026-08-05 10:29).

### 9.3 pbxproj verification

```
python3 scripts/verify-xcode-project.py
```

Sanity-checks the Xcode project:
- Every `.swift` under `GamesRoom/` has a `PBXFileReference`
  AND is in the Sources build phase.
- Both Debug + Release configurations set
  `CODE_SIGN_ENTITLEMENTS = GamesRoom/GamesRoom.entitlements`.
- Sign-in-with-Apple capability is declared.
- `Config.xcconfig` is wired to all four build configurations
  (project + target × Debug/Release).
- The shared scheme targets the right `PBXNativeTarget`.

Run this after every `project.pbxproj` edit. The
`rewrite-pbxproj.py` and `merge-v0-8-pbxproj.py` scripts were
the V0.7→V0.8 pbxproj-merge tools; they're kept as historical
artefacts in `scripts/` and untracked (not committed).

### 9.4 Deployment targets

- iOS / iPadOS 26.0 minimum.
- Universal device target (iPhone + iPad), portrait + all
  landscape orientations.
- iPad renders the iPhone column centered with black margin
  (no iPad split view).
- Bundle id and team live in the Xcode target settings (not in
  `Config.xcconfig`).

---

## 10. Tests

- **21 Foundation-only cases** in `main.swift` (repo root).
  Covers `PackRegistry` (4), `PackScoringResolver` (3),
  `ScoreEntry` JSON round-trip, `Room` decoder (V0.26 +
  legacy fallback), `RedeemedRoom` decoder, `BriefingSummary`
  arithmetic, `Event` round-trip, `MemberRSVPState` semantics +
  rawValue round-trip, `MemberRSVP` JSON decode, `PackMetaValue`
  round-trip, `LeaderboardEntry` round-trip.
- **iOS-side tests** live in Xcode via `xcodebuild test`. Not
  enumerated here — `scripts/verify-xcode-project.py` and
  `build-and-run-tests.sh` are the no-Xcode paths.
- **What is NOT covered.** The `LiveRoomStore` RPC wrappers
  themselves; `LiveScoringStore`; `CasinoService` network paths;
  any SwiftUI view. These require a Mac with Xcode.app for
  `xcodebuild test` against the iOS SDK.

> **Tests README path drift.** `tests/README.md` referenced the
> old `main.swift`-inside-`tests/` and
> `build-and-run-tests.sh`-inside-`tests/` layout. Fixed in B1.4
> — the actual entry points are **`main.swift` at the repo
> root** with **`build-and-run-tests.sh` at the repo root**.
> The `tests/` directory is documentation-only.

---

## 11. Half-finished features, TODOs, broken scripts

A walkthrough flagged these:

| Issue                                                                                       | Status                                                                                                                  |
|---------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------|
| `Room.swift` line 34: `let mascotApiKey: ***` — the literal type name appears as `***` in on-disk text. | `***` is a redaction marker (matches `GamesRoom/Models/VisionProvider.swift` API-key field and `.archive/.../Docs/*.md`). Not a code defect. The compiler reads `String?`. Leave it. |
| `tests/README.md` references paths that don't match the actual test layout.                 | Cosmetic — fix the README to point at `/main.swift` and `/build-and-run-tests.sh`. Trivial.                              |
| Empty trailing " 2" directories (`GamesRoom/Auth 2/`, `Models 2/`, `Services 2/`, `Views 2/`, `Assets 2.xcassets/`) | Finder duplicates from the V0.7→V0.8 file moves (Aug 1). Empty. Safe to `rm -rf` after review, but `rm -rf` is destructive — run from the repo root and confirm contents are empty first. |
| `scripts/merge-v0-8-pbxproj.py` and `scripts/rewrite-pbxproj.py` are untracked               | Historical V0.7→V0.8 pbxproj merge helpers. Not part of the V0.8 build flow. Track them or delete in a follow-up.        |
| No `TODO` / `FIXME` / `HACK` markers anywhere in `GamesRoom/`.                              | Confirmed via `grep -rni 'todo\|fixme\|xxx\|hack' --include='*.swift' GamesRoom/`. The codebase has no deferred-work markers — debt lives in `ponytail:` comments instead. |
| `PackDefinition.swift` comments mention a non-existent XCTest target            | Drift — fixed in B1.4 by removing the comment. The 27 Foundation cases live at the repo-root `main.swift`. |
| How-to guide placeholder taps on pack shelf rows                                          | Tap surface ships, body is V0.9 (per comment). Documented as open question.                                              |
| `record_member_scan` RPC is still on the CasinoService path                                 | Pre-V0.8 camera flow. Not surfaced in V0.8 UI but still callable. Safe to keep; not safe to remove without migrating the attestation dispute surface. |
| `MascotFooterCaption` reads `MascotEngine.generateVoice(...kind: .postPlayRecap)` with `memberCount: 0, memberNames: []` | Pure template interpolation — fills placeholder rows with empty values. Brief acknowledges mascot voice is v0.9; this is the V0.8 placeholder per Q7. |
| `RoomDetailView.openHostScore` for `withdraw_return` packs opens `SettleCasinoSheet`         | Implemented. Brief said `SettleCasinoSheet` is the host's at-play surface for casino, and `HostScoreEntrySheet` for single-winner — split is in place. |
| Casino virtual-only mode: no camera/Vision exercised                                       | By design (P0.5 acceptance). Camera entitlements + plist strings are present for V0.9 wiring.                            |
| `SettleCasinoSheet` opens with `withdrawn: 0` default                                       | Comment in `RoomDetailView.openScan` notes "Until we wire the attestation → withdrawn lookup, default to 0 so the sheet always renders. The member can edit via the stepper." This is the intended V0.8 fallback. |
| `Room.swift` `init(from:)` does not fall back the missing-but-present `mascot_api_key` differently from `String?` | Already handled — `decodeIfPresent` collapses to `nil`.                                                                  |
| `CasinoService.submitMemberScan` sends `p_session_id` (the legacy param name)                | Comment notes the migration 030 RPC is `record_member_scan(p_session_id, bigint, jsonb)` and folds `source` / `confidence_avg` into the snapshot envelope before sending. Working as intended. |
| `RoomDetailView.refresh()` fans out 6 parallel loads via `async let`                          | OK. Each `loadXIfNeeded` is gated on cache presence for the expensive ones.                                              |
| App-level: SwiftUI `.task { await roomService.refresh() }` on `RoomPage`                       | Already there.                                                                                                            |

---

## 12. Stack conventions (the take-away)

If you are adding to this codebase, the conventions are:

1. **Models are pure.** No SwiftUI, no Supabase, no `import`
   beyond `Foundation`. Put value types in `GamesRoom/Models/`.
2. **Services are `@MainActor @ObservableObject`.** Wire a
   protocol-store if you need a swappable backend
   (`RoomStore` / `ScoringStore`). Defaults to in-memory.
3. **Live stores call RPCs via `SupabaseClientProvider.shared`.**
   Each method's docstring names the RPC + migration.
4. **Views read service caches via `@EnvironmentObject`.** No
   ad-hoc singletons. No `@StateObject` outside the app entry
   point.
5. **Theme tokens live in `Theme.swift` only.** No ad-hoc
   colors, no inline hex. `.sectionCard(.standard | .hero)` for
   surfaces. `.contentColumn()` for iPhone-column-on-iPad.
6. **One accent at a time.** `.hero` SectionCard appears at
   most once per slot. Single primary CTA per state, always.
7. **Ponytail comments mark sharp edges.** Use the
   `ponytail:` prefix when adding one. Don't use `TODO` /
   `FIXME`.
8. **No new components in `Theme.swift` without a deliberate
   reason.** (File comment, line 7.)
9. **Tests are Foundation-only.** New tests go in `main.swift`
   as `runner.run("name") { ... }` blocks. 21/21 pass.
10. **Verify the pbxproj after touching it.** Run
    `python3 scripts/verify-xcode-project.py` after every Xcode
    project edit.

---

## 13. Risks & follow-ups

The implementation-step task can lift these into a follow-up
card:

1. **Camera/Vision path is parked.** `NSCameraUsageDescription`
   is set; no AVCapture/Vision code on the V0.8 path. P0.5 ships
   virtual-only Casino.
2. **Pack how-to guides.** Shelf taps are wired; bodies are
   V0.9.
3. **Mascot voice is templated only.** 25-voice matrix; no LLM
   call. Open question #7 in the V0.8 brief.
4. **iPad split view.** Not implemented. iPad renders the iPhone
   column centered with black margin per `BRIEF.md` Q2.
5. **iOS notification permission UX.** No prompt surface yet
   (open question #3). Notification cadence is best-effort.
6. **Member-side event edit surface (open question #9).** Decline
   is terminal in V0.8; re-entry path is V0.9.
7. **`tests/README.md` path drift.** Trivial doc fix.
8. **Empty " 2" directories.** Optional cleanup.
9. **`PackDefinition.swift` test-file reference.** Optional
   comment fix.
10. **No CI.** Builds are validated manually on a Mac with
    Xcode (`build-and-run-tests.sh` + `verify-xcode-project.py`).
    Adding a CI lane is out of scope for this audit.

---

## 14. What exists, what is missing

**Built (V0.8 surface):**
- Apple Sign-In auth + `AuthService` + `currentUser`.
- Two-tab `ContentView` (Rooms + Settings).
- Rooms list with last-viewed hero, empty-state CTA, pull-to-refresh.
- Create-room flow with mascot config + starting bonus.
- Join-code redemption (6 chars, uppercase, validated client + server).
- Room detail (3-slot stage: Briefing / Witness Screen / Ceremonial).
- RSVP (claimed / declined / unclaimed) with terminal decline.
- Pack catalog (4 V0.8 packs) + scoring resolver + score submission.
- Virtual-only Casino (Withdraw / Return) via `record_round_score`.
- Pack shelf (read-only).
- Member roster (read-only on page; host-only edit surface in
  room settings).
- Leaderboard (full board, your row highlighted).
- Host settings: mascot + operations + feature toggles.
- Host journal (≤280 chars, hard-clamped client + server).
- Host-side invite-code minting.
- Display-name + sign-out in app settings.
- `@AppStorage("lastViewedRoomIdString")` cold-launch resume.
- Mascot footer caption (one-line italic, all states).
- NotificationDispatcher (3×3 cadence × RSVP matrix, idempotent
  at UN layer).

**Missing (deferred per V0.8 brief):**
- Camera/Vision chip-scan pipeline (V0.9).
- LLM-driven mascot voice (V0.9).
- Member-side event edit (V0.9; decline is terminal in V0.8).
- Pack how-to guide bodies (V0.9).
- Cross-room social surface (V2).
- Season-end awards surface beyond the `.ended` state branch
  (V0.8 has `season_status` model but no awards card).
- iPad split-view (intentionally collapsed to iPhone-column-on-iPad).
- Watch complications / Live Activities (intentionally out of
  scope per brief Q3).

---

## 15. Acceptance-criteria check

> "A fresh engineer could use the report alone to understand
> what is built, what is missing, and what stack conventions to
> follow."

- **What is built:** §4 (file layout), §5 (data model), §6
  (auth), §7 (UI), §8 (state), §14 (built-vs-missing summary).
- **What is missing:** §11 (deferred + half-finished), §13
  (follow-ups), §14 (missing list).
- **Stack conventions:** §3 (framework), §9 (build), §10
  (tests), §12 (conventions).

End of report.
