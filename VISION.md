# Games Room — Vision

> Consolidated vision for the Games Room project, retrieved from gbrain
> (2026-08-11). Every section is traceable to a canonical brain page
> (`[Source: <slug>]`). This is the *vision* — the shape of the product.
> For build-level detail see `docs/vision.md` (full spec) and the
> implementation spec in the kanban workspace (`games-room-spec.md`).
> When this document and a source disagree, the source wins.

---

## 1. What this is

An invite-only iOS app for **in-person games nights**. ≥1 host per room
(V0.91 — multi-host is allowed; the original creator is the first host,
any host can promote another member to host, any host can demote a host
back to member as long as ≥1 host remains),
a small fixed group (8–12), physically present at the table. The app plans
the night, runs a credit ledger, and stays quiet during play. Not a games
app — a platform for people to plan and run in-person games nights.

Commercialised fork of the private Felt Faction program. Nathan + Connor
intend to commercialize it so other groups can run their own game nights
with the same structure. Engineering lead: Connor. Implementation hands:
OpenCode CLI. Orchestration: Hermes Agent.

[Source: projects/games-room, 2026-07-20]

## 2. Why it exists (the market gap)

- The "third place" died in 2019 and hasn't come back. Pubs are
  restaurants, cafés are co-working. The free, low-stakes
  "people-just-hanging-out" venue is priced out almost everywhere.
- Group chats replaced the group. The friction of *physical coordination*
  — date, venue, who's-in, what-are-we-playing, what-do-I-bring — is now
  the entire reason most nights die in the iMessage thread.
- Most games nights have no memory. Nobody tracks who actually wins
  across months. Competitive friendship needs an arc, not isolated
  evenings.

**The gap:** Games Room is the first platform that treats your friend
group as a durable, multi-room social object. Same friend from poker night
also plays in the CAH Sunday group — that person is a member of multiple
rooms, each with its own season, rhythm, and personality. Multi-room per
user is the unlock. Most apps make you pick one community; Games Room
carries all of them.

[Source: concepts/games-room-market-context, 2026-07-12]

## 3. North star (the shape, do not change)

1. **Kill the friction of organising a night.** Host labour per event =
   ~3 taps (Create, Finalize, Declare). Phone invisible during play.
2. **Continuity engine, not wipe-at-midnight.** The ledger compounds
   within a season so competitive friendship has an arc — "like an arc in
   a TV show that completed over multiple episodes."
3. **Two role states — Host and Member; multi-host is allowed (V0.91).**
   No tiers, no `.cohost` / `.moderator` middle ground. The original
   creator is the first host; any host can promote another member to
   host, and any host can demote a host back to member as long as
   ≥1 host remains. A room is never hostless. Host scores alone and
   can also play.
4. **One CTA per state.** The dominant action is the single source of
   truth.
5. **Placement follows the workflow moment**, not the screen inventory.
6. **Mascot voice is the footer caption** (italic 13pt one-liner). Never
   the lead. Mascot earns its voice *after* settle.

[Source: originals/2026-07-07-games-room-mvp-scope-1c6aaa; concepts/games-room-market-context]

## 4. UX vision — the lifecycle

| Phase | Window | Host labour | App behaviour |
|---|---|---|---|
| Pre-game | T-48h → T-30m | One pre-event note (≤280 chars) | Briefing card, mascot broadcast, push trio |
| Arrival | T-15m → T-0m | Present-and-warm | iPad in Arrival Mode (low-power, mascot quiet) |
| Live play | T-0m → T+2-4h | One tap per scoring event | Mascot silent. Phone in pocket. |
| Cashout | T+15m | One tap (Finalize) | Per-member chip scan on member's own phone |
| Post-game | settle → 24h | Zero | Chapter title + ledger delta + call-forward |
| Season close | Season end | One tap (Declare) | Awards surface (Phoenix/Veteran/Whale/Drowning) |

**Page architecture:** the Room page is a single scroll whose content
rotates by the room's `DominantAction` state — Pre-play Briefing
(`Claim seat` / `Can't make it`), At-play Witness Screen (`Withdraw
chips` → `Scan your chips`), Post-play Ceremonial Card, or Quiet state
(`+ Add an event`, host only).

