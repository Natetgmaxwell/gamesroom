# Games Room — Implementation Plan (V0.9 → first release)

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

> **Status (2026-08-11, updated by integration task t_a4d83930):** T0.3 (CI lane), T0.4 (repo hygiene), T1.1 (EventKit), T1.2 (photo persistence), T1.3 (icon wiring — v3 GR monogram "The Ring" per the plan default), T1.4 (ui-polish audit) are DONE and committed. The PLAN.md W-04..W-06 gap-closers (room deletion, season history, casino color-map editor) are DONE and committed; W-07/W-08 housekeeping landed with the integration task. Remaining: T0.1/T0.2 (Xcode-host gates — no Xcode.app on this host), Wave 2 (gated on Q-TONE / Q-LLM-PROVIDER / Q-PAID-PACKS / Q-HOST-FEEDBACK). Verification after this run: 73/73 Foundation tests, 36/36 parse-checks, pbxproj green. **The requirement-coverage map for the current tree is `PLAN.md` §2; this document is the V0.9-era plan.**

**Goal:** Close the remaining gaps between the codebase at `main` (`157ab69`) and the vision in `VISION.md`, then ship the first TestFlight build.

**Current state (verified 2026-08-11):** V0.8 plus every V0.9 roadmap slice (W1.1–W1.6, W2.1–W2.8, W3.2, W3.3) is code-complete. 62/62 Foundation tests pass, 33/33 parse-checks pass, pbxproj validator green. The remaining work is: the first real Xcode build + TestFlight upload, three vision-fidelity gaps (EventKit calendar auto-add, photo-persistence option, app-icon wiring), a CI lane, the ui-polish pass, and four gated decisions that must not be silently resolved.

**Architecture:** Native iOS 26+ SwiftUI app, Supabase backend (Postgres + RPCs), on-device Core ML vision for the Casino pack. No third-party UI deps. Services are `@MainActor @ObservableObject`; views talk to services, services talk to the `RoomStore` protocol (live + in-memory impls).

**Tech stack:** Swift 6 / SwiftUI, supabase-swift 2.54.1, WidgetKit + ActivityKit, Core ML, EventKit (to add), StoreKit (v1-ready shell only).

**Build-level spec:** `docs/vision.md` (37 KB) is the source of truth for build detail; `VISION.md` is the consolidated shape this plan is checked against. When they disagree, the source wins.

---

## 1. Gap analysis — VISION.md vs codebase

| VISION.md § | Requirement | Status (verified 2026-08-11) | Action |
|---|---|---|---|
| §5.1 | Paid packs v1-ready | PackStoreView shell lists 4 packs with installed state; StoreKit deferred | No MVP action. T2.2 when packs go paid |
| §5.2 | Photo default = discard, keep hash + snapshot | Default implemented (F-CAS-03, `ChipScanSheet`); no opt-in to keep the photo | T1.2 |
| §5.2 | Cloud-vision hybrid | On-device locked (recall 0.975, precision 1.000); hybrid is v2-only | T2.3 monitor, no code |
| §5.3 | Mascot via Apple Foundation Models (iOS 26+ native LLM) | LLM voice runs via z.ai glm-4.6 over URLSession; no `FoundationModels` import anywhere | Provider mismatch → T2.1 (gated on Q-TONE) |
| §5.3 | 75-cell matrix: broadcast, briefing, recap, season-end | 25-voice matrix + LLM broadcast/recap done (W2.6); full matrix + season-end gated | T2.1 |
| §6 | App icon: "The Table" locked, "Join Code" A/B | `.designs/app-icons-v3/` holds the delivered GR-monogram v3 set; `AppIcon.appiconset` has a single 1024 png | T1.3 + Q-ICON |
| §8 | EventKit calendar auto-add (per-room host toggle, default off) | Toggle exists in `Room` + settings sheet; zero EventKit code in the tree | T1.1 |
| §8 | WidgetKit + Live Activity score surface, no LA during play | W2.3 code-complete (Glance + LA + Watch targets, App Group channel); device pass pending | T0.1 |
| §9 | Wave 0 TestFlight upload | Env-blocked: no Xcode.app on this host | T0.1 → T0.2 |
| §9 | M6 ui-polish pass (design bar) | Pending | T1.4 |
| §9 / plan M6 | CI lane | No `.github/workflows/` in the repo; W3.2 hardened local scripts only | T0.3 |
| — | Repo hygiene | `VISION.md` + `.designs/` untracked | T0.4 |

**Resolved since VISION.md §9 was written** (no action): host dashboard V2-full (W1.6), inline `+` create-room (W2.2), pack how-to bodies (W2.2), LLM mascot half (W2.6), awards card + Drowning privacy (W1.5/W1.1), decline re-entry (migration 046), member-side event edit (W2.4), joined-late catch-up push (W2.7), iPad split-view (W2.8), Live Activity (W2.3).

---

## 2. Workstreams and dependencies

