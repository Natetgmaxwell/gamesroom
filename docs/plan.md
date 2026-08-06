# Games Room — V0.8 Implementation Plan

> **Audience.** An engineer who has read `docs/vision.md` (the
> shape) and `docs/audit.md` (the as-built surface) and now needs
> a sequenced plan to close the remaining gaps.
>
> **Companion docs.**
> - `docs/vision.md` — the durable product vision.
> - `docs/audit.md` — the as-built audit (V0.8 snapshot, 64 Swift
>   files, 21/21 Foundation tests passing).
> - `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` — the
>   converged layout / state-machine brief this plan implements.
>
> **Method.** Every requirement in vision.md (§3.1–§3.9, §4) is
> tagged with a status against the current code: **done**,
> **partial**, **missing**, or **out-of-scope (non-goal)**. Every
> missing or partial line has a concrete change (files / module /
> migration / RPC), an effort estimate (S / M / L), and a milestone
> assignment. The milestone order respects hard dependencies
> (schema before RPC before service before view) but parallelises
> everything that can be parallelised. Open questions from
> `vision.md` §6 and the V0.8 brief "What's Still Open" are
> consolidated into §5 for Nathan's attention — they are
> decisions the plan cannot make on its own.
>
> **Effort key.** S = ≤ ½ day (one engineer). M = 1–2 days. L =
> 3+ days or requires a design pass first.

---

## 1. TL;DR

The V0.8 surface is **largely built** — onboarding, pack catalog,
scoring, virtual-only Casino, pack shelf, roster, three-slot stage,
notifications, host journal. **21/21 Foundation tests pass.** The
remaining work is concentrated in four places:

1. **Slot-rotation fidelity** — the V0.8 brief lists 10 `DominantAction`
   cases; the implementation has 8. Two cases (`.tonightEvent`,
   `.seasonClose`) are either collapsed or missing. **M1.**
2. **Section discipline (Track E verdicts)** — a handful of sections
   are misplaced, duplicated, or have a11y regressions.
   Specifically: pack CTAs on the room page, the inline
   `EventTransactionsView`, the `MascotFooterView` `onTapGesture`
   a11y bug, and the host-room-settings sheet (needs to split into
   Social / Operations / Members). **M2.**
3. **Casino V0.29 settlement surface** — the audit confirms
   `record_member_scan` (legacy) is still wired and `SettleCasinoSheet`
   opens with `withdrawn: 0` because the attestation → withdrawn
   lookup isn't wired. The V0.29 per-member-scan flow needs the
   attestation display, withdraw-by-attestation lookup, and host
   finalise chain. **M3.**
4. **Pack-as-platform polish** — pack shelf tap is wired but the
   how-to body is V0.9. Pack install/uninstall notification
   surface (vision §3.3 closing) is not implemented. **M4.**

Plus one **M0 hygiene** pass (pbxproj drift, README path,
re-exports, empty " 2" dirs), one **M5 deferred** bucket
(Camera/Vision, LLM mascot, member-side event edit, how-to bodies,
awards card — all V0.9 per the brief), and one **M6 release-readiness**
bucket (CI lane, App Store metadata, legal/gambling posture note).

The milestones are **sequential on the critical path** (M0 → M1 → M2 →
M3 → M4 → M6) but **M3 + M4 can run in parallel after M2** if two
engineers are available. **M5 runs in parallel with everything else**
(V0.9 work, not a blocker).

---

## 2. Requirement → Status Map

The full requirement table. Every row cross-references vision.md
§3.1–§3.9, §4, the V0.8 brief, and the audit. Done / partial /
missing columns are pulled from the audit; concrete-change and
effort columns are the new contribution of this plan.

### 2.1 MVP-load-bearing features (vision §3.1)

