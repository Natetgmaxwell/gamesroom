# Games Room — Vision

> Consolidated vision for the Games Room project, retrieved from gbrain
> (2026-08-11). Every section is traceable to a canonical brain page
> (`[Source: <slug>]`). This is the *vision* — the shape of the product.
> For build-level detail see `docs/vision.md` (full spec) and the
> implementation spec in the kanban workspace (`games-room-spec.md`).
> When this document and a source disagree, the source wins.

---

## 1. What this is

An invite-only iOS app for **in-person games nights**. One host per room,
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
3. **Two roles only — Host and Member.** No tiers. Host scores alone and
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

## 6. Brand direction

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

## 7. MVP scope (small + working before expansion)

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

## 8. Technical direction

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

## 9. Current state (verified 2026-08-10)

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

## 10. Open questions — do NOT silently resolve

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

## 11. Source index (gbrain slugs)

- `projects/games-room` — project hub
- `originals/2026-07-07-games-room-mvp-scope-1c6aaa` — canonical MVP scope
- `concepts/games-room-market-context` — market framing / why-now
- `projects/casino-pack-vision-architecture` — casino pack + vision flow
- `originals/2026-07-28-casino-pack-settlement-reversal` — per-member scan model
- `originals/2026-07-21-games-room-v024-casino-vertical-slice` — event identity / RPC contract
- `concepts/games-room-scoring-pack-schema` — pack-as-platform schema
- `concepts/2026-07-27-games-room-profile-aware-social-design` — mascot rationale
- `concepts/2026-07-27-v06-v26-combined-greenlight` — mascot + settings greenlight
- `originals/2026-07-20-games-room-brand-decision` — brand-lock (Games Room vs Felt Faction)
- `originals/2026-08-10-games-room-logo-concepts` / `-brainstorm` / `enterprise-logo-concepts` — icon + enterprise mark
- `concepts/games-room-logo-direction` — icon direction synthesis
- `wiki/originals/ideas/2026-07-17-common-sense-cta-placement-2e35f4` — placement rule
- `wiki/personal/reflections/2026-07-17-ui-elevation-do-better-2e35f4` — design bar
- `inbox/2026-07-12-369a1029` / `-056564db` / `-35510a62` — Connor breakfast decisions, pack vision, architecture pivot

---

*Vision consolidated 2026-08-11 from gbrain. Build-level truth lives in
`docs/vision.md` and the kanban implementation spec; this document is the
shape, not the spec.*
