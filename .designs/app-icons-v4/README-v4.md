# Games Room — App Icon v4 (The Table / The Join Code)

2026-08-12 · task t_a1c8b57f · after feedback: "The app icon needs some work, it still sucks."

## What changed vs v3

v3 (GR monogram "The Ring") was wired into the app but never matched the locked
vision. §8 of VISION.md locks **"The Table"** as the app icon with **"The Join
Code"** as the A/B challenger. v4 delivers exactly those two concepts.

## The two concepts

### 1. The Table (app icon — installed)
Top-down game table in warm amber on deep indigo, four cream seat markers at
the cardinal points. The table is a 560px rounded square (rx 140) — reads round
at a glance, keeps the shape language's rounded-rectangle register. Cream seats
are heavy rounded rects (150×76, rx 38) tucked onto the indigo so they stay
cream at 29px. Warm, not noir: no rails, no chips, no felt texture — just a
table waiting for four friends.

### 2. The Join Code (A/B challenger)
2×2 grid of 200px rounded pips (rx 56): three cream, one amber (bottom-right).
The amber pip is the brand-wide accent device — "one seat waiting for you."
Simplest geometry of the set; trivially survives every size and appearance
variant.

## Files

- `concept-{1-table,2-joincode}-icon.svg` — 1024×1024 masters (layered: background + foreground)
- `concept-{...}-{1024,180,120,167,152,80,76,60,40,29}.png` — full size sets
- `sheet-1024-v4.png` — contact sheet (both at 1024)

## Installed

`GamesRoom/Assets.xcassets/AppIcon.appiconset/` now contains The Table at all
nine required sizes (1024/180/120/120/80/76/152/167/29). The Join Code PNGs are
in this folder for the A/B round — swap `icon-*.png` to A/B on device.

## Verification (automated, all passing)

- All 1024px icons flattened RGB, no alpha (HIG)
- Background indigo at corners; amber + cream both present
- Content centered (bbox center within 12px of canvas center, margin ≥ 100px)
- Probe points: Table north seat cream, table center amber; Join Code TL pip
  cream, BR pip amber
- 29px color survival: amber + cream both present for both concepts
- All sizes rendered via rsvg-convert + PIL LANCZOS; dimensions confirmed via sips
- Contents.json valid JSON (python json.tool). NOTE: `plutil -lint` on this
  CLT-only host is broken for ALL JSON (rejects even `{"a":1}`); `plutil -p`
  parses the file correctly, and Contents.json is byte-identical to the
  previously shipped version.

## Next steps

1. A/B on device: install with The Table, then swap in The Join Code.
2. Liquid Glass / Icon Composer variants for the winner if desired.
3. Watch + widget icons follow once the app icon is locked.