| ID | Feature | Status | Where it lives today | Concrete change | Effort | Milestone |
|---|---|---|---|---|---|---|
| F-MVP-01 | Invite-only rooms + 6-char join codes | **done** | `RoomStore.swift:113-…` (generateJoinCode, redeemJoinCode), `JoinRoomSheet.swift`, RPCs `generate_join_code` (004), `redeem_join_code` (004 + V0.18) | None — already wired live + in-memory. | — | — |
| F-MVP-02 | Host + member roles | **done** | `RoomRole` enum, `Member.role`, role-gated UI in `RoomPage` / `RoomSettingsSheet` | None. | — | — |
| F-MVP-03 | Seasons with continuous-within / reset-at-end | **partial** | `Season` / `SeasonStatus` / `SeasonAward` models exist; migration 019 added `season_score`; `Declare` flow **not wired** in UI; awards surface **not implemented** (only `season_status == .ended` branch exists in `V0State`). | Add a "Declare season" CTA in the host room settings sheet (Operations sub-sheet); implement `.seasonClose` `V0State` case (per V0.8 brief §"State Machine"); add `season.close` RPC + migration. Awards card surface deferred to V0.9 per vision §3.1 open question #6. | M | M2 |
| F-MVP-04 | Seat deposits with refund / forfeit | **partial** | `seat_deposits` table referenced in audit §5.1 but **no model, no RPC, no UI** in the audited tree. The vision spec calls this load-bearing. | Verify whether the table actually exists in migrations 001–036 (grep `seat_deposits` under `Supabase/migrations/`); if missing, add migration. Add `SeatDeposit` model + `seat_deposits` RPCs (hold, refund, forfeit). Add attendance check at event creation (auto-refund if member RSVPs `declined`). UI: row in Witness Screen if a deposit is owed. | L | M2 |
| F-MVP-05 | iPad-first live scoring dashboard (host-only) | **partial** | `HostDashboard` referenced in vision but **not implemented** in tree. The audit lists `HostScoreEntrySheet` (single-winner round entry) but no general dashboard view. `iPad renders iPhone column centered with black margin` per audit §3 — explicitly **not** split-view. | Either (a) implement `HostDashboard` (per-event score entry surface with per-pack UI template, multi-round for non-casino packs), or (b) confirm with Nathan that `HostScoreEntrySheet` + `AddEventSheet` are the dashboard and ship the iPad-iPhone-column convention as the only v1 host UI. **This is an open question (§5 Q-F05).** | L | M2 |
| F-MVP-06 | 3–4 dev-created packs (Casino, CAH, Monopoly, Pluto Chess) | **done** | `Packs/CasinoPack.swift`, `CAHPack.swift`, `MonopolyDealPack.swift`, `PlutoChessPack.swift` (per audit §4; `Packs/` directory has 4 pack files). Migration 034 seeds the catalog. | None. | — | — |
| F-MVP-07 | In-app pack store shell | **partial** | `pack_store` route referenced in vision but **not implemented** as a separate view. The pack catalog is reachable via room settings (per Track E verdict, M2). | Confirm the V0.8 brief's intent: pack acquisition is **not** in V0.8 (all 4 packs ship pre-installed); pack store is V2 substrate (vision §3.2 two-level install model is also V2). Mark F-MVP-07 as **deferred to v2** in the plan; remove from MVP-cut list. | — | (V2) |
| F-MVP-08 | Native iOS from day 1 (iPhone + iPad, iOS 26+) | **done** | SwiftUI throughout; `Info.plist` MinOS 26.0; no third-party UI deps; Universal device target. | None. | — | — |
| F-MVP-09 | Internet required; offline cache deferred | **done** | Supabase backend; in-memory store is a preview-time stub only. | None. | — | — |
| F-MVP-10 | Spectator view (members see everyone's scores) | **done** | `get_room_leaderboard` RPC (022); `LeaderboardRow` + full board in `RoomDetailView`. | None. | — | — |
| F-MVP-11 | Score correction visibility ("host correcting" indicator) | **missing** | Not present in tree. Live Activities + Watch are explicitly V2 per V0.8 brief Q3 ("no surface in v0.8"). | Per vision §3.1 F-MVP-11, the indicator lives in "Live Activity + member row badge". Since Live Activity is V2, the member-row-badge half is in scope: add a `correcting` field on the `LeaderboardEntry` trajectory row, render a small amber dot for 60s after a score correction. RPC: extend `record_round_score` (035) to emit a `correction_of: uuid?` field. | M | M2 |
| F-MVP-12 | Glance / Live Activity / Watch for live-score | **deferred** | Per vision §4.2 N-16 and V0.8 brief Q3: "Watch is v2. No surface in v0.8." | Mark out-of-scope. Track in M5. | — | M5 |

### 2.2 Pack-as-platform architecture (vision §3.2)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| Pack schema: `{slug, display_name, scoring_type, win_points, withdraw_default, metadata, scoring_ui_schema, score_computation, how_to_content}` | **done** | Migration 012 + 034 + `PackDefinition.swift`. | — | — |
| Two-level install model: app-level / room-level | **partial** | `PackRegistry` (app-level) is in `Packs/`. The room-level install surface (which packs are enabled per room) is referenced in vision §3.2 but **no per-room pack table exists** in migrations 001–036. | Add migration `037_room_packs` (room_id, pack_slug, enabled). Add `Room.installedPackSlugs: [String]` to the `Room` model + decoder. Add a `packs` sub-section to the room settings sheet (Social / Operations / Packs) per V0.8 brief "section disposition". RPC `update_room_packs(p_room_id, p_slugs text[])`. | M | M4 |
| First concrete pack: Casino | **partial** | Casino pack + virtual-only withdrawal/return works (V0.29 reversal applied per audit §14). Camera/Vision path parked. | See F-V0.29 below (§2.3). | — | M3 |

### 2.3 Casino pack (vision §3.3)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| V0.29 per-member scan on the member's own phone | **partial** | `SettleCasinoSheet` exists (`Views/SettleCasinoSheet.swift`) but `RoomDetailView.openScan` opens it with `withdrawn: 0` because the attestation → withdrawal lookup isn't wired (audit §11). | In `RoomDetailView.openScan`: replace `withdrawn: 0` with a lookup against `CasinoService` (new RPC `get_my_open_withdrawal(p_event_id)` returning the latest `CasinoWithdrawal` for the calling user). Plumb through `SettleCasinoSheet` stepper default. | M | M3 |
| Host finalises → attest row visible to members | **partial** | `EventTransactionsView` is on the page per audit §11 (deprecated per V0.8 brief "Additional Drops"). | Remove `EventTransactionsView` from `RoomDetailView`; the attest row inside the Witness Screen's `.settleRound` slot is the canonical surface. Add per-member attest row UI inside the Witness Screen hero (per V0.8 brief "INTEGRATE" verdict on the attest banner). | M | M3 |
| 24h unscanned default to P&L = 0 with "did not scan" flag | **missing** | No cron / scheduled RPC exists for the 24h sweep. | Add Supabase scheduled function `cron_close_unscanned_attestations()` (pg_cron) running every 15 min: for any `casino_settlement_attestations` where `event.settled_at + interval '24 hours' < now() and attested_at is null`, mark them with `vision_amount_points = 0`, `claimed_amount_points = 0`, `disputed = true`, and `attested_at = now()`. Wire from migration 029 or add a new migration `038_unscanned_sweep.sql`. | S (RPC + cron) | M3 |
| Pack install/uninstall surfaces in room notification stream | **missing** | Vision §3.3 closing line + vision §6.2 Q18: "A pack uninstall must surface in the room's notification stream because the room's running state depends on it." | When `update_room_packs` (from §2.2) removes a pack that has an in-flight `casino_withdrawals` row, emit an in-app banner (not a push — push during play is banned per N-16) via `NotificationDispatcher.addSystemNotification(roomId, kind: .packRemoved, packSlug:)`. Persist in a `room_system_events` table; render in the Briefing slot's "system" section when the room has an active pack-related event. | M | M4 |

### 2.4 Mascot engine (vision §3.4)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| V0.6 core: 25-voice matrix (5 personalities × 5 ideologies) | **done** | `Services/MascotEngine.swift` (576 lines). Generates `OneLiner`. | None. | — |
| V0.26 extension: per-event broadcast, briefing narration, recap, dashboard prompt | **partial** | `MascotEngine` has `generateVoice(...kind: .postPlayRecap)` etc. (audit §11). The room-settings "Social" sub-sheet toggles exist (per vision §3.5) but the **per-event broadcast** (the V0.26 thing) is **not wired** to the host's pre-event note. | When the host adds a note (≤280 chars) in `RoomSettingsSheet.Social`, route it through `MascotEngine.generateVoice(...kind: .eventBroadcast, hostNote:)` so the T-48h notification body for claimed members reads `…is in two days. You're in. Host's note: {note}.` per vision §3.6. | S | M2 |
| V0.8 footer caption constraint (italic 13pt one-liner, never the lead) | **partial** | `MascotFooterCaption` exists in tree. Audit §11 flags: "MascotFooterCaption reads `MascotEngine.generateVoice(...kind: .postPlayRecap)` with `memberCount: 0, memberNames: []`. Pure template interpolation — fills placeholder rows with empty values." Plus the **a11y bug** in `Components/MascotFooterView.swift:52-53` (`onTapGesture` instead of `Button`). | (a) Replace `onTapGesture` with `Button(action: openMascotBubble)` for accessibility. (b) Pass actual member count + names from `RoomService.membersByRoom` to `MascotEngine`. (c) Wire `MascotFooterCaption` to all 8 current `V0State` cases — audit §11 confirms "today only fires inside the Tonight card." Goal: one footer per page, in all states. | S | M2 |

### 2.5 Navigation & information architecture (vision §3.5)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| Two tabs only: Rooms (default), Account / Room settings pair | **done** | `ContentView.swift` two-tab `TabView`. | None. | — |
| Last-viewed room opens Rooms tab automatically | **done** | `@AppStorage("lastViewedRoomIdString")` in `RoomPage`. | None. | — |
| No tabs inside a room (single scroll with 3 slots) | **done** | `RoomDetailView` is a `ScrollView` driven by `V0State`. | None. | — |
| Room settings sheet split into Social / Operations / Members sub-sheets | **missing** | `RoomSettingsSheet` (348 lines) is currently monolithic per audit §11. V0.8 brief "Section disposition" table mandates three sub-sheets. | Refactor `RoomSettingsSheet` to a `NavigationStack` root that pushes one of three sub-sheets based on a `RoomSettingsSection` enum. Move mascot + personality + ideology + narration toggles into `RoomSettingsSocialSheet`. Move max-seats, invite quota, join bonus into `RoomSettingsOperationsSheet`. Move roster + blacklist into `RoomSettingsMembersSheet`. Keep the gear icon as the entry point in `RoomDetailView` toolbar (host-only). | M | M2 |
| Packs are operational chrome (in room settings, NOT on-page) | **partial** | Track E verdict "DROP from page" applied in current build (per audit §11), but the `pack_store` and pack detail taps are still on the room page per the V0.8 brief "Additional Drops" list (`RoomDetailView.swift:935, :1515`). | Drop the `CasinoPanelView` trigger from the pack-row tap (Track E verdict re-applied). Pack rows become non-interactive (read-only display). Pack install/uninstall moves to `RoomSettingsOperationsSheet` (or a fourth "Packs" sub-sheet — open question). | S | M2 |

### 2.6 Notification trio (vision §3.6)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| 3×3 cadence × RSVP matrix (on-create / T-48h / morning-of × claimed / declined / unclaimed) | **done** | `Services/NotificationDispatcher.swift:51-109` (396-line file). Cadence bound to scoring events, not wall-clock, per V0.8 brief Q3. | None. | — |
| Body branches on recipient's response state (3 branches, not 2) | **done** | Declined branch is terminal (no further pushes). Claimed branch is logistics-only. Unclaimed branch is reminder. | None. | — |
| On-create push is the only "open and claim" prompt | **done** | Per audit §6 / V0.8 brief p.99. | None. | — |
| T-48h + morning-of are reminders for unclaimed (not fresh prompts) | **done** | Per dispatch logic. | None. | — |
| iOS notification permission prompt at room join (not install) | **missing** | Vision §6.1 Q3 lean: "prompt for permission at room join, not at install. The on-page briefing is the fallback." Currently no permission-prompt surface at all. | In `JoinRoomSheet.submit`: after `redeem_join_code` succeeds, show `UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])` *before* dismissing the sheet. If denied, log a `ponytail:` comment in the redemption flow noting "notifications denied at join; briefing slot is the fallback." | S | M2 |

### 2.7 Multi-room per user (vision §3.7)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| Rooms list = top-bar dropdown reachable from any room view | **missing** | Current rooms list is the `Rooms` tab itself, not a dropdown (audit §7.2). The dropdown affordance is implied by the vision. | Add a `RoomSwitcherMenu` toolbar item on `RoomDetailView` (visible to users with > 1 room). On tap, show a `Menu` listing rooms with `•` for active event + mascot name. Tap → switch `RoomService.currentRoomId` and re-fetch. Empty list (only the current room) → menu still renders but with just the current room, no-op on tap. | S | M1 |
| `+` inside the dropdown for create-room | **missing** | Current `+` is in `RoomPage` toolbar (per audit §7.2). | Move / mirror the `+` inside the dropdown menu (Section: "Create a new room" with `+` icon). Keep the existing `RoomPage` toolbar `+` to avoid breaking the empty-state "Create one to get started" CTA. | S | M1 |
| Default-on-relaunch = last-opened room | **done** | `@AppStorage("lastViewedRoomIdString")`. | None. | — |
| Account-level settings live in separate surface (not inside rooms dropdown) | **done** | `SettingsPage` wraps `AppSettingsView`. | None. | — |
| Session-active indicator (green dot / LIVE / row reorder) | **partial** | No session-active indicator in `RoomPage` rows. The active state is computed (`RoomService.activeEventByRoom[id] != nil`) but not surfaced. | Add a small `Circle().fill(Theme.Palette.accent)` next to the room name in `RoomPage` rows where `activeEventByRoom[id] != nil`. Tappable → jumps to room. | S | M1 |

### 2.8 Visual design grammar (vision §3.8)

| Requirement | Status | Concrete change | Effort | Milestone |
|---|---|---|---|---|
| iPhone-first; iPad renders iPhone column centered with black margin | **done** | `.contentColumn(maxWidth:)` helper in `Theme.swift`. Audit §7.4. | None. | — |
| Existing 80/20/10 palette stays; one accent at a time | **partial** | `Theme.Palette` has the 5 colors. But `.hero` SectionCard is not always driven by the state machine — audit §11 calls out the iPhone Tonight card bug: "hard-coded `.hero` regardless of state, `RoomDetailView.swift:663`." | In `RoomDetailView`, replace hard-coded `.hero` wash on the Tonight card with a state-driven resolver: only the active slot's hero carries `.hero`; all other sections are `.standard` or no wash. Verify by re-grepping `RoomDetailView.swift` for `.hero` and `.standard` after the change. | S | M2 |
| Visual placebo = design-bar-bumped (polish is the work) | **done (in progress)** | Per vision §3.8: "user has explicitly refused to ship functional-but-ugly." V0.8 brief §"What Comes Next" step 2 calls for the `ui-polish-engineering-loop` skill after structural ship. | After M1–M4 land, run the `ui-polish-engineering-loop` skill: falsifiable 4-pt grid, vertical rhythm, horizontal alignment, type scale, edge padding, divider count. Apply deltas. | M | M6 |
| `chair.fill` semantic for icons | **partial** | `SeatGridView` uses seat icons; pack shelf icons are SF Symbols. Audit confirms no centralized icon spec. | Add `Theme.Icon.chairFill` (or similar) and route pack shelf + seat-grid + add-event CTAs through it. Confirm SF Symbol names match the games-room aesthetic. | S | M2 |
| Pull-to-refresh > buttons (per wiki reflection 2026-07-17) | **done** | `RoomPage` has `.refreshable { await roomService.refresh() }` per audit §11. | None. | — |

### 2.9 Constraints (vision §4) — verification only

| Constraint | Status | Notes |
|---|---|---|
| §4.1 iOS 26+, SwiftUI, no third-party UI deps, Supabase backend | **done** | Audit §3 confirms. |
| §4.2 No ads, no Live Activities during play, no third nav page, mascot = footer, one CTA per state | **partial** | All four are honored structurally except Live Activities during play (correctly N-16 out of scope). The "one CTA per state" rule needs verification after the M2 refactor of `RoomSettingsSheet` — a multi-section sheet does not break the rule because each sheet is its own context. |
| §4.3 Audience: self-host model, masked-autistic / 2e host | **done (concept)** | The mascot engine + footer caption design honours this. |
| §4.4 No real-money exchange; no legal/gambling assessment in v1 | **partial** | Vision §6.2 Q13 defers legal review until launch-readiness. Add a `ponytail: legal-review-gating-launch.md` note in `docs/` flagging this. |
| §4.5 Tone TBD (NOT finance-noir); brand-lock position (Games Room ≠ Felt Faction) | **done** | Confirmed by audit + brand decision original. |
| §4.6 Ownership: Connor (eng lead), Nathan (supports), opencode (hands), Hermes (orchestrator) | **done (process)** | No code change. |

### 2.10 Non-goals (vision §5) — verify these stay out

The non-goals in vision §5 (N-01 through N-20) are explicit
constraints, not features. The plan must not regress them. All 20
are currently honoured by absence — none of the listed items exist
in the V0.8 tree. **Verification only.** No code change. If any
future PR introduces a non-goal (e.g. ads, freemium tiers, public
signup), the brief-anchored reviewer rejects it.

---

## 3. Milestones

The execution order. Each milestone is bounded, has a single
acceptance test, and lists the dependent and parallel work. The
critical path is M0 → M1 → M2 → M3 → M4 → M6; M5 is parallel
non-blocking; M3 + M4 can run concurrently if two engineers are
available.

### M0 — Hygiene (S, ½ day)

**Blocker for everything else.** Tidies drift so that downstream
PRs are clean.

1. **pbxproj drift check.** Run `python3 scripts/verify-xcode-project.py`.
   Confirm 64 PBXFileReference == 64 PBXSourcesBuildPhase == 64 .swift
   on disk. Audit confirms it passes; verify again before M1 work.
2. **Empty ` 2` directories.** `GamesRoom/{Auth 2, Models 2, Services 2,
   Views 2, Assets 2.xcassets}` are empty Finder duplicates from the
   V0.7→V0.8 file moves (audit §11). After manual confirmation each
   is empty, `rm -rf` from the repo root. Add a gitignore line
   `GamesRoom/* 2` and `GamesRoom/* 2.xcassets` to catch future
   Finder dupes.
3. **`tests/README.md` path drift.** Rewrite to point at `/main.swift`
   and `/build-and-run-tests.sh` at repo root, not the `tests/` dir
   (which is documentation-only — see audit §10).
4. **Comment drift on the XCTest target.** A historical
   comment referenced a non-existent XCTest target. Fixed in
   B1.4 — the 27 Foundation cases live at the repo-root
   `main.swift`.
5. **Untracked merge scripts.** Decide on `scripts/merge-v0-8-pbxproj.py`
   and `scripts/rewrite-pbxproj.py` — either commit them as
   historical artifacts with a README, or delete. Recommend delete
   (V0.8 is shipped; the scripts are no longer needed).
6. **`AppSettingsView.save()` error swallowing** (per review.json
   `info` suggestion). Replace `_ = error` with a `lastSaveError`
   `@State` + transient banner.
7. **Centralize `'lastViewedRoomIdString'`** as a constant in
   `Services/AuthService.swift` (or a new `StorageKeys.swift`).

**Acceptance.** `./build-and-run-tests.sh` → 21/21 still pass.
`scripts/verify-xcode-project.py` → exits 0. `git status` is clean.

### M1 — Slot-rotation fidelity (M, 1–2 days)

Closes the gap between the V0.8 brief's 10-state machine and the
implementation's 8-state machine. The brief lists:
`.loading, .upcoming, .claimed, .declined, .tonightEvent, .inPlay,
.settleRound, .justSettled, .readStandings, .seasonClose`. The
implementation (`RoomDetailView.swift:409-417`) has 8 cases:
`.justSettled, .inPlay, .settleRound, .upcoming, .claimed,
.declined, .readStandings` plus `.loading` (per audit §7.1).

The brief's `.tonightEvent` case (active event + playedAt ≤ now +
no withdrawals yet, with Withdraw as the CTA) was collapsed into
`.inPlay` per audit §7.1's closing note. **The collapse was a
deliberate implementation decision but loses two capabilities:**
(1) the brief specifies a distinct UI affordance for the
"play-just-started, no withdrawals yet" moment (mascot-narrated
started-time + seat grid + delayed chip tray all present);
(2) the V0.8 brief lists `.tonightEvent` as a separate state
specifically so the at-play slot can render the witness hero
even when withdrawals haven't started.

