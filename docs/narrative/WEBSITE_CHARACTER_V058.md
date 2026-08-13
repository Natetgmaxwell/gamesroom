# Games Room Website — Character Pass (V0.58)

> Status: canonical spec. Implements the user's directive (2026-08-14): "more quiffy, memorable, own character, not another boring website, not AI-generated slop."
> Parent: V0.57 (f6a3792, live). This pass RE-COMPOSES + RE-TYPES + REWRITES in place. Palette unchanged (dark #0A0A0B + brass #B08D57 — that part is good).

---

## 1. Diagnosis (slop audit, per claude-design skill)

Score: 3.5/10. Tells firing:
- **#3 Feature-tile grid** — every section is a card. Hero → card → card → card → card → 3 cards → card → card. Monotony by construction.
- **#8 Center stack** — one column of equal-weight boxes, no rhythm variation.
- **#9 Default type** — SF Pro Rounded + ui-serif. System defaults, nothing chosen.

The palette is good. The composition is the problem. Do NOT recolor. RE-COMPOSE and RE-TYPESET.

## 2. The four fixes

1. **Type** — self-host **Fraunces** (Google Fonts, woff2). Display serif for h1, `.serif` moments, `.arc-close`, and the two full-bleed statements. Body stays SF. Fraunces has a wonk axis — that's the hand-made character. It is NOT the AI default (Inter/Georgia/system).
2. **Composition** — break the card stack:
   - "The night dies in the thread" → **full-bleed statement section, NO card**. Big serif type on the open background.
   - "Why now" → **full-bleed statement section, NO card**.
   - "Four packs" → **slim strip, NO card**. Horizontal list, gold dots.
   - "What a season looks like" → **cardless timeline**. Beats on the open background, gold dots, hairline separators.
   - Personas stay as cards (the one place cards earn it — three people, three seats).
   - "What it is" + "Seasons" + "Mascot" stay as cards (compact, 2-up on desktop).
3. **Copy** — kill the framework tells, kill the stat-drop, inject the mascot's voice. Exact copy below.
4. **Continuity** — DELETE the duplicate "A season, in four weeks" section (lines 118–129 of current index.html). The V0.56 dotted timeline "What a season looks like" stays. Remove ALL inline styles. Fix the hero's negative-margin hack (use a proper full-bleed section wrapper instead of `margin: -1.4rem calc(-1 * var(--gutter))`).

## 3. Exact copy (verbatim — do not edit)

### Hero (keep H1, tighten lead)
- H1: `Your games night, <em>kept.</em>` (unchanged)
- Lead: `You bring the people. Games Room plans the night, keeps the scores, and stays quiet during play.` (replaces the current lead — tighter, parallel, mascot-adjacent)

### B1 — The night dies in the thread (full-bleed, no card)
- Heading: `The night dies in the <span class="serif">thread</span>.`
- Body:
  - `Every Friday, the chat scrolls on. Because of that, the night dies in the thread.`
  - `Not because nobody wanted it. Because the host had to chase RSVPs, hold the date, and keep the group from flaking. That is the whole job, and the group chat is bad at it.`
  - `Games Room takes that job off the host's hands. It plans the night, holds the seats, and gets out of the way.`
- **DELETED:** `The host is the hero. The app is the guide.` (StoryBrand jargon — AI tell)

### What it is (card, unchanged)
- `A host creates a room and shares a six-character invite code. Members join, claim seats, and RSVP. Every room is invite-only.`
- Muted: `The app is in beta and under active development. Things will shift as we find what works.`

### B2 — Why now (full-bleed, no card)
- Heading: `Why <span class="serif">now</span>`
- Body:
  - `The feed taught a generation to collect friends and keep none of them in a room. No memory, no arc, no season. Just isolated evenings that never quite became a thing.`
  - `You know the feeling: the thread goes quiet, and the night just doesn't happen.`
  - `The fix is the opposite of another feed: a small group that meets on a schedule and keeps a memory. Real tables. Real friends. No feed.`
  - `Games Room is not a calendar app. It is the counter-trend to social media: tech that gets people to the table, then gets out of the way.`
- **DELETED:** `The loneliness numbers are not subtle. Half of US adults report feeling measurably lonely, and the Surgeon General calls it a public-health epidemic.` (report-stat — breaks the voice)
- **DELETED:** `How you frame a thing changes what it is worth.` (Sutherland reference — AI tell)
- **FIXED:** `The fix is not another feed. It is the opposite:` → `The fix is the opposite of another feed:` (negative parallelism tell)

### Seasons (card, unchanged)
- `Scores carry between nights and reset when the season ends. The leaderboard tracks who actually wins across months — not just who won last Tuesday.`

### Four packs (slim strip, no card)
- Heading: `Four packs ship pre-installed`
- List: `Casino` `Cards Against Humanity` `Monopoly Deal` `Pluto Chess` (horizontal, gold dots)

### Mascot (card, unchanged)
- `Pick its personality at room-create, and it sends the reminders, narrates the night, and wraps each session in one line. Quiet, witty, on your side.`

### Who this is for (cards, keep)
- Section head: `Who this is for`
- Lead-in (REPLACES "The host is the hero. The app is the guide."): `Every room has three kinds of person in it.`
- Host card: `Three taps and the night is on. The room is set, the RSVPs are in, nobody got chased. You host because you want the night to happen, not because you want to <span class="serif">run</span> it.`
- Member card: `Your chair card has your name on it. You walk in, sit, and the night starts. No scanning for where you fit, no wondering if it is still on. The seat is <span class="serif">held</span>.`
- Quiet member card: `You read the ledger before the game. You know who is ahead and what happened last time, so you walk in already in the <span class="serif">story</span>. No performance required.`

### What a season looks like (cardless timeline, keep beats)
- Heading: `What a season looks like`
- Beats (unchanged, keep the dotted timeline treatment):
  - Week 1 — `The chair card. The first RSVP that actually <span class="serif">held</span>.`
  - Week 4 — `Someone brought chips, unprompted, because the night had become a thing.`
  - Week 8 — `The season-end award. The loser took the Drowning trophy and laughed.`
  - Week 12 — `A friend-of-friend showed up, and did not feel new.`
- Close: `The arc runs itself. The night keeps itself.`

### The night compounds (full-width statement, properly styled)
- `The night <span class="serif">compounds</span>.`
- NEW treatment: full-width, centered, Fraunces, ~1.6rem, gold serif on "compounds", generous padding above/below. NOT a floating inline-styled p. Give it a class (e.g. `.moral`).

### Trust + CTA + Footer (unchanged)
- Trust: `No ads. No analytics. No third-party SDKs. Sign in with Apple; we never see your email.`
- CTA: `Coming soon →` + `Games Room is in <strong>beta</strong>. App Store launch is on the way.`
- Footer: `"Pull up a seat. The night keeps itself."` + nav

### Mascot typewriter lines (add 2, keep 5)
- Keep: `The chips count themselves. You just sit.` / `Four seats. One table. All of you.` / `Quiet during play, chatty between nights.` / `Seasons end. Rivalries outlast them.` / `No ads, no tracking, just the night.`
- Add: `The deposit is the promise. The night is the payoff.` / `You bring the chips. It brings the memory.`

## 4. Font spec (self-host Fraunces)

- Download from Google Fonts (woff2, latin subset): weights 400, 500, 600 + italic 400. Use the `opsz` axis (9..144) and `SOFT`/`WONK` axes if available; at minimum the static instances.
- Save to `website/fonts/fraunces-*.woff2`.
- `@font-face` in style.css:
  - `--font-display: "Fraunces", ui-serif, Georgia, serif;` (replaces ui-serif)
- Apply to: `h1`, `h1 em`, `h2 .serif`, `.arc-close`, `.moral`, `.person-tag` (keep uppercase tracking), `.week` (keep uppercase tracking).
- Body font unchanged (SF system stack).
- No external CDN. Self-hosted only — matches the privacy posture.

## 5. Layout spec

- **Hero**: keep structure (icon + copy + mascot). Fix the negative-margin hack: wrap hero in a full-bleed section (`.hero` gets `width: 100vw; margin-left: calc(50% - 50vw);` or move the bleed to a parent). Keep the radial accent-wash.
- **B1 (night dies)**: full-bleed statement. No card. Big Fraunces heading (~2rem), body at 1.1rem, max-width 46ch, left-aligned on desktop, centered on mobile. Gold serif on "thread". Hairline top/bottom separators.
- **B2 (why now)**: same treatment as B1. Gold serif on "now".
- **What it is + Seasons + Mascot**: cards, 2-up on desktop (col-2), full-width on mobile. Keep.
- **Packs**: slim strip. No card. Horizontal flex row on desktop, wrap on mobile. Gold dots. Hairline top/bottom.
- **Personas**: 3-up cards on desktop (unchanged), 1-up mobile.
- **Timeline**: cardless. Beats on open background, gold dots, hairline separators between beats. Keep the `.beat` grid.
- **Moral**: `.moral` class — centered, Fraunces, 1.6rem, padding 2.5rem 0, gold serif on "compounds".
- **Trust + CTA**: unchanged.
- **Responsive**: keep the 768/1024 breakpoints. Full-bleed statements collapse to centered on mobile. Packs strip wraps. Timeline stays single column.

## 6. Verification

- Deploy via wrangler (canonical routine, whoami first, token fallback).
- Wait 60s for CF Pages cache.
- Fetch live URL: confirm (a) no "A season, in four weeks" section, (b) "The host is the hero" gone, (c) "How you frame a thing" gone, (d) "Half of US adults" gone, (e) new lead-in "Every room has three kinds of person in it." present, (f) "The night compounds." present, (g) H1 unchanged.
- Confirm fonts load (fetch one woff2 URL, 200).
- No regression: all other sections present.

## 7. Commit + return

- Commit first, deploy second. FF merge to main.
- Return: deploy URL + verification snippet + commit SHA + deviations.