## 5. Product pillars

### 5.1 Packs as a platform
Modular, downloadable game packs — installable into the app, not
hard-coded. Each room enables its own set of games; per-room
personalization. Each pack declares its scoring rules + UI template
(pack-as-platform schema). Two-level install: pack installed at app
level, enabled per-room. Room never reaches up to a global catalog.
In-app store shell exists; paid packs are v1-ready even if MVP packs are
free.

[Source: inbox/2026-07-12-056564db (pack architecture vision); concepts/games-room-scoring-pack-schema]

### 5.2 The Casino pack and the vision system
The first concrete pack, and the anchor piece. Adds the concept the rest
of the scoring system assumes away: **physical chips**.

- **The flow (locked 2026-07-12):** member withdraws N points from
  virtual balance → host dishes out physical chips → play runs with the
  app *not in the loop* → at session end each member scans their own
  remaining stack on their own phone → pack converts scanned value back
  to virtual points as a single settlement transaction.
- **Why vision:** manual counting is the failure mode the MVP explicitly
  avoided — "scoring friction is the UX risk." Vision collapses "host
  taps 47 buttons" into "member points camera, taps confirm." Win is
  fewer taps, not novelty.
- **The reversal worth remembering:** the 2026-07-07 MVP scope said
  "chip-photo vision → does NOT carry." Reversed 2026-07-12 after the
  Connor breakfast: virtual chips mean the host is back to tapping every
  score — exactly the friction the live-scoring dashboard was built to
  avoid. Physical chips + vision at session end keeps the host's loop
  short and the ledger accurate.
- **Settlement model (V0.29, per-member):** each member scans their own
  chips (trust: the member validates their own count, vision is the
  assistant not the authority). 12 members scan in parallel instead of
  one host serially. Unscanned members default to P&L 0 with a
  "did not scan" flag after a 24h window. Host Finalize closes the
  session.
- **On-device first:** Core ML segmentation detector, no API key, no
  network. LOCKED 2026-08-10: stress recall 0.975, precision 1.000,
  color 0.974, zero pure-felt false positives, deterministic. Hybrid
  (on-device + cloud) is v2 only if confidence falls short.
- **Privacy:** images stay on-device. Default = discard photo, keep a
  hash + vision snapshot so disputes can be reasoned about without the
  original image.

[Source: projects/casino-pack-vision-architecture, 2026-07-12; originals/2026-07-28-casino-pack-settlement-reversal; originals/2026-07-21-games-room-v024-casino-vertical-slice]

### 5.3 The mascot (social layer)
Each room gets its own mascot with its own personality — a 25-voice
matrix (personality × ideology), extended to a 75-cell matrix with
per-event broadcast, briefing, recap, and season-end. Generated via
Apple Foundation Models (iOS 26+ native LLM). Voice is always the footer
caption, never the lead. The mascot takes social-generation work off the
host's plate. Gated on the Q-TONE brand-voice decision.

[Source: concepts/2026-07-27-games-room-profile-aware-social-design; concepts/2026-07-27-v06-v26-combined-greenlight]

### 5.4 Design principles (earned, not assumed)
- **"Apply a bit of common sense"** — placement is a function of three
  axes: *who acts* (self / host / any-of-N), *when in the session*
  (upcoming / active / past), *how often*. Withdraw = member action at
  session start → member's own row. Settle = host action at session end
  → PAST section. A button in the wrong moment is worse than no button.
- **Pull-to-refresh > button.** Gestures over chrome.
- **"We are not aiming to be mediocre."** Functional-but-ugly is a
  reject; polish is the work. The design bar is the bar of UI that got
  design awards.
- **Icons as `chair.fill` semantic** — fits the games room aesthetic.
- **Emotional design on the moments that matter** (Claim seat prominent,
  not buried next to destructive actions).

[Source: wiki/originals/ideas/2026-07-17-common-sense-cta-placement-2e35f4; wiki/personal/reflections/2026-07-17-ui-elevation-do-better-2e35f4]

## 6. User stories & requirements

> Note: gbrain does not contain a formal user-story backlog. The stories
> below are **derived** from the canonical MVP scope, pack-schema,
> casino-pack, and V0.26/V0.6 specs. Each is traceable to its source.
> Where a requirement is locked with a date, the date is given.