**Recommendation:** un-collapse — add `.tonightEvent(Event)` back
as a distinct case between `.declined` and `.inPlay`. Add
`.seasonClose` as the season-end slot (referenced by vision
§2.2 lifecycle phase 7 and F-MVP-03 above).

1. **Add `.tonightEvent(Event)` to `V0State`.**
   In `RoomDetailView.swift`, add the case after `.declined`.
   Trigger: `activeEvent.playedAt ≤ now && memberWithdrawalByEvent[event.id] == nil`.
   UI: Witness Screen hero with the started-time caption + seat
   grid + the "Withdraw chips" CTA (full-width, brass fill).
   Transitions to `.inPlay` the first time the user makes a
   withdrawal (set a flag on `casino_withdrawals` and join
   from `LiveRoomStore`).
2. **Add `.seasonClose` to `V0State`.**
   Trigger: `currentSeason.status == .ended`.
   UI: Awards card surface (Phoenix / Veteran / Whale /
   Drowning). Awards data lives in `season_awards` table (verify
   it exists in migrations 019 or 036; add migration 039 if not).
   Note: per vision §6.1 Q6, the **Drowning** award is private to
   the member — only they see it. The query that powers this
   slot needs a per-member filter; the host and other members see
   the Drowning row blanked or absent.