```
Wave 0 — Release gate (needs Mac + Xcode 27)
  T0.1 first Xcode build + device pass ──► T0.2 TestFlight upload
  T0.3 CI lane (parallel)          T0.4 repo hygiene (parallel)

Wave 1 — Vision-fidelity gaps (runnable on this host)
  T1.1 EventKit calendar auto-add   (parallel)
  T1.2 photo-persistence option    (parallel)
  T1.3 app-icon wiring             (after Q-ICON)
  T1.4 ui-polish pass              (parallel)

Wave 2 — Gated / decision items (do NOT silently resolve)
  T2.1 mascot matrix Wave 5        (after Q-TONE + Q-LLM-PROVIDER)
  T2.2 paid packs / StoreKit       (after Q-PAID-PACKS)
  T2.3 cloud-vision hybrid         (monitor only, after T0.2)
```

---

## 3. Tasks

### T0.1 — First full Xcode build + device pass

**Objective:** Prove the app builds and the widget / Live Activity / Watch / camera surfaces render on a Mac with Xcode 27.

**Files:** none (verification only; fixes land as findings).

**Steps:**
1. `xcodebuild -project GamesRoom.xcodeproj -scheme GamesRoom -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build`
2. Build for a physical device (camera + Live Activity need one).
3. Manual pass: chip-scan camera flow, widget glance (1-min refresh), Live Activity suppressed during play, Watch app snapshot.
4. Fix any build or render defects found; each fix lands with its own test where the defect is testable.

**Acceptance criteria:**
- Simulator + device builds succeed.
- All four manual surfaces verified on device.
- Any fixes pass `./build-and-run-tests.sh` (62/62) + `python3 scripts/verify-xcode-project.py`.

**Depends on:** nothing. **Blocks:** T0.2.

---

### T0.2 — TestFlight upload

**Objective:** Ship build 0.1.0 (1) to TestFlight with release notes and beta testers.

**Files:** `docs/testflight-release-notes.md` (exists — paste into "What to Test").

**Steps:**
1. Archive + upload from Xcode Organizer (or `altool`/Transporter).
2. Paste the release notes into the TestFlight "What to Test" field.
3. Invite the Q-HOST-FEEDBACK beta accounts.

**Acceptance criteria:**
- Build visible in TestFlight with notes set.
- Beta testers invited and can install.

**Depends on:** T0.1, Q-HOST-FEEDBACK.

---

### T0.3 — CI lane

**Objective:** Every push runs the three verification gates on a macOS runner.

**Files:**
- Create: `.github/workflows/ci.yml`

**Steps:**
1. Workflow triggers on `push` + `pull_request` to `main`.
2. Runner: `macos-latest`; steps: checkout, `./build-and-run-tests.sh`, `python3 scripts/verify-xcode-project.py`, `bash scripts/parse-check-swiftui.sh`.
3. Commit the workflow.

**Acceptance criteria:**
- Workflow file committed and syntactically valid.
- First run on the next push is green (cannot be executed from this host — the file is the deliverable).

**Depends on:** nothing.

---

### T0.4 — Repo hygiene

**Objective:** Decide the fate of the untracked `VISION.md` + `.designs/`.

**Files:** `VISION.md`, `.designs/`.

**Steps:**
1. Confirm `.designs/` contains no secrets (icon PNGs/SVGs + READMEs only).
2. Commit `VISION.md` and `.designs/` — or add `.designs/` to `.gitignore` if it is scratch.

**Acceptance criteria:** working tree clean; `VISION.md` tracked.

**Depends on:** nothing.

---

### T1.1 — EventKit calendar auto-add

**Objective:** Honor the existing `calendarAutoAddHost` toggle with real EventKit writes.

**Files:**
- Create: `GamesRoom/Services/CalendarService.swift`
- Modify: `GamesRoom/Views/RoomSettingsSheet.swift` (wire toggle → service)
- Modify: `GamesRoom/Info.plist` (`NSCalendarsUsageDescription`)
- Modify: `GamesRoom.xcodeproj/project.pbxproj` (new file reference — run `verify-xcode-project.py` after)

**Steps:**
1. `CalendarService`: `EKEventStore` wrapper — `requestAccess()`, `addEvent(room:event:)`, `removeEvent(room:event:)`.
2. When the host enables the toggle, request calendar access; persist the toggle via the existing `update_room` RPC (default off preserved).
3. On event create/update, write an `EKEvent` (title, start/end, venue in notes). On event settle/delete, remove it.
4. Failure is non-fatal: calendar write errors surface as a transient banner, never block the event flow.

**Acceptance criteria:**
- Toggle persists; enabling prompts consent; created events land in the host's calendar.
- Parse-check + pbxproj verify green; device pass on Xcode host.

**Depends on:** nothing.

---

### T1.2 — Photo-persistence option

**Objective:** Add the opt-in "keep scan photo" setting; the discard-by-default behavior stays identical.

**Files:**
- Modify: `GamesRoom/Views/ChipScanSheet.swift`
- Modify: `GamesRoom/Services/StorageKeys.swift`
- Modify: `GamesRoom/Views/AppSettingsView.swift` (or room settings — pick the surface that matches the existing settings split)
- Modify: `main.swift` (Foundation test)