### 6.1 Rooms, invites, roles
- US-01 — As a **host**, I can create a room and generate a **single-use
  6-character join code** so friends can join by typing it. (Locked
  2026-07-09: 6-char, human-typable, room-scoped.)
- US-02 — As a **member**, I can redeem a join code once; a second device
  sees "code already used" (optimistic lock). (Locked 2026-07-09.)
- US-03 — As a **host**, I can generate unlimited codes. Member code
  quotas are v2.
- US-04 — As a **host**, deleting the room expires all outstanding codes.
  (Locked 2026-07-09.)
- US-05 — As a **user**, I am a member of multiple rooms simultaneously,
  with a top-bar dropdown to switch rooms (default-on-relaunch = last
  opened room). (Locked 2026-07-12.)
- US-06 — As a **user**, I can see which of my rooms has a live session
  (green dot / LIVE badge / row reorder). (Locked 2026-07-12.)
- US-07 — As a **user**, I have exactly two role states: host or member.
  No tiers. (Locked 2026-07-07.)

### 6.2 Seasons & scoring
- US-08 — As a **host**, I define the season name and length; scores
  carry between sessions within a season and reset at season end.
- US-09 — As a **host**, I trigger the next season manually — no
  auto-creation, no parallel seasons per room. (Locked 2026-07-09.)
- US-10 — As a **member**, I see the current season running total, a
  per-game breakdown (Poker +240 · CAH +60 · Monopoly −30), and
  this-season vs previous-seasons comparison (the "improving over time"
  view).
- US-11 — As a **member**, I can view **everyone's** scores in the room,
  not just my own (spectator view). (Locked 2026-07-09.)
- US-12 — As a **host**, I am the only scorer, and I can play too.
  (Locked 2026-07-09.)
- US-13 — As a **member**, I see a "host correcting" indicator for ~30s
  after the host edits a score, plus a faint dot on the affected member's
  row. No version history in v1. (Locked 2026-07-09.)

### 6.3 Seat deposits
- US-14 — As a **host**, I can require seat deposits for an event.
- US-15 — As a **member**, I claim a seat (deposit paid) and get it
  refunded on attendance, forfeited on no-show. Forfeited deposits
  vanish into the metaphorical bank — no one is enriched. (Locked
  2026-07-09.)
- US-16 — Reservation status flow: `invited → confirmed (deposit paid) →
  attended (refunded)` or `invited → confirmed → no_show (forfeited)`.

### 6.4 Game packs
- US-17 — As a **host**, I install packs into my room from an in-app
  store; each room has its own set of games. (Pack architecture vision,
  2026-07-12.)