3. **Wire `.tonightEvent` and `.seasonClose` into the state
   resolver** in `RoomDetailView.state` (lines 194+).
4. **Update the `.hero` wash resolver** so `.tonightEvent` and
   `.seasonClose` carry `.hero` (the brief's "one accent at a time"
   rule).
5. **Update the `MascotFooterCaption` integration** to fire in the
   two new states.

**Parallel work (no dependencies on M1 critical path):**
- Multi-room dropdown (§2.7) — separate PR, can ship in any order
  relative to M1's state machine work.

**Acceptance.** All 10 `V0State` cases wired. `./build-and-run-tests.sh`
still passes. Manual: in `InMemoryRoomStore` seed (Carwoola Crew),
force `currentSeason.status = .ended` → awards card renders. Force
an event at `playedAt = now - 1 min` with no withdrawals →
`.tonightEvent` slot renders the Witness hero.

### M2 — Section discipline + Track E verdicts (L, 2–3 days)

The longest milestone. Closes the Track E integration-critique
verdicts and the V0.8 brief's "Sections — Track E Verdicts Applied"
+ "Sections — Additional Drops" + "Sections to Keep" lists.

1. **Drop `CasinoPanelView` trigger from pack-row tap** (Track E
   verdict "DROP the pack-row trigger"). Pack rows on `PackShelfReadOnly`
   become non-interactive (or show a brief tap-then-no-op animation
   acknowledging the row, per a11y). Add a `ponytail:` comment noting
   the pack detail view is V0.9.
