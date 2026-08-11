# Games Room — App Icon v2 (redesign round)

2026-08-10 · task t_6e2d331d · after desktop feedback: "These are pretty bad. Go back to the drawing board. Think monogram, table, gold coins, currency. Instantly recognisable from a small image. Simple. Convey the feeling and vision."

## What changed vs v1

v1 (The Table / The Open Door / The Die) was rejected: too literal, too busy, didn't read at small sizes. v2 is a full redesign around **one bold shape per icon**, heavy strokes, and the locked brand register (indigo `#23264F` + amber `#F5A623`, cream `#F7F3E9`, coral `#FF6B5E` accent).

## The four concepts

### 1. The G — monogram
Bold rounded G in amber on indigo, cream pip in the counter. The pip is the brand's smallest unit (join-code dot, notification dot) — the monogram carries the name, the pip carries the story. Reads as a letter at 29px, not a blob: the counter stays open.

### 2. The Gold Token — coin
Amber coin with cream rim, four indigo pips stamped in a 2x2 grid. The coin is the currency of game night (chips, stakes, the pot); the four pips are the four seats / the join code. One object, two stories. The rim keeps the coin from reading as a generic amber circle.

### 3. The Join Code — 2x2 pips
Four rounded pips, three amber + one coral, on indigo. The signature mechanic (join code) made iconic. Reads as a die face, a keypad, four players at a table. Simplest geometry of the set — trivially survives 29px and every appearance variant. The coral pip is the warmth: "one seat is waiting for you."

### 4. The Table v2 — table + rail
Amber table with a cream rail (the table's edge, drawn as a heavy rounded stroke), four amber seats on the rail at the cardinal points. Redesign of v1's table: the rail replaces the floating seat ticks, so the table reads as a solid object with seats attached — not four dots around a rectangle.

## Enterprise marks

Each concept has a transparent-background enterprise mark (512px PNG + SVG) — the same motif, no background, for the company logo system. Lockups (mark + GAMES ROOM wordmark in SF Rounded, wide letterspacing) in light and dark variants.

## Files

- `concept-{1-g,2-token,3-joincode,4-table}-icon.svg` — 1024x1024 masters (layered: background + foreground, ready for Icon Composer)
- `concept-{...}-{1024,180,29}.png` — renders at App Store / home screen / notification sizes
- `enterprise-{...}.svg` + `.png` — transparent enterprise marks
- `lockup-{...}-{light,dark}.svg` + `.png` — wordmark lockups
- `sheet-1024-v2.png` — contact sheet (all four at 1024)
- `sheet-small-v2.png` — contact sheet (180 + 29 per concept)
- `mock-home-v2.png` — home-screen mock: the four icons placed in a 4x5 grid among placeholder apps

## Verification (automated, all passing)

- All 1024px icons flattened RGB — no alpha, no pre-masking (HIG)
- Content centered: G (502,510) margin 152px; Token (510,510) margin 164px; Join Code (512,512) margin 259px; Table (512,512) margin 195px
- Signature colors survive 29px: amber everywhere; cream pip in The G; coral pip in The Join Code
- Enterprise marks: transparent background

## Next steps

1. Pick a direction (or A/B two) — The G and The Join Code are the strongest candidates per the research (monogram = premium/scalable; pip grid = most robust, most distinctive).
2. Build Liquid Glass layers in Icon Composer (dark/clear/tinted variants).
3. Mock a store grid against real gaming/social apps.
4. Lock the enterprise system for the winner.
5. A/B test via App Store icon experiments once in TestFlight.