- US-18 — As a **developer/pack author**, a pack is a config: it declares
  `scoring_ui` (layout, labels, game-type options) and `score_compute`
  so the app renders the right scoring UI per pack. (User-stated
  requirement, 2026-07-10: "each game pack tells games room what the
  scoring is like for a particular game … the UI should be different for
  each pack".)
- US-19 — As a **host**, I can switch packs mid-session (toggle at will).
  Structured multi-pack nights are v2. (MVP answer, 2026-07-09.)
- US-20 — As a **host**, I can correct a score by tapping a member's
  running total, seeing recent entries, and editing/deleting — one tap,
  chat-thread pattern.

### 6.5 Casino pack (chip vision)
- US-21 — As a **member**, at session start I can withdraw N points from
  my virtual balance to physical chips (button on my own member row).
- US-22 — As a **member**, at session end I scan my own remaining chip
  stack with my own phone, see the vision result, and tap "Looks right"
  or "Off by $X". Low-confidence results let me re-scan with better
  lighting. (Settlement reversal, 2026-07-28.)
- US-23 — As a **host**, I see per-member scan results as they arrive,
  resolve disputes, and tap Finalize to close the session. (2026-07-28.)
- US-24 — As a **member** who doesn't scan within 24h of session end, my
  P&L defaults to 0 with a "did not scan" flag. (2026-07-28.)
- US-25 — As a **member**, my scan photo is discarded by default; only a
  hash + vision snapshot is kept for dispute resolution.
- US-26 — As a **host**, I can override the per-room chip color map
  (defaults to standard casino colors).

### 6.6 Mascot & social layer
- US-27 — As a **host**, the mascot (personality × ideology) writes the
  broadcast, briefing, recap, and season-end narration so social
  generation is off my plate; I can override with my own text. (V0.26,
  2026-07-27.)
- US-28 — As a **member**, I receive a 48h pre-session briefing (who's
  coming, what's played, what to bring).
- US-29 — As a **host**, I can toggle per-room: auto-broadcast, 48h
  briefing, calendar auto-add (EventKit, default off), per-member
  preferences, mascot narration. (V0.26, 2026-07-27.)
- US-30 — As a **member**, I can set social preferences the host sees but
  I don't broadcast ("introduce me by name", low-stakes banter first).
  Default pre-set, editable. (V0.26, 2026-07-27.)

### 6.7 Notifications
- US-31 — As a **user**, I get system-wide notifications (new session,
  seat claiming opened) for any room I'm a member of, grouped per room on
  the lock screen (`thread-id = room_id`). (2026-07-09/10.)
- US-32 — As a **user**, I mute via iOS system settings — one global
  channel, no in-app per-room mute in v1. (Simplified 2026-07-12.)

## 7. Feature list

MVP (v1) features, consolidated from MVP scope + pack schema + casino
spec + V0.6/V0.26 greenlight:

1. **Rooms** — invite-only, join-code lifecycle (single-use 6-char,
   host unlimited, dies with room).
2. **Roles** — host / member only.
3. **Seasons** — host-defined, continuous-within / reset-at-end,
   host-triggered next season, no parallels.
4. **Seat deposits** — refund on attendance, forfeit on no-show,
   closed-loop forfeiture.
5. **Live scoring dashboard** — iPad-first, host-only scoring, big
   buttons, per-pack UI, spectator view for members (1-min refresh
   budget, locked 2026-07-09).
6. **Game packs (4 dev-created)** — Casino, CAH, Monopoly Deal, Pluto
   Chess; pack = config (metadata, scoring_ui, score_compute, how_to,
   version, author_kind).
7. **In-app pack store shell** — catalog from day 1; paid packs v1-ready;
   community contribution v2.
8. **Casino pack** — withdraw → physical chips → per-member scan →
   settlement; on-device Core ML vision (F-CAS-02 LOCKED 2026-08-10);
   per-room color map; per-member "Looks right / Off by $X"; 24h scan
   window; host Finalize.
9. **Score correction** — chat-thread pattern, 30s "host correcting"
   indicator, no edit history in v1.
10. **Progression views** — season total, per-game breakdown,
    improving-over-time.
11. **Mascot engine** — personality × ideology matrix, Foundation Models,
    footer-caption voice, broadcast/briefing/recap/season-end (V0.6 +
    V0.26 greenlit 2026-07-27; gated on Q-TONE for the full 75-cell
    matrix).
12. **System notifications** — one global channel, per-room `thread-id`
    grouping, deep-link payload `(room_id, session_id, screen)`.
13. **Calendar auto-add** — EventKit, per-room host toggle, default off.
14. **Multi-room UI** — top-bar dropdown, last-opened default, host-role
    affordance in room rows, session-active indicator.
15. **Brand & icon** — "The Table" app icon (locked), "The Four Seats"
    enterprise mark, warm-not-noir palette (indigo `#23264F`, amber
    `#F5A623`, coral `#FF6B5E`, cream `#F7F3E9`).
16. **Monetisation (MVP path)** — per-pack paid downloads (~$5) with free
    MVP packs; no ads; no pay-to-win currency.

## 8. Brand direction

- **Warm, not noir.** Games Room does NOT carry Felt Faction's
  finance-noir aesthetic. The icon must read as an invitation to a
  friend's place, not a casino floor.
- **Palette:** deep indigo night `#23264F`, warm amber `#F5A623`, coral
  `#FF6B5E`, cream `#F7F3E9`. Indigo+amber is the signature pairing —
  distinctive against gaming apps' neon-on-black default.
- **Shape language:** rounded rectangles and circles only. Heavy,
  confident strokes (no hairlines). No text in the app icon.
- **App icon (locked):** "The Table" — top-down game table in warm amber
  on deep indigo, four cream seat markers. A/B challenger: "The Join
  Code" (2×2 pip grid). The amber pip is the brand-wide accent device.
- **Enterprise mark:** "The Four Seats" — 2×2 grid of four rounded pips
  beside the GAMES ROOM wordmark in a rounded geometric sans with wide
  letterspacing.
- **Brand-lock:** "Games Room" = public commercialised fork. Felt
  Faction = internal private program. Separate pages, separate brand.

[Source: originals/2026-08-10-games-room-logo-concepts; originals/2026-08-10-games-room-logo-concepts-brainstorm; originals/2026-08-10-games-room-enterprise-logo-concepts; originals/2026-07-20-games-room-brand-decision]

## 9. MVP scope (small + working before expansion)

- Invite-only rooms with single-use 6-char join codes.
- Host + member roles (no tiers).
- Seasons with continuous-within / reset-at-end scoring.
- Seat deposits with refund / forfeit (no-show mechanism).
- iPad-first live scoring dashboard, host-only scoring.
- 3–4 dev-created game packs (Casino, CAH, Monopoly Deal, Pluto Chess).
- In-app store shell for packs.
- Native iOS from day 1 (iPhone + iPad, iOS 26+, SwiftUI throughout,
  no third-party UI deps).
- Internet required (live DB via Supabase). Offline cache not v1.
- Built on top of Felt Faction's tier system for invite priority.

**What carries from Felt Faction (concept-level, not code):** members +
invite tiers → host/member roles; continuous ledger; virtual currency
with no redemption; private-by-default; the deferral discipline; single
chip economy across game types; standing/leaderboard with personality;
seat deposit mechanism.

**What does NOT carry:** the Bank (loans, interest); finance-noir
aesthetic; chip-photo vision (as originally scoped — reversed 2026-07-12,
see §5.2).

**Explicit non-goals for v1:** public signup, multi-tier roles, parallel
seasons, loans/interest, pay-to-win currency, ads, community how-to
guides, cross-room social surface, persisting original scan photos.

[Source: originals/2026-07-07-games-room-mvp-scope-1c6aaa]

## 10. Non-goals (explicit, do not build)

From the MVP scope, the deferral list, and the V0.3 "what NOT to do"
list (calibration addendum, 2026-07-27):

1. **No public signup / no marketplace.** Private-by-default is a
   feature, not a limitation.
2. **No multi-tier roles.** Host/member only in v1.
3. **No parallel seasons per room.** One season, host-triggered.
4. **No loans, no interest, no Bank.** Virtual chips don't need credit.
5. **No pay-to-win.** In-game currency bought for real money violates
   chip-game integrity. (Workshopped 2026-07-06/09.)
6. **No ads.** "Apps/ads cheapen the experience" — load-bearing UX
   constraint.
7. **No community-editable how-to guides in v1.** Bundled with freemium
   decision; revisit after per-pack store is live.
8. **No community-pack submission/approval system in v1.** Catalog from
   dev team; contribution surface is v2.
9. **No cross-room user stats / no cross-room social surface in v1.**
10. **No offline-first.** Internet required; offline cache not v1.
11. **No persisting original scan photos.** Discard photo, keep hash +
    vision snapshot (disputes only).
12. **No generic abstractions in the vision path.** No `VisionService`
    protocol with one implementation, no generic "PackService" base
    class, no "Configurable" interface. (V0.3 what-NOT-to-do list.)
13. **No network vision calls in v1.** On-device only; hybrid is v2.
14. **No "smart" attribution suggestions** (e.g., "this stack belongs to
    Seat 3 based on past sessions"). Tap-to-assign only.
15. **No vision model settings panel.** Standard presets; per-room color
    map is the only override.
16. **No real-time member stack checking during play.** "App is not in
    the loop during play" is load-bearing; member in-play surfaces are
    v2.
17. **No per-hand scoring tables, no tournament/multi-table config in
    v1.** (V0.3 list.)
18. **No in-app per-room notification mute in v1.** One global channel;
    iOS system settings handle muting.
19. **No edit-history / audit trail in v1.** 30s correction indicator
    only; version history is v2.

## 11. Technical direction

- **iOS 26+ Universal (iPhone + iPad), SwiftUI throughout.** No
  third-party UI dependencies. Native only.
- **Supabase backend** (Postgres + PostgREST RPCs). Identity authority
  is `events.id` — every RPC that touches room scope derives `room_id`
  from the event, not from the caller's membership.
- **Core ML on-device vision** for the Casino pack (segmentation
  detector: background-adaptive mask, connected components, sorted merge
  into stacks, saturation-first color classification).
- **Apple Foundation Models framework** for mascot generation.
- **EventKit** for calendar auto-add (per-room host toggle, default off).
- **WidgetKit + Live Activity** for score surface (refresh budget 1 min;
  no Live Activity during play). Watch is v2.
- **Custom auth** (Supabase auth migration was the V0.2 milestone).
- **Hermes Agent / OpenCode CLI** as the dev loop.

## 12. Acceptance criteria

> gbrain contains no single global acceptance-criteria document.
> Acceptance criteria exist **per feature** in the sources below; the
> consolidated, checkable criteria are:

### 12.1 Product-level (locked, all must hold)
- AC-01 — Host labour per event ≈ 3 taps (Create, Finalize, Declare).
  Phone invisible during play. (North star §3.)
- AC-02 — One CTA per state: exactly one dominant action per
  user-role × event-state combination, in one physical slot. (Locked
  2026-07-17: "A button in the wrong moment is worse than no button".)
- AC-03 — Placement rule holds for every action: (who acts, when in
  session, how often) → placement. Withdraw on the member's own row at
  session start; Settle in the PAST section at session end; refresh is
  pull-to-refresh, never a button. (2026-07-17.)
- AC-04 — Join code: 6 chars, single-use, optimistic-lock redemption,
  "code already used" on second attempt. (Locked 2026-07-09.)
- AC-05 — No parallel seasons; no auto season creation; season end rolls
  deposit refunds/forfeitures and starts a clean seat state. (Locked
  2026-07-09.)
- AC-06 — Deposit flow: `invited → confirmed → attended (refunded)` or
  `invited → confirmed → no_show (forfeited)`; forfeited chips vanish
  (deflationary by design). (Locked 2026-07-09.)
- AC-07 — Live Activity / Watch spectator surface refreshes within
  1 minute. (Locked 2026-07-09.)
- AC-08 — Score corrections surface a "host correcting" indicator for
  ~30s and a faint dot on the affected row; no version history in v1.
  (Locked 2026-07-09.)
- AC-09 — Every RPC that touches room scope derives `room_id` from
  `events.id`, never from caller membership. (V0.24, 2026-07-21.)
- AC-10 — RPC failure modes are specified and user-visible: error
  message says what failed, why, and what to do; sheet stays open; photo
  preserved on settlement failure so the host can retry. (V0.3 addendum,
  2026-07-27.)

### 12.2 Casino vision gate (F-CAS-02, LOCKED 2026-08-10)
- AC-11 — Detection confidence ≥ 0.85 on stacks satisfying ALL:
  ≥ 4 chips per stack; centroid-to-centroid distance ≥ 25mm from any
  other stack; chips in a single contiguous polygon; lighting 200–1000
  lux diffuse (not point-source); background standard casino felt (green,
  blue, or burgundy). (V0.3 addendum, 2026-07-27.)
- AC-12 — Probe gate: **10/10** photos must pass at 0.85 confidence to
  ship. 9/10 = spec revision, not ship. (V0.3 addendum, 2026-07-27 —
  the masked-profile bias to rationalise a 1/10 failure is explicitly
  named as a trap.)
- AC-13 — F-CAS-02 locked numbers (stress corpus, 2026-08-10): recall
  0.975, precision 1.000, color accuracy 0.974, zero pure-felt false
  positives, deterministic. Known weaknesses carried: count MAE ~6
  chips, low-contrast stacks on dark felt.
- AC-14 — On-device only: no API key, no network for vision inference in
  v1. Images stay on-device; default discards the photo, keeps hash +
  vision snapshot.
- AC-15 — Per-member settlement: `record_member_scan` idempotent on
  `(session_id, member_id)`; 24h window → default `did_not_scan` row with
  amount 0; `finalize_casino_session` closes the session and rejects
  further scans; `get_session_scans` powers the host's live results
  board. (2026-07-28.)

### 12.3 Pack schema (v1)
- AC-16 — A pack is a config with: `id`, `name`, `icon`, `description`,
  `scoring_ui`, `score_compute`, `how_to`, `version`, `author_kind`.
  Dashboard renders `(room, installed_packs)`; adding a pack is a row,
  not a code change. (2026-07-09/10.)
- AC-17 — `scoring_ui` composes from dashboard primitives
  (`member_selector`, `amount_input`, `confirm_button`) + pack-defined
  layout/labels/options. Two flavours of `score_compute`: pure function
  (v1) and stateful (v2, deferred). (2026-07-09.)

### 12.4 Verification gates (repo baseline, 2026-08-10)
- AC-18 — 27/27 Foundation tests green; 24/24 SwiftUI/Services
  parse-checks green; pbxproj validator green. First Mac+Xcode build is
  the unverified moment-of-truth (xcodebuild unreachable on CLT-only
  shell).

## 13. Current state (verified 2026-08-10)

- Repo: `/Users/nathanmaxwell/Documents/VS Code/games-room`, HEAD
  `4137a82` on `main`, working tree clean.
- **V0.8 build phase done.** 21/25 vision must-haves shipped; 3 deferred
  (pack store V2, Live Activity V0.9, cloud-vision hybrid V0.9); 4
  partial (host dashboard V2, photo-persistence option, LLM mascot half,
  inline `+`).
- Verification baseline: 27/27 Foundation tests + 24/24 SwiftUI/Services
  parse-checks + pbxproj validator green. First Mac+Xcode build is the
  unverified moment-of-truth (xcodebuild unreachable on CLT-only shell).
- **F-CAS-02 LOCKED (2026-08-10):** on-device Core ML vision shippable
  (see §5.2). Known weaknesses to carry: count MAE ~6 chips,
  low-contrast stacks on dark felt.
- **Q-TONE pending:** brand voice decision brief exists (4 options,
  recommendation C quietly-wry); Nathan decides. Gates the mascot matrix
  (Wave 5) only.
- Roadmap waves: Wave 0 TestFlight upload (env-blocked, needs Mac+Xcode),
  Wave 1 Drowning privacy + decline re-entry, Wave 2 pack how-to +
  dropdown `+`, Wave 3 vision probe (DONE), Wave 4 docs drift, Wave 5
  mascot matrix (gated on Q-TONE).

## 14. Open questions — do NOT silently resolve

1. **Q-TONE (brand voice).** Nathan decides. Default if "go": ship
   existing template voice.
2. **Q-HOST-FEEDBACK.** How many host beta accounts for first TestFlight
   cycle? Default: 2–3, recruited by Nathan.
3. **Q-PRIVACY-URL.** App Store Connect needs a privacy URL before
   TestFlight upload. Default: ship `docs/privacy-policy.md` + GitHub
   Pages.
4. **Q-DROWNING-OPT-IN-DEFAULT.** Wave 1.1 opt-in column default `false`
   (privacy-respecting) or `true`? Default: `false`.
5. **Q-MONOPOLY-MULTIWINNER.** Multi-winner / split-the-pot for Monopoly
   Deal. Default: defer to V0.9.1.
6. **Q-V0.9-PUBLICITY.** TestFlight changelog post or silent iteration?
   Default: silent unless Q-TONE triggers a co-brand question.

## 15. Explicit gaps (things the brain does NOT contain)

These are the items a developer would normally expect in a vision
document that gbrain does **not** hold. Do not treat absence as a
decision:

1. **No formal user-story backlog.** The stories in §6 are derived from
   scope/spec pages, not written as stories by Nathan or Connor. If
   priorities conflict, the source spec wins.
2. **No global acceptance-criteria document.** Criteria are per-feature
   (§12 consolidates what exists). No single sign-off artifact exists.
3. **No monetisation final decision.** The matrix (§7 item 16) is
   workshopped, not locked: per-pack ~$5 is the MVP path, ads are
   rejected, freemium offerings are unpicked. Nathan/Connor decide at
   v1-readiness.
4. **Q-TONE (brand voice) undecided** — gates the full mascot matrix
   only. See §14.
5. **No legal/gambling risk assessment.** Virtual-currency-with-no-
   redemption is the assumed posture; a real legal read is deferred
   until launch-readiness (Connor flagged it, 2026-07-07).
6. **No detailed API/RPC schema in gbrain.** Lives in the repo
   (`Supabase/migrations/*.sql`). The vision doc cites contracts at the
   decision level only.
7. **No UI mockups in gbrain.** Design artifacts live in the repo
   (`.designs/`). The brain holds principles, not pixels.
8. **Real-photo vision probe WAIVED.** The planned 10-photo real-room
   validation was waived by product-owner decision (2026-08-10) with
   Felt Faction PoC accepted as evidence. Real-photo performance is
   therefore **unverified** — carry the count MAE ~6 chips / dark-felt
   weaknesses into test planning.
9. **xcodebuild / full Xcode verification pending** — environment-
   blocked (SSH to Mac Studio denied; CLT-only shell). All gates so far
   are parse/lint/test-level, not a real device build.
10. **No pricing, timeline, or staffing plan** beyond "Connor owns
    engineering, Nathan supports, MVP first" (2026-07-07).

## 16. Source index (gbrain slugs)

- `projects/games-room` — project hub
- `originals/2026-07-07-games-room-mvp-scope-1c6aaa` — canonical MVP scope
- `concepts/games-room-market-context` — market framing / why-now
- `projects/casino-pack-vision-architecture` — casino pack + vision flow
- `originals/2026-07-28-casino-pack-settlement-reversal` — per-member scan model
- `originals/2026-07-21-games-room-v024-casino-vertical-slice` — event identity / RPC contract
- `concepts/games-room-scoring-pack-schema` — pack-as-platform schema
- `concepts/2026-07-27-casino-v03-calibration-addendum` — vision acceptance gate + RPC error contract
- `concepts/2026-07-27-games-room-profile-aware-social-design` — mascot rationale
- `concepts/2026-07-27-games-room-v0-26-spec` — broadcast/briefing/calendar/preferences spec
- `concepts/2026-07-27-v06-v26-combined-greenlight` — mascot + settings greenlight
- `concepts/games-room-system-notifications` — notification architecture
- `originals/2026-07-20-games-room-brand-decision` — brand-lock (Games Room vs Felt Faction)
- `originals/2026-08-10-games-room-logo-concepts` / `-brainstorm` / `enterprise-logo-concepts` — icon + enterprise mark
- `concepts/games-room-logo-direction` — icon direction synthesis
- `wiki/originals/ideas/2026-07-17-common-sense-cta-placement-2e35f4` — placement rule
- `wiki/originals/ideas/2026-07-17-state-aware-action-block-over-button-tree-2e35f4` — single-CTA principle
- `wiki/originals/ideas/2026-07-17-action-lives-in-natural-session-moment-2e35f4` — workflow-moment placement
- `wiki/originals/ideas/2026-07-10-pack-defined-scoring-as-platform-93888e` / `-game-packs-as-rule-system-93888e` / `-pack-as-declarative-config-93888e` — pack extensibility
- `wiki/personal/reflections/2026-07-17-ui-elevation-do-better-2e35f4` — design bar
- `wiki/personal/reflections/2026-07-10-boil-the-oceans-without-criteria-93888e` — polish-loop lesson
- `inbox/2026-07-12-369a1029` / `-056564db` / `-35510a62` — Connor breakfast decisions, pack vision, architecture pivot
- `inbox/audio/2026-07-06-call-with-connor.transcript` — original call transcript
- Repo docs (not gbrain): `docs/vision.md` (37 KB full spec), `docs/plan.md`, `docs/audit.md`, `docs/casino-vision-probe-report.md`, `docs/roadmap-v0.9.md`, `IMPLEMENTATION_PLAN.md`

---

*Vision consolidated 2026-08-11 from gbrain. Build-level truth lives in
`docs/vision.md` and the kanban implementation spec; this document is the
shape, not the spec. §6 user stories and §12 acceptance criteria are
derived from the cited sources — see §15 for what the brain does not
hold.*