2. **Remove `EventTransactionsView` from `RoomDetailView`** ("Additional
   Drops" line 2). Move per-event live transactions to a "Live
   board" sub-surface inside `RoomSettingsOperationsSheet` (host-only).
3. **Move inline attest banner into Witness Screen hero.** Currently
   the "Your P&L: +$X" row is a separate section at `RoomDetailView.swift:404-439`;
   per V0.8 brief "INTEGRATE" verdict, it becomes part of the
   `.settleRound` slot hero.
4. **Refactor `RoomSettingsSheet` into three sub-sheets**
   (Social / Operations / Members). 348-line file → `NavigationStack`
   with three sub-views. Preserve the entry-point gear icon in
   `RoomDetailView` toolbar (host-only).
5. **Fix `MascotFooterView` a11y regression.** Replace `onTapGesture`
   with `Button(action: openMascotBubble)` at `Components/MascotFooterView.swift:52-53`.
   Promote the footer caption to a page-level surface (one per
   page, all states — not just inside the Tonight card).
6. **State-driven `.hero` wash.** Remove the hard-coded `.hero` on
   the Tonight card (`RoomDetailView.swift:663`). Drive `.hero` /
   `.standard` from the state machine — only the active slot's hero
   gets `.hero`, everything else is `.standard` or no wash.
7. **`chair.fill` icon semantic.** Add `Theme.Icon` constants;
   route pack shelf + seat-grid + add-event CTAs through them.
8. **Notification permission prompt at room join.** In
   `JoinRoomSheet.submit`, after `redeem_join_code` succeeds,
   call `UNUserNotificationCenter.current().requestAuthorization(...)`.
9. **F-MVP-04 seat deposits** (if confirmed in migrations). If
   `seat_deposits` exists, add the `SeatDeposit` model + RPCs + UI
   row in the Witness Screen.
10. **F-MVP-05 host dashboard** (open question). See §5 Q-F05.
11. **F-MVP-11 score correction badge.** Extend `record_round_score`
    (migration 035) with a `correction_of` field; render a 60s amber
    dot on the corrected member's `LeaderboardEntry` row.
12. **MascotEngine host-note broadcast.** Route the host's ≤280-char
    pre-event note through `MascotEngine.generateVoice(...kind: .eventBroadcast)`
    so the T-48h notification body reads correctly.

**Parallel work:**
- `games-room-tests` extension: add Foundation cases for any new
  model fields (F-MVP-04, F-MVP-11). These compile alongside the
  current 21.

**Acceptance.** All Track E verdicts applied. `RoomSettingsSheet`
split into three sub-sheets, accessible from the same gear icon.
Mascot footer caption present in all 10 `V0State` cases. `.hero`
wash driven by state, not hard-coded. `./build-and-run-tests.sh`
21+ passing. `xcodebuild build` (iPhone simulator) green.

### M3 — Casino V0.29 settlement surface (M, 1–2 days)

Closes the V0.29 per-member-scan reversal properly. Audit §11
confirms the legacy `record_member_scan` is still on the path and
the `withdrawn: 0` fallback in `SettleCasinoSheet` is the
intended V0.8 placeholder. **M3 is the work to replace that
placeholder.**

1. **Per-member attestation lookup RPC.** Add migration 037 (or
   extend 029) with `get_my_open_withdrawal(p_event_id uuid) returns
   casino_withdrawals`. Returns the latest open withdrawal for the
   calling user on the given event, or `null`.
2. **Wire `CasinoService.loadMyWithdrawal(eventId:)`** calling the
   new RPC.
3. **`RoomDetailView.openScan` lookup.** Replace `withdrawn: 0`
   with `CasinoService.loadMyWithdrawal(eventId:)`; pass the value
   to `SettleCasinoSheet` as the stepper default.
4. **Per-member attest row in Witness Screen hero.** Add the
   inline attest row UI inside the `.settleRound` slot (per V0.8
   brief INTEGRATE verdict). Data source: existing
   `get_event_transactions` (migration 024).
5. **24h unscanned sweep cron.** Add Supabase scheduled function
   `cron_close_unscanned_attestations()` running every 15 min.
   Migration `038_unscanned_sweep.sql` defines the function + the
   pg_cron schedule. Marks attestations as
   `vision_amount_points = 0, disputed = true` after 24h.
6. **Update V0.29 tests in `main.swift`** (Foundation-only) — add
   a `CasinoWithdrawal` round-trip case if not already present
   (audit §10 lists the current 21 cases; verify whether
   `CasinoWithdrawal` is covered).

**Parallel work:** M4 (M4 does not depend on M3; both depend on M2).

**Acceptance.** `SettleCasinoSheet` opens with the actual
withdrawal amount (not `0`). Witness Screen `.settleRound` slot
shows the per-member attest row. 24h cron sweeps in pg_cron
(verify by querying `cron.job` after deployment). `./build-and-run-tests.sh`
still passes.

### M4 — Pack-as-platform polish (M, 1–2 days)

Closes vision §3.2 two-level install and vision §3.3 closing
line (pack install/uninstall notifications).

1. **`room_packs` table** (migration 037 or 039). `(room_id, pack_slug,
   enabled, installed_at)`. The room never reaches up to the
   global catalog — only enabled rows are visible.
2. **`update_room_packs` RPC.** Accepts `p_room_id, p_slugs text[]`.
   Validates the slugs are in `packs`. Throws on invalid input.
3. **`Room.installedPackSlugs: [String]`** field on the model +
   decoder.
4. **`LiveRoomStore.fetchRoomPacks(roomId:)` + `updateRoomPacks(roomId:slugs:)`**
   wrappers, with `InMemoryRoomStore` defaults (all 4 packs enabled).
5. **Room settings sheet "Packs" sub-section** (or fourth sub-sheet
   — open question). Renders current install state, toggles per pack,
   "Save" commits via `updateRoomPacks`.
6. **Pack install/uninstall in-app banner** (vision §3.3 closing).
   When `update_room_packs` removes a pack that has in-flight
   `casino_withdrawals` rows, write a row to `room_system_events`
   (new table in the same migration) with `kind = 'pack_removed'`,
   `payload = { pack_slug, event_id }`. Surface in the Briefing
   slot's "System" section when the room has any unread
   `room_system_events`.
7. **Pack shelf tap surface.** Per audit §11, the shelf tap target
   is wired but the how-to body is V0.9. Confirm the tap is a
   no-op or a brief "Details coming soon" toast. Document the
   decision in a `ponytail:` comment.

**Parallel work:** none (M4 is the final structural milestone).

**Acceptance.** Host can enable/disable packs per room via the
settings sheet. Removing a pack with in-flight casino withdrawals
shows the system banner. `./build-and-run-tests.sh` still passes.

### M5 — V0.9 parallel work (L+, indefinite)

Out of the V0.8 critical path. Run in parallel with M1–M4 if a
second engineer is available; defer otherwise.

1. **Camera/Vision chip-scan pipeline** (vision §3.1, F-MVP-09
   note; §6.2 Q15 vision feasibility probe). Core ML on-device.
   The 10-photo Vision probe is the single highest-leverage
   blocking action per vision §6.2 Q15.
2. **LLM-driven mascot voice** (vision §3.4 V0.26 LLM extension).
   Apple Foundation Models framework. 75-cell mascot matrix
   (5 personalities × 5 ideologies × 3 RSVP states) per vision
   §6.1 Q7.
3. **Member-side event edit surface** (vision §6.1 Q9). Decline
   becomes re-enterable.
4. **Pack how-to guide bodies** (vision §3.1 F-MVP-07 deferred).
5. **Season-end awards Drowning privacy rewrite** (vision §6.1 Q6).
   The privacy boundary in the schema first, awards card second.
6. **Chapter-line cadence + season subtitle mascot judgment**
   (vision §6.1 Q1 + Q5). Host-approval beat for the season subtitle.
7. **"Joined late" catch-up push** (vision §6.1 Q8). For members
   who join after `event.createdAt`.
8. **On-create notification timing refinement** (vision §6.1 Q8).
9. **iPad split-view** (deferred per `BRIEF.md` Q2; revisit at v2).

### M6 — Release-readiness (M, 2–3 days)

After M1–M4 land. Picks up the polish + release mechanics.

1. **`ui-polish-engineering-loop` skill pass.** Falsifiable
   4-pt grid, vertical rhythm, horizontal alignment, type scale,
   edge padding, divider count. Apply deltas.
2. **CI lane.** GitHub Actions: `swift build` + `swift test`
   (Foundation-only) + `scripts/verify-xcode-project.py`. No
   `xcodebuild` lane yet (Mac runner required).
3. **App Store metadata.** Description, screenshots (iPhone 17 Pro
   + iPad), privacy nutrition labels (Apple Sign-In only — minimal
   data collected). Privacy policy URL.
4. **Legal/gambling posture note.** Per vision §4.4 + §6.2 Q13.
   Document the "virtual currency with no real-world exchange"
   posture in `docs/legal-posture.md` for Connor's review. Defer
   formal legal review to post-launch.
5. **TestFlight build.** `xcodebuild -scheme GamesRoom -configuration
   Release` + archive + upload. Recruit 2–3 hosts-of-record for
   beta.
6. **Migration 039 / 040 housekeeping.** Roll any M1–M4 ad-hoc
   migrations into a single ordered set so a fresh DB bootstrap
   works end-to-end.

**Acceptance.** TestFlight build uploaded; CI green; `docs/legal-posture.md`
exists; `ui-polish-engineering-loop` checklist closed.

---

## 4. Parallelisation Map

Two-engineer team. Without dependencies:

```
Week 1  ──────────────────────────────────────────────────────────
  Eng A: M0 (½ day) → M1 (1–2 days) → M2 starts
  Eng B: starts M2 with Eng A on day 3; or starts M5 (Camera/Vision)

Week 2  ──────────────────────────────────────────────────────────
  Eng A: M2 finishes → M3
  Eng B: M4 (independent of M3) → M2 verification review

Week 3  ──────────────────────────────────────────────────────────
  Eng A: M6 polish loop
  Eng B: M6 CI + TestFlight + legal-posture.md

Week 4+ ─────────────────────────────────────────────────────────
  Both: M5 (V0.9 work) in parallel
```

Single-engineer team: M0 → M1 → M2 → M3 → M4 → M6 (sequential;
~3–4 weeks full-time). M5 deferred until after M6 ships.

---

## 5. Open Questions for Nathan

These are the decisions this plan **cannot make on its own.** They
need human judgement. Each is tagged with the requirement it
gates and the milestone it affects.

### Q-F05 — Host dashboard surface

**Gates.** F-MVP-05 (vision §3.1); M2 step 10.
**The question.** The vision calls for an iPad-first live scoring
dashboard. The current tree has `HostScoreEntrySheet` (single-winner
round entry, opened per-pack). Is that the dashboard, or should
we build a dedicated `HostDashboard` view that hosts the scoring
surface per active event?
**Lean.** Per the V0.8 brief and the iPad-iPhone-column convention,
`HostScoreEntrySheet` + `AddEventSheet` are likely the v1 host UI;
a separate `HostDashboard` is V2.
**Decision needed by.** Before M2 step 10 starts.

### Q-F03 — Seat deposits scope

**Gates.** F-MVP-04 (vision §3.1); M2 step 9.
**The question.** Audit §5.1 lists `seat_deposits` in the
migrations summary, but no model / RPC / UI exists in the tree.
Is seat-deposit actually live, or is the audit referencing a
schema sketch that never landed? If it's live, do we ship the
full refund/forfeit flow in V0.8 or defer to V0.9?
**Lean.** Defer to V0.9 if the table is real but no model exists
(suggests it was sketched but never wired); ship if the table is
real AND the model already exists under a different name.
**Decision needed by.** Before M2 step 9 starts.

### Q-PACK — Pack settings: third or fourth sub-sheet

**Gates.** Vision §3.5; M2 step 4 + M4 step 5.
**The question.** V0.8 brief "section disposition" lists three
sub-sheets (Social / Operations / Members). M4 needs a "Packs"
sub-section. Should that be a fourth sub-sheet, or fold into
Operations?
**Lean.** Fourth sub-sheet (Packs is a discrete operational
concern; folding it into Operations clutters the latter).
**Decision needed by.** Before M2 step 4 starts (because the
refactor of `RoomSettingsSheet` is the right time to add the
fourth sub-sheet, even if its UI is empty until M4).

### Q-F07 — Pack store

**Gates.** F-MVP-07 (vision §3.1); no milestone (recommend mark
deferred to V2).
**The question.** Vision §3.1 lists F-MVP-07 as MVP-load-bearing,
but vision §3.2 ("Pack-as-platform") and the V0.8 brief both
defer the two-level install model to V2. Is there a v1 pack
acquisition surface, or are all 4 packs pre-installed?
**Lean.** All 4 packs pre-installed in V0.8; pack store is V2.
Mark F-MVP-07 as deferred in the vision doc.
**Decision needed by.** Before any pack-acquisition code is
written (no risk to V0.8 if deferred).

### Q-NOTIFY-BODIES — LLM-driven vs templated

**Gates.** Vision §3.6; §6.1 Q7; M2 step 12.
**The question.** V0.8 ships templated mascot voice
(`{mascot}, {event}, {date}, {time}, {venue}, {seats_left},
{seats_claimed}` interpolation). V0.9 introduces per-state LLM
generation (75 cells per personality × ideology). Confirm
templated is the V0.8 surface.
**Lean.** Templated for V0.8 (vision §6.1 Q7 explicit).
**Decision needed by.** Before M2 step 12 starts (so the
templated implementation matches the V0.8 intent).

### Q-DROWNING — Awards privacy boundary

**Gates.** Vision §6.1 Q6; M1 step 2.
**The question.** The Drowning award is private to the member.
The schema needs to gate this at query time. Build the privacy
boundary into the M1 schema (even though the awards card UI ships
in V0.9), or wait?
**Lean.** Build the schema boundary in M1 (so V0.9 work doesn't
have to migrate); ship the awards card UI in V0.9.
**Decision needed by.** Before M1 step 2 starts.

### Q-LEGAL — Virtual currency posture

**Gates.** Vision §4.4 + §6.2 Q13; M6 step 4.
**The question.** "Virtual currency with no real-world exchange"
is the assumed posture. Connor verbatim: "we haven't done any
legal assessment." Does M6 ship a `docs/legal-posture.md` note
for self-review, or hold the release until formal review?
**Lean.** Self-review note in M6; formal review post-launch
(per vision §6.2 Q13 explicit deferral).
**Decision needed by.** Before TestFlight upload (M6 step 5).

### Q-LEGACY-SCAN — Keep `record_member_scan` callable?

**Gates.** Audit §11; M3 step 1.
**The question.** The legacy `record_member_scan` (pre-V0.29
host-scan RPC) is still wired. Keep it callable for backward
compat, or delete once V0.29 settles land?
**Lean.** Keep callable until at least one V0.9 release ships
with the new attestation surface stable; remove after V0.9.1.
**Decision needed by.** Before M3 step 1 starts (so the
RPC migration doesn't accidentally remove it).

### Q-SCHEMA-CLEANUP — Migration re-numbering

**Gates.** M6 step 6.
**The question.** M1–M4 add migrations 037–040 (ad-hoc). Should
they land incrementally as written, or should we re-number to
fill gaps (some early migrations are 017-onwards)?
**Lean.** Land as 037–040; do a single re-numbering pass in M6
if the gaps bother the team.
**Decision needed by.** Before M6 starts.

---

## 6. Risks & Acceptance Criteria

### 6.1 Cross-cutting risks

- **R1: Mascot voice fragility** (V0.8 brief R1). The footer
  caption form is lower-risk than a hero card. **Stay in footer.**
  Any PR that proposes a hero-card mascot treatment needs to
  override the M2 decision explicitly.
- **R2: Pre-game phone presence** (V0.8 brief R2). The only lever
  is "nothing compelling is on the phone during play." **Aggressive
  push-budget discipline.** Push budget refresh: 1 min (vision
  §3.1 F-MVP-12 note).
- **R6: Monetisation constrained** (V0.8 brief R6). 4 dev-curated
  packs, at least 2 must ship in V1. **All 4 ship in V0.8.** ✅
- **R7: User is a real-time prior corrector at the shape level**
  (vision §6.3 R7). The plan ships a structural V0.8; the user
  will re-anchor with "apply common sense" prompts. **Build the
  loop, not the assumption.** Use the `plan` skill for any new
  slices added mid-stream.
- **R8: Data-layer drift hides UI features** (vision §6.3 R8).
  **Always query the DB before debugging the UI.** This is a
  process rule for M3 (V0.29 settlement) and M4 (pack install
  banner) specifically.

### 6.2 Acceptance for the plan itself

A reviewer should be able to:

- Pick any vision requirement (§3.1–§3.9, §4) and find its row in
  §2 with status, concrete change, effort, and milestone.
- Pick any milestone (§3) and see all the requirements it
  implements plus all the open questions it depends on.
- Pick any open question (§5) and see the requirement + milestone
  it gates plus a recommended lean.
- Hand M0 + M1 to a junior engineer and not need to re-derive any
  design.

If any of those fail, the plan needs another pass.

### 6.3 Acceptance for V0.8 ship

- All 21+ Foundation tests pass.
- `scripts/verify-xcode-project.py` exits 0.
- `xcodebuild` builds green on iPhone + iPad simulators.
- All 10 `V0State` cases wired.
- Track E verdicts fully applied (pack-row CTAs dropped,
  EventTransactionsView moved, attest banner integrated, room
  settings split).
- V0.29 settlement surface complete (per-member attest row +
  withdrawal lookup + 24h sweep).
- Pack two-level install wired with system-event banner.
- TestFlight build uploaded; at least 2 hosts-of-record in beta.

---

*Plan written 2026-08-05 from `docs/vision.md` (the shape) and
`docs/audit.md` (the as-built surface). When this plan disagrees
with the source pages, the source pages win — same rule the
vision doc follows.*