**Steps:**
1. Add `StorageKeys.keepScanPhotos` (default `false`).
2. `ChipScanSheet`: when `true`, save the JPEG to the app sandbox (`Documents/ScanPhotos/<eventId>-<memberId>-<timestamp>.jpg`) instead of discarding. The hash is always recorded either way.
3. Foundation test: key default is `false`; round-trip persists.

**Acceptance criteria:**
- Default path unchanged: hash + vision snapshot only, photo discarded.
- Opt-in stores the photo locally; it is never uploaded.
- 62/62 tests + 33/33 parse-checks green.

**Depends on:** nothing.

---

### T1.3 — App-icon wiring

**Objective:** Ship the final icon set in the asset catalog.

**Files:**
- Source: `.designs/app-icons-v3/` (SVG masters + PNGs)
- Modify: `GamesRoom/Assets.xcassets/AppIcon.appiconset/`

**Steps:**
1. Resolve Q-ICON (which concept is final — vision "The Table" vs delivered v3 GR monogram).
2. Generate the full size set (1024/180/120/167/152/76/60/40/29) from the SVG master.
3. Replace the appiconset contents; `plutil -lint Contents.json`; `verify-xcode-project.py`.

**Acceptance criteria:**
- Appiconset has the complete size set; lint passes.
- Icon renders on device (Xcode host).

**Depends on:** Q-ICON.

---

### T1.4 — ui-polish pass

**Objective:** Run the design-bar loop (VISION.md §5.4 — "we are not aiming to be mediocre").

**Files:** `GamesRoom/Views/**` (findings only).

**Steps:**
1. Load the `ui-polish-engineering-loop` skill.
2. Audit the 8 `V0State` surfaces against the design bar (one CTA per state, mascot footer caption, 80/20/10 palette, `chair.fill` semantics).
3. Fix findings; re-run the full verification suite.

**Acceptance criteria:**
- Findings list + fixes landed.
- 62/62 tests + 33/33 parse-checks still green.

**Depends on:** nothing.

---

### T2.1 — Mascot matrix Wave 5 (gated)

**Objective:** When Q-TONE lands, extend the mascot to the full matrix and settle the LLM provider.

**Files:**
- Modify: `GamesRoom/Services/MascotEngine.swift`
- Modify: `GamesRoom/Models/MascotPersonality.swift`, `GamesRoom/Models/MascotPoliticalIdeology.swift`

**Steps:**
1. Nathan answers Q-TONE (default if "go": ship the existing template voice).
2. Decide Q-LLM-PROVIDER: Apple Foundation Models (per VISION.md §5.3) vs the current z.ai endpoint.
3. Implement season-end voice + any missing matrix cells; voice stays the footer caption, never the lead.

**Acceptance criteria:**
- Matrix complete; footer-caption constraint holds; tests green.

**Depends on:** Q-TONE, Q-LLM-PROVIDER.

---

### T2.2 — Paid packs / StoreKit (gated)

**Objective:** When packs go paid, wire StoreKit purchase into the pack store.

**Files:**
- Modify: `GamesRoom/Views/PackStoreView.swift`
- Create: `GamesRoom/Services/StoreService.swift`

**Steps:**
1. Add product ids to the pack catalog.
2. `StoreService`: `Product`/`Transaction` purchase + restore.
3. Purchase state gates pack install; free packs unaffected.

**Acceptance criteria:** purchase flow works on device; free packs unchanged.

**Depends on:** Q-PAID-PACKS.

---

### T2.3 — Cloud-vision hybrid (monitor only)

**Objective:** No code. Re-evaluate only if on-device confidence falls short in beta.

**Acceptance criteria:** n/a — revisit after T0.2 TestFlight feedback.

**Depends on:** T0.2.

---

## 4. Open questions — do NOT silently resolve

| ID | Question | Default |
|---|---|---|
| Q-TONE | Brand voice decision (gates T2.1) | If "go": ship existing template voice |
| Q-ICON | Final icon concept: vision "The Table" vs delivered v3 GR monogram | Latest approved v3 set |
| Q-LLM-PROVIDER | Apple Foundation Models vs z.ai for mascot LLM (part of T2.1) | Keep z.ai until Q-TONE lands |
| Q-HOST-FEEDBACK | How many host beta accounts for first TestFlight cycle (gates T0.2 invite list) | 2–3, recruited by Nathan |
| Q-MONOPOLY-MULTIWINNER | Multi-winner / split-the-pot for Monopoly Deal | Defer to V0.9.1 |
| Q-V0.9-PUBLICITY | TestFlight changelog post or silent iteration | Silent unless Q-TONE triggers a co-brand question |

---

## 5. Verification baseline

Every task that touches code must leave these green:

```
./build-and-run-tests.sh          → 62 passed, 0 failed
bash scripts/parse-check-swiftui.sh → 33/33 pass
python3 scripts/verify-xcode-project.py → exit 0
plutil -lint <any touched plist>   → OK
```

Xcode-host gates (T0.1, T0.2, device renders) are documented as manual — this host has no Xcode.app.
