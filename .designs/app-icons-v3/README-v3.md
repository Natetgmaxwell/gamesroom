# Games Room — App Icon v3 (GR monogram round)

2026-08-11 · task t_6e2d331d · after desktop feedback: "None of the concepts resonate. One looks like a button, one's a weird looking G. Try something clever with the GR for games room. Some geometry tricks with letters, something that gives a little bit of intrigue."

## What changed vs v2

v2's plain G and coin were rejected. v3 drops single-letter and coin ideas entirely. Every concept is a real two-letter monogram with a geometry trick — one stroke doing double duty as part of G and part of R. Same locked register: indigo `#23264F`, amber `#F5A623`, cream `#F7F3E9`.

## The four concepts

### 1. The Ring
Full amber circle on indigo. The circle is G's body and R's bowl at once — the whole letter R is inside a G-shaped hole. Vertical stem inside the ring, full-width G bar crossing it, R leg sweeping out bottom-right. The bar crossing the circle is the moment: G on the left, R on the right, one object.

### 2. The Sweep
Open C-ring (G without the bar). The bar exits the ring's opening at the right and sweeps down and around in one continuous curve — that single stroke is G's bar, then R's leg, then a cream pip at the terminal. One line, three jobs, reads like a signature. The pip is the join-code dot.

### 3. The Spine
G and R side by side sharing one central stem. Left: C + bar (G). Right: bowl + leg (R). The shared stem is the geometry trick — at 29px it reads as a bold monogram, close up you notice both letters lean on the same pillar. The cleanest, most "logo" of the set.

### 4. The Die-R
Bold R whose bowl is a complete G: full ring for the bowl, G bar crossing it, cream pip in the counter. Stem and leg complete the R. The R is a die with a G stamped in it — the game room's two initials in one letter, with the pip as the "one seat waiting" accent.

## Files

- `concept-{1-ring,2-sweep,3-spine,4-die-r}-icon.svg` — 1024x1024 masters (layered: background + foreground, ready for Icon Composer)
- `concept-{...}-{1024,180,29}.png` — App Store / home screen / notification sizes
- `enterprise-{...}.svg` + `.png` — transparent enterprise marks (same motif, no background)
- `lockup-{...}-{light,dark}.svg` + `.png` — mark + GAMES ROOM wordmark (SF Rounded, wide tracking)
- `sheet-1024-v3.png` — contact sheet (all four at 1024)
- `sheet-small-v3.png` — contact sheet (180 + 29 per concept)
- `mock-home-v3.png` — home-screen mock: the four icons in row 3 of a 4x5 grid

## Verification (automated, all passing)

- All 1024px icons flattened RGB, no alpha, no pre-masking (HIG)
- Background indigo, content centered (margins 150–165px)
- Signature amber survives 29px and 180px for all four
- Enterprise marks: transparent background, amber strokes
- Lockups: wordmark ink rendered in both light and dark

## Next steps

1. Look at `sheet-1024-v3.png`, then `mock-home-v3.png`. My read: The Ring and The Sweep have the most intrigue (the trick is visible); The Spine is the safest; The Die-R is the most playful.
2. Pick one (or two to A/B).
3. Icon Composer Liquid Glass layers + dark/tinted variants for the winner.
4. Lock the enterprise system.
5. A/B test via App Store icon experiments once in TestFlight.
