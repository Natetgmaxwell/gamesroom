# Games Room — Vision Spec

> Synthesised from the gbrain knowledge base. Every requirement below is
> traceable to a source page (canonical slug in `[Source: …]`). Open
> questions are flagged inline for the planner.
>
> **Status:** vision-level. Not a build spec, not a roadmap. The job of
> this document is to name the *shape* of the product so downstream
> planning can derive slices, milestones, and acceptance tests without
> re-deriving the product from transcripts.

---

## 1. North Star

> *"Social north star, operations engine — connection/attendance defines
> success; the ledger and rituals make it reliable. The night operations
> work in service of the social interaction and arcing storylines through
> a persistent ledger. Like an arc in a TV show that completed over
> multiple episodes."*
>
> — `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` (L1)

Three load-bearing sentences from the MVP scope, in priority order:

1. **North star (product existence):** *"we need a small working product
   first before expanding because there's no point if it doesn't
   work."*  [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa`]
2. **Friction-killer (the product's job):** The platform's job is *not*
   to host the night — it's to **kill the friction of organising one.**
   [Source: `concepts/games-room-market-context`; corroborated by
   `phone-calls/2026-07-07-call-with-connor-hansen` — "friction" used
   4× in the call]
3. **Continuity engine (the durable value):** *Most games nights have
   no memory. Competitive friendship needs an arc, not isolated
   evenings.*  [Source: `concepts/games-room-market-context`]

**What this is not:** an MVP scope doc. The MVP scope is one-pager
(`originals/2026-07-07-games-room-mvp-scope-1c6aaa`) and changes per
build. This spec captures the *shape* of the product — the things that
should not change between v0.6 and v1.0.

---

## 2. Goals and User Experience

### 2.1 The job-to-be-done

Games Room is an invite-only iOS app for **in-person games nights**, run
by a single host for a small group of friends-of-friends. Members are
**physically present** at the table; the app plans the night, runs the
ledger, and stays quiet during play.

> *"It's not a games app, it's not a gaming app as such — it's a
> platform for people to plan in person games nights."*
> — `phone-calls/2026-07-07-call-with-connor-hansen` (Connor, 09:09–09:24)

### 2.2 The user experience, in three layers

The lifecycle is explicit (`.hermes/plans/2026-07-31_games_room_redesign_v0.8.md`
§Track A §2, "Lifecycle phases"):

| Phase | Time window | Host labour | App behaviour |
|---|---|---|---|
| Discovery | — | Zero | App is dormant |
| Pre-game ritual | T-48h → T-30m | One pre-event note (≤280 chars) + mascot-generated broadcast | Briefing slot, push trio (on-create / T-48h / morning-of) |
| Arrival | T-15m → T-0m | Present-and-warm | iPad at rest in "Arrival Mode" (low-power, mascot quiet) |
| Live play | T-0m → T+2-4h | One tap per scoring event | Mascot silent. Phone in pocket. **Mascot absence is the feature.** |
| Cashout | T+15m | One tap (Finalize) | Per-member chip scan on the member's own phone |
| Post-game → next session | — | Zero | Mascot recap narration + season arc surface |
| Season close | Season end | One tap (Declare) | Awards surface (Phoenix / Veteran / Whale / Drowning) |

[Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` —
locked by Nathan 2026-07-31.]

### 2.3 The five operating principles

These are the *shape* of the product. They survive scope changes.

1. **Runs off-stage.** The app is the rehearsal hall, not the stage.
   The phone is invisible during play.
   [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md`
   Final Statement; reinforced by `concepts/2026-07-27-games-room-profile-aware-social-design`]
2. **One CTA per state.** The dominant action is the single source of
   truth. Secondary actions live behind one tap from the primary.
   [Source: `wiki/originals/ideas/2026-07-17-state-aware-action-block-one-cta-at-a-time-2e35f4`]
3. **Placement follows the workflow, not the feature.** Where does the
   user reach when they need this action? Not "where does the feature
   live?" The user is the verifier.
   [Source: `wiki/originals/ideas/2026-07-17-common-sense-cta-placement-2e35f4`;
   `wiki/originals/ideas/2026-07-17-action-lives-in-natural-session-moment-2e35f4`]
4. **The mascot has a voice so the host does not.** The masked-autistic
   / 2e host's cost is social-generation in real time. The mascot's
   voice takes that work off their plate.
   [Source: `concepts/2026-07-27-games-room-profile-aware-social-design`;
   carries forward `originals/felt-faction-ios-app-v5-felty-as-the-bank`]
5. **Durable over wipe-at-midnight.** The ledger persists across
   sessions within a season. Season → season resets. The continuity
   is the product.
   [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa`
   — "Continuous ledger, not wipe-at-midnight"]

### 2.4 The user roles

Two roles, fixed, no tiers in v1:

- **Host** — owner of the room; the scorer; the only one who can score
  (lock 2026-07-09). The host can also play (lock 2026-07-09).
- **Member** — joins via the host's one-time join code; can view the
  full standings (spectator view is load-bearing, not nice-to-have —
  lock 2026-07-09).

[Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Roles]

### 2.5 The page architecture (one page, three slots)

The Room page is a single scroll whose content rotates by the room's
`DominantAction` state. Same surface area; different content per slot.

| Slot | When | Hero | Primary CTA |
|---|---|---|---|
| **Pre-play Briefing** | event created → T-0m | Briefing card (date, time, who's in, what to bring) | `Claim seat` / `Can't make it` (two buttons) |
| **At-play Witness Screen** | T-0 → settle | Witness hero: mascot-narrated started-time + seat grid + your delayed chip tray | `Withdraw chips` (until first withdrawal) → `Scan your chips` (after host finalises) |
| **Post-play Ceremonial Card** | settle → 24h | Chapter title (28pt serif) + ledger delta (monospaced) + 64pt gap + `↳ Next: <call-forward>` | (none) |
| **Quiet state** | activeEvent == nil && lastSettledAt > 24h ago | Room name + season subtitle + full standings | `+ Add an event` (host only) |

[Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` —
locked L1–L7]

---

## 3. Feature and Functional Requirements

### 3.1 MVP-load-bearing features (must ship before v1)

These are MVP-scoped features that the team has explicitly called out
as *not viable to defer* (lock 2026-07-09, MVP scope):

| ID | Feature | Source | Slices |
|---|---|---|---|
| F-MVP-01 | Invite-only rooms with single-use 6-character join codes | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Join code lifecycle | Join sheet, redemption RPC, optimistic-lock on duplicates |
| F-MVP-02 | Host + member roles (no tiers) | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Roles | `room_memberships.role` enum, role-gated UI |
| F-MVP-03 | Seasons with continuous-within / reset-at-end scoring | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Seasons | `seasons` table, `season_totals` archive, Declare flow |
| F-MVP-04 | Seat deposits with refund / forfeit | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Seat deposits | `seat_deposits` table, attendance check, forfeit flow |
| F-MVP-05 | iPad-first live scoring dashboard (host-only scoring) | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Scoring | `HostDashboard`, per-pack scoring UI |
| F-MVP-06 | 3–4 dev-created game packs (Casino, CAH, Monopoly, Pluto Chess) | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §MVP scope cuts | `packs` table, four seed rows |
| F-MVP-07 | In-app store shell for packs (paid packs v1-ready, MVP packs free) | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §MVP scope cuts | `pack_store` route, install flow |
| F-MVP-08 | Native iOS from day 1 (iPhone + iPad, iOS 26+) | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §MVP scope cuts | SwiftUI throughout, no third-party UI deps |
| F-MVP-09 | Internet required (live DB for state); offline cache deferred | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §MVP scope cuts | Supabase backend |
| F-MVP-10 | Spectator view — members see everyone's scores, not just their own | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Scoring | `standings` query, board render |
| F-MVP-11 | Score correction visibility — "host correcting" indicator in Live Activity + member row badge | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Scoring | Live Activity toggles, row badge |
| F-MVP-12 | Glance + Live Activity + Watch complications for member-facing live-score | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Scoring | WidgetKit + Live Activity (refresh budget: 1 min) |

### 3.2 Pack-as-platform architecture (the unlock)

The pack is a self-describing bundle that tells the app (a) the scoring
rules and (b) the UI template. **Adding a new pack = adding a row, not
shipping a new app version.** This is the architectural difference
between "an app for games nights" and "a platform for games nights."

- **Pack schema (minimum):** `{slug, display_name, scoring_type, win_points, withdraw_default, metadata, scoring_ui_schema, score_computation, how_to_content}`. [Source: `wiki/originals/ideas/2026-07-10-pack-defined-scoring-as-platform-93888e`; `wiki/originals/ideas/2026-07-10-pack-as-declarative-config-93888e`]
- **Two-level install model:** pack installed at app level, enabled per-room. Room never reaches up to global catalog. [Source: `projects/casino-pack-vision-architecture`]
- **First concrete pack:** Casino (`projects/casino-pack-vision-architecture`). Adds the concept **physical chips** that the rest of the scoring system assumes away. Reversed on 2026-07-12 from the original "no chip-photo vision" stance — recorded in the architecture doc for posterity.

### 3.3 The Casino pack (concrete example)

The casino pack is the most-developed pack and the design test for the
rest. The flow (locked 2026-07-12):

1. Member withdraws N points from virtual balance
2. Host dishes out N worth of physical chips at the table
3. Players run as many rounds as they want — app is **not in the loop** during play
4. At session end, host **scans** each member's chip stack (V0.29: per-member scan on the member's own phone, not host-side)
5. Pack converts scanned physical value back into virtual points and writes a single settlement transaction per member

[Source: `projects/casino-pack-vision-architecture`; `originals/2026-07-28-casino-pack-settlement-reversal`]

**Reversal worth knowing:** the v0.28 settlement reversal moved
host-scan → per-member-scan. The 24h window is for unscanned members —
if a member doesn't scan within 24h of session end, the system defaults
their P&L to 0 with a "did not scan" flag. [Source: `originals/2026-07-28-casino-pack-settlement-reversal`]

**Out-of-band system-notifications requirement:** As per the constraint
that no notification cadence exists for "pack installed" — a pack
uninstall must always surface in the room's notification stream because
the room's running state depends on it. [Source: `concepts/games-room-system-notifications` — referenced from `projects/games-room` See-also]

### 3.4 The mascot engine (V0.6 + V0.26)

The mascot is the load-bearing component that buys the host's social
generation. Three layers:

- **V0.6** — mascot engine core: 25-voice matrix (personality ×
  ideology). Generates the one-liner. Existing `generateOneLiner` is
  the foundation. [Source: `concepts/2026-07-27-v06-v26-combined-greenlight`]
- **V0.26** — mascot voice extends to: per-event broadcast, briefing
  narration, recap, dashboard prompt. Adds per-member social
  preferences, host's pre-event note (≤280 chars), calendar auto-add
  toggle. [Source: `concepts/2026-07-27-games-room-v0-26-spec`]
- **V0.8 layout constraint** — mascot voice is the **footer caption**
  (italic 13pt one-liner), never the lead. The hero-card mascot
  treatment is removed. [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` L4]

### 3.5 Navigation and information architecture

The structural rules, locked 2026-07-10:

- **Tabs are for peers within a context. Pages are for different
  contexts.** [Source: `wiki/originals/ideas/2026-07-10-tabs-vs-pages-navigation-93888e`]
- **Two tabs only:** `Rooms` (default), and an Account / Room settings
  pair. Last-viewed room opens the Rooms tab automatically.
  [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Layout Constraints]
- **No tabs inside a room.** The room page is a single scroll with three time slots. No segmented control. No third page. [Source: same, L1]
- **Settings surfaces — three sub-sheets of the room settings sheet:** Social (mascot, personality, ideology, narration toggles), Operations (max seats, invite quota, join bonus), Members (roster + blacklist). [Source: same, "Section disposition" table]
- **Packs are operational chrome in the host's room settings.** They are NOT on-page content. [Source: same, L6; "Sections — Additional Drops"]

### 3.6 Notification trio (locked 2026-07-12, refined v0.8)

The pre-event notification cadence runs three pushes, with the body
branching on the **recipient's response state** — three branches, not
two:

| State | Definition | Receives further nudges? |
|---|---|---|
| **Claimed** | Tapped `Claim seat` | Yes — logistics only (no "claim your seat" prompt) |
| **Declined** | Tapped `Can't make it` | No. Terminal for this event. |
| **Unclaimed (no response)** | Received on-create push, did not tap either | Yes — T-48h + morning-of are **reminders**, not fresh prompts |

| Cadence | When | Unclaimed | Claimed | Declined |
|---|---|---|---|---|
| On create | `event.createdAt` | "…has a new [event] on [date]. Open to claim your seat." *(the only prompt)* | (n/a) | (n/a) |
| T-48h | T-48h | "reminder — [event] is Saturday 8pm. [N] seats left, [N] claimed." | "…is in two days. You're in. Host's note: [≤280 chars]." | skipped |
| Morning of | T-0m | "reminder — tonight at [time]. [venue]. [N] seats left." | "tonight at [time]. [venue]. You're in." | skipped |

[Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` —
notification cadence; `originals/2026-07-07-games-room-mvp-scope-1c6aaa`
"What's still open" #4]

### 3.7 Multi-room per user (the unlock)

Each user can be a member of multiple rooms. Locked 2026-07-12.

- **Rooms list = top-bar dropdown** reachable from any room view.
- **Create-room affordance = `+` inside the dropdown.** Visible to
  anyone but functional only for users hosting their own room.
- **Default-on-relaunch = last-opened room.**
- **Account-level settings (display name, email, sign-out) live in a
  separate account surface** — not inside the rooms dropdown.
- **Session-active indicator** (green dot / "LIVE" / row reorder) is
  the surface where Glance / Live Activity / Watch get the "you have a
  session in 23 minutes" reminder.

[Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What's
still open" #1, #3]

### 3.8 Visual design grammar

- **Brand voice:** *"Each room gets its own mascot with its own
  personality. A season-long scoreboard that turns poker night into
  something worth showing up for."* — `IDEA.md` (the repo's
  3-line gist).
- **iPhone-first.** iPad renders the iPhone-shaped column centered
  with black margin. Locked in `.designs/room-page/BRIEF.md`.
  [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Layout Constraints]
- **Existing 80/20/10 palette stays** (`Theme.swift`). One accent at a
  time. No new components in `Theme.swift` without a deliberate reason.
  [Source: same]
- **Visual placebo = design-bar-bumped.** The user has explicitly
  refused to ship "functional-but-ugly." The polish is the work.
  [Source: `wiki/personal/reflections/2026-07-17-ui-elevation-do-better-2e35f4`]
- **Icons as `chair.fill` semantic ("fit the games room aesthetic").**
  [Source: same, verbatim quote]
- **Pull-to-refresh > buttons.** When the action is "refresh," a
  pull-to-refresh is more intuitive than a button. Avoid the trap of
  putting buttons where the platform idiom is gesture.
  [Source: `wiki/personal/reflections/2026-07-17-user-as-loop-prior-corrector-2e35f4`,
  moment two.]

### 3.9 Build-target summary

| Component | State |
|---|---|
| iOS source | Active, building toward v0.8 |
| Xcode project | `GamesRoom.xcodeproj` (Universal, iOS 26+) |
| Backend | Supabase (Postgres + RPC) |
| Calendar | EventKit (V0.26 — per-room host toggle, default off) |
| Vision | Core ML on-device (V0.3 casino pack), hybrid fallback deferred to v2 |
| Auth | Custom (V0.2 was the Supabase auth milestone) |
| Mascot engine | Apple Foundation Models framework (iOS 26+) |

[Source: `README.md` in the repo archive + `concepts/2026-07-27-games-room-v0-26-spec`]

---

## 4. Constraints

### 4.1 Platform and stack

- **iOS 26+** (Apple Foundation Models framework). iPhone + iPad,
  Universal. SwiftUI throughout. No third-party UI dependencies.
  [Source: `README.md` — `.archive/2026-07-31-pre-v0.8/`; `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md`]
- **Supabase backend** (Postgres + PostgREST RPCs). Hardcoded
  assumptions: `events.id = p_session_id` is the source of truth for
  room scope (migration `025_casino_event_integrity.sql`). [Source: `originals/2026-07-21-games-room-v024-casino-vertical-slice`]
- **Internet required.** Offline cache possible but not v1.
  [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §MVP scope cuts]
- **No third-party UI dependencies.** SwiftUI + Foundation Models native.
- **Native iOS from day 1.** No web wrapper, no React Native. The
  dashboard runs native on iPad. [Source: same]

### 4.2 Stylistic and design constraints

- **Apps/ads cheapen the experience** — UX constraint, not a preference.
  Ads: **No.** [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` Monetisation matrix]
- **No Live Activities, no push bait, no glance-bait during play.**
  Watch is v2. [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Layout Constraints]
- **No third navigation page.** No tabs inside a room. Two tabs only.
  [Source: same, L1, L6]
- **Mascot voice = footer caption.** Never the lead. Italic 13pt
  one-liner. [Source: same, L4]
- **Mascot presence is silence during play.** The mascot earns its
  voice after settle. [Source: same, "At-play Witness Screen" row]
- **One primary CTA per state, always.** Secondary actions live behind
  a single tap from the primary. [Source: same, Layout Constraints;
  `wiki/originals/ideas/2026-07-17-state-aware-action-block-one-cta-at-a-time-2e35f4`]
- **Cross-room = v2 substrate.** The data model must not collapse
  rooms into a single community. [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md`]

### 4.3 Audience

- **Primary:** friends-of-friends groups running in-person games
  nights. Self-host model. Bounded seats (likely 8–12 per room).
  [Source: `concepts/games-room-market-context`; `phone-calls/2026-07-07-call-with-connor-hansen`]
- **The host is doing the highest-cost work.** The masked-autistic /
  2e host profile is the *target* — the mascot engine is the bet that
  pays off the host's social-generation labour. [Source: `concepts/2026-07-27-games-room-profile-aware-social-design`]
- **Global reach argument + pub-partnership expansion as the scale
  path.** Pub/venue partnerships (trivia nights on Tue/Wed/Thu)
  deferred until MVP ships. [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions"; `atoms/2026-07-18/the-pub-off-nights-wedge-trivia-when-nobodys-there`]

### 4.4 Legal / regulatory

- **Virtual currency with no real-world exchange** is the assumed
  posture. No fiat, no crypto, no redemption.
- **No legal/gambling assessment in v1.** Connor's verbatim: "You want
  to be careful you don't step on gaming rules and gambling rules and
  things… we haven't done any legal assessment or risk assessment on
  the idea." Defer until launch-readiness. [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions"]

### 4.5 Tone and brand

- **NOT finance-noir.** Felt Faction's tone is finance-noir. Games
  Room's tone is TBD. Does not carry from Felt Faction.
  [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What carries from Felt Faction"]
- **Brand-lock position:** "Games Room" is the public-facing,
  commercialised fork. Felt Faction is the internal private program.
  Separate projects, separate pages, separate brand. [Source: `originals/2026-07-20-games-room-brand-decision`]

### 4.6 Ownership and operating model

- **Engineering lead: Connor.** Verbatim: "that'd fall on my shoulders mostly."
- **Nathan: supports.** Will learn where he can. Will help.
- **MVP first.** No expansion until the small thing works.
- **Engineering assist: opencode** (the OpenCode CLI is the implementation hands; Hermes Agent is the orchestrator).
- **Orchestration: Hermes Agent.** [Source: `README.md` in the repo archive; `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Ownership split"]

---

## 5. Explicit Non-Goals (do not build in v1)

These are ideas that have been *deliberately* rejected or deferred, with
the rationale captured. They are non-goals so the planner doesn't
re-introduce them.

| ID | Non-goal | Reason | Source |
|---|---|---|---|
| N-01 | Public signup / marketplace | Host-controlled invite list. "Private, not public." | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Concept |
| N-02 | Multi-tier membership roles | Two roles only. No tiers. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Roles |
| N-03 | Parallel seasons per room | One season per room at a time. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Seasons |
| N-04 | Auto-creation of next season | Host-triggered, not automatic. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Seasons |
| N-05 | Loans / interest ("The Bank") | Virtual chips don't need loans. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What carries from Felt Faction" |
| N-06 | In-game currency bought for real money | Pay-to-win violates chip-game integrity. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` Monetisation matrix |
| N-07 | Ads | "Apps/ads cheapen the experience" — UX constraint. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` Monetisation matrix |
| N-08 | Community-editable how-to guides | Bundled deferral with freemium/ads question. v2. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions" |
| N-09 | Community-created packs in v1 | Catalog v1, contribution v2. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` Monetisation matrix |
| N-10 | Freemium paid-tier offerings | Architecture supports it. Pick offerings at v2 when users exist. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions" |
| N-11 | Pub/venue partnerships | Deferred until MVP ships. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions" |
| N-12 | Personality tone (CARROT-style) | Revisit when there's UI surface to write for. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions" |
| N-13 | Legal/gambling assessment | Defer until launch-readiness. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "Deferred decisions" |
| N-14 | Finance-noir aesthetic | "Probably doesn't carry. Games Room tone TBD." | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What carries from Felt Faction" |
| N-15 | Multi-scorer per room | Host is the single scorer. If role-sharing is needed, fix in v2. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §Scoring |
| N-16 | Live Activities during play | No glance-bait during play. Watch is v2. | `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Layout Constraints |
| N-17 | Cross-room social surface in v1 | Rooms stay siloed. Cross-room is v2 substrate. | `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Q5 |
| N-18 | Per-room iOS notification categories | One global notification channel. User mutes via iOS system settings. Per-room `thread-id` is server-side dedup only. | `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What's still open" #4 |
| N-19 | Decline / re-entry on the room page | Decline is terminal in v0.8. Member-side event edit surface is v0.9 candidate. | `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` "What's Still Open" #9 |
| N-20 | Persisting the original scan photo | Photos stay on-device; default is **discard photo, keep hash + vision snapshot** for audit. | `projects/casino-pack-vision-architecture` |

---

## 6. Open Questions / Unresolved Decisions

These are the live questions the planner needs to flag for human
attention. Each one is a real ambiguity, not a rhetorical one.

### 6.1 From the v0.8 brief (`.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` "What's Still Open")

1. **Chapter-line cadence.** Does the host see the call-forward before
   it goes to the room, or does the mascot own it end-to-end? Lean:
   host-approval beat is required for the season subtitle, not for
   per-session chapter lines.
2. **Delayed chip-tray default.** Track C v1.3 sets the lag to "end
   of hand." The casino pack's hand-boundary detection is not in the
   model today. Lean: ship at lag = 0 (live) for v0.8; v0.9 introduces
   hand-boundary detection.
3. **Shared T-0 haptics cue.** iOS notifications permission is
   one-way. Members who denied at install never get the cue. Lean:
   prompt for permission at room join, not at install. The on-page
   briefing is the fallback for denied-permission members.
4. **MemberNotes social-preferences asymmetry.** Members may
   self-censor if they learn the host is reading their preferences.
   Lean: rename the surface so the asymmetry is implicit ("how to host
   me" not "my preferences").
5. **Season subtitle mascot voice.** Track C v1.3 proposes the subtitle
   updates only on arc-grade closes. The mascot engine's 25-voice matrix
   does not have an "arc-grade" calibration. Lean: ship a host-curated
   subtitle for v0.8; v0.9 introduces mascot judgment.
6. **Season-end awards card's Drowning recipient.** Per
   `.designs/room-page/track-c-lead-directive.md §2a`, Drowning is
   private to the member. The V0.7 spec has the awards surface; the
   privacy rewrite is unverified. Lean: build the privacy boundary
   into the v0.8 schema, ship the awards card after schema lands.
7. **Notification bodies.** The 25-voice mascot matrix needs to produce
   3 distinct message voices per personality × ideology per response
   state (claimed / declined / unclaimed-no-response) = 75 cells per
   personality × ideology. Lean: ship a templated
   `{mascot}, {event}, {date}, {time}, {venue}, {seats_left},
   {seats_claimed}` interpolation for v0.8; v0.9 extends the
   `MascotEngine` to generate per-state bodies.
8. **On-create notification timing.** The `event.createdAt` push is
   per-recipient (not a broadcast); recipients are the room's members
   at the moment of creation. New members joining after `createdAt` do
   not get the on-create push — they get the T-48h and morning-of
   pushes only. Lean: ship as documented; v0.9 introduces a "joined
   late" catch-up push.
9. **Decline is terminal in v0.8.** A declined member who changes their
   mind must do it through the member-side event edit surface, which
   is a v0.9 candidate. **The declined-member row in the host's
   claim-status view should distinguish "declined" from "no response"
   so the host knows whose seat is genuinely available vs whose seat
   is still contested.** ← this is a real UX gap in v0.8.

### 6.2 From the broader MVP scope

10. **Tone of Games Room.** The MVP-scope doc explicitly says the
    Felt Faction finance-noir tone "probably doesn't carry" and "Games
    Room tone TBD." The mascot engine is voiced but the brand-voice
    surface hasn't been specified. [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa`]
11. **Does the invite-only model survive a public launch?** Direct
    open question from the project hub. [Source: `projects/games-room`]
12. **What's the minimum surface area that makes a room feel useful?**
    Direct open question. [Source: `projects/games-room`]
13. **How much of Felt Faction's mechanics carry over vs. need to be
    reworked for strangers?** Direct open question. [Source: `projects/games-room`]
14. **Host-role affordance in the rooms list.** If a user hosts one
    room and plays in two others, the room row needs to make the host
    role visible without being shouty. Color, icon, or section header
    — pick at iOS UI design time. [Source: `originals/2026-07-07-games-room-mvp-scope-1c6aaa` "What's still open" #2]
15. **Vision feasibility probe.** Run Core ML stack-segmentation on
    real chip photos in normal room lighting. If <80% reliable, the
    casino pack spec needs a hybrid fallback. The 10-photo Vision
    probe (V0.3 casino pack) is still the single highest-leverage
    blocking action. [Source: `projects/casino-pack-vision-architecture` "Open gates" #1; `concepts/2026-07-27-v06-v26-combined-greenlight`]
16. **Chip denomination count.** Standard sets are 3–5 colors. Confirm
    tournament sets aren't a v1 requirement. [Source: `projects/casino-pack-vision-architecture` "Open gates" #3]
17. **Tournament / Monopoly Deal behavior.** Per the pack schema, it
    requires *one* winner's score to be entered. But the "monopoly deal
    game pack would have winner gets x amount of points" model
    assumes a single-winner per game. What does multi-winner or
    split-the-pot look like in this pack? Not in the v0.7 worked
    example. [Source: `wiki/originals/ideas/2026-07-10-pack-defined-scoring-as-platform-93888e`]
18. **Pack install/uninstall notifications.** A pack uninstall must
    surface in the room's notification stream because the room's
    running state depends on it. The spec is mentioned but not
    detailed. [Source: `concepts/games-room-system-notifications`]

### 6.3 Risks the planner should weigh

- **R1: Mascot voice fragility.** The footer caption form is
  lower-risk than a hero card. Stay in footer. [Source: `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Risks]
- **R2: Pre-game phone presence is hard to enforce by app design.**
  The only lever is "nothing compelling is on the phone during play."
  Aggressive push-budget discipline. [Source: same]
- **R6: Monetisation is constrained.** 4 dev-curated packs, at least 2
  must ship in v1. [Source: same]
- **R7 (cross-cutting):** The user's working pattern is *real-time
  prior correction at the shape level*. Plan iteratively — the spec
  you ship will be re-anchored by the user with "apply common sense"
  prompts. Build the loop, not the assumption. [Source: `wiki/personal/reflections/2026-07-17-user-as-loop-prior-corrector-2e35f4`]
- **R8 (cross-cutting):** Data-layer drift hides UI features. Always
  query the DB before debugging the UI. [Source: `wiki/personal/reflections/2026-07-10-data-layer-drift-hides-ui-93888e`]

---

## 7. Source Index (canonical slugs)

For traceability. Every requirement above cites one of these:

- `projects/games-room` — the project hub
- `originals/2026-07-07-games-room-mvp-scope-1c6aaa` — the MVP scope one-pager
- `originals/2026-07-20-games-room-brand-decision` — the brand-lock artifact
- `originals/2026-07-21-games-room-v024-casino-vertical-slice` — V0.24 vertical slice
- `originals/2026-07-28-casino-pack-settlement-reversal` — V0.28 settlement reversal
- `projects/casino-pack-vision-architecture` — Casino pack architecture
- `concepts/games-room-market-context` — market framing
- `concepts/2026-07-27-games-room-v0-26-spec` — V0.26 mascot extension
- `concepts/2026-07-27-games-room-profile-aware-social-design` — the masked-autistic / 2e target user
- `concepts/2026-07-27-v06-v26-combined-greenlight` — combined V0.6 + V0.26 plan
- `wiki/originals/ideas/2026-07-10-pack-defined-scoring-as-platform-93888e` — pack-as-platform
- `wiki/originals/ideas/2026-07-10-pack-as-declarative-config-93888e` — declarative pack configs
- `wiki/originals/ideas/2026-07-10-tabs-vs-pages-navigation-93888e` — tabs vs pages
- `wiki/originals/ideas/2026-07-17-common-sense-cta-placement-2e35f4` — placement rule
- `wiki/originals/ideas/2026-07-17-action-lives-in-natural-session-moment-2e35f4` — placement follows workflow
- `wiki/originals/ideas/2026-07-17-state-aware-action-block-one-cta-at-a-time-2e35f4` — one CTA per state
- `wiki/personal/reflections/2026-07-17-ui-elevation-do-better-2e35f4` — design bar
- `wiki/personal/reflections/2026-07-17-user-as-loop-prior-corrector-2e35f4` — user-as-corrector pattern
- `wiki/personal/reflections/2026-07-10-data-layer-drift-hides-ui-93888e` — data-layer discipline
- `phone-calls/2026-07-07-call-with-connor-hansen` — the founding call with Connor
- `inbox/audio/2026-07-06-call-with-connor.transcript` — Connor's audio transcript
- `originals/2026-07-07-games-room-mvp-scope-1c6aaa` §"What's still open" — multi-room decisions
- `IDEA.md` (repo) — the 3-line gist
- `README.md` (in `.archive/2026-07-31-pre-v0.8/`) — repo README
- `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` — V0.8 design brief (the most recent converged design artifact)
- `concepts/games-room-system-notifications` — notification system (referenced from project hub)
- `concepts/games-room-scoring-pack-schema` — pack schema (referenced from project hub)
- `shared/felt-faction-commercialisation-rebrand-fork-v18` — brand-lock decision artifact
- `inbox/2026-07-12-056564db` — "Games Room Pack Architecture Vision" (inkling)
- `inbox/2026-07-12-369a1029` — "Game Room Design Decisions (from Connor breakfast)"
- `inbox/2026-07-12-35510a62` — "Rooms Games: Architecture Pivot"
- `atoms/2026-07-18/the-pub-off-nights-wedge-trivia-when-nobodys-there` — pub-partnership wedge

---

## 8. Schemas (for the planner)

### 8.1 `packs` table (minimum MVP)

```sql
create table public.packs (
  id uuid default gen_random_uuid() primary key,
  slug text unique not null,
  display_name text not null,
  description text,
  scoring_type text not null check (scoring_type in ('single_winner', 'withdraw_return')),
  win_points int default 1,                    -- for single_winner
  withdraw_default int default 10,             -- for withdraw_return
  metadata jsonb,                               -- name, icon, description
  scoring_ui_schema jsonb,                      -- fields, labels, layout
  score_computation jsonb,                      -- chip math, win conditions
  how_to_content text,                          -- onboarding
  created_at timestamptz default now() not null
);

create table public.events (
  id uuid default gen_random_uuid() primary key,
  room_id uuid references public.rooms(id) not null,
  pack_slug text references public.packs(slug) not null,
  name text not null,
  played_at timestamptz not null,
  created_by uuid references public.users(id),
  created_at timestamptz default now() not null
);
```

[Source: `wiki/originals/ideas/2026-07-10-pack-defined-scoring-as-platform-93888e`]

### 8.2 Casino pack DB additions

- `transactions` — general ledger, written by every pack
- `casino_withdrawals` — point → chip bracket per member per session
- `casino_room_config` — per-room pack config (color map, dimensions)

[Source: `projects/casino-pack-vision-architecture`]

### 8.3 Identity authority

`events.id = p_session_id` is the source of truth for room scope. All
casino RPCs derive `room_id` from the event, not from the caller's
membership. Hardcoded in migration `025_casino_event_integrity.sql`.
[Source: `originals/2026-07-21-games-room-v024-casino-vertical-slice`]

---

## 9. Final Statement (closer)

> *"The room page is a three-slot stage — pre-play Briefing (T-48h →
> T-0m), at-play Witness Screen (live), post-play Ceremonial Card
> (settle) — that rotates by time-to-event. The dominant-action lever
> is the single source of truth. One primary CTA per slot, always.
> Mascot voice is the footer caption, never the lead. Standings is the
> TV-arc ledger, full board, your row highlighted. Packs are operational
> chrome in the host's room settings; they are not on-page content.
> App settings is a gear icon in the nav bar. The phone is invisible
> during play by ambient-gating the chapter strip and by ritualising
> the settle-only ceremony. The arc compounds through a chapter strip
> threaded by call-forwards, under a season subtitle."*
>
> — `.hermes/plans/2026-07-31_games_room_redesign_v0.8.md` Final Statement

> *"A server-side rehearsal hall that runs almost entirely off-stage,
> with a host who's present in the room because the mascot has taken
> the narration, a ledger that compounds the social relationship across
> a season, and a phone that's invisible during play because the room
> is the product."*
>
> — same, Closing Line

---

*Synthesised 2026-08-05 from gbrain knowledge base. Source citations
use canonical slugs. When this spec and the source page disagree, the
source page wins — this document is a derived artifact, not a source of
truth.*
