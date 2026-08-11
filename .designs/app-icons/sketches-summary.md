# Games Room — App Icon Sketches (v1)

First-pass vector sketches of all three approved concepts, rendered and verified.
Per the desktop comment ("I'm happy if you want to Sketch all three"), all three
concepts were drawn — not just the recommended one.

## What's here

`sketches/` contains:

| File | What it is |
|---|---|
| `concept-a-table-icon.svg` | Concept A — The Table. 1024×1024 master, layered for Icon Composer |
| `concept-b-door-icon.svg` | Concept B — The Open Door. 1024×1024 master, layered |
| `concept-c-die-icon.svg` | Concept C — The Die. 1024×1024 master, layered |
| `enterprise-table-mark.svg` | Enterprise mark A — table line-art with 4 seat ticks (transparent) |
| `enterprise-door-mark.svg` | Enterprise mark B — "aperture" rounded square with amber wedge |
| `enterprise-pip-mark.svg` | Enterprise mark C — the amber pip, atomic brand unit |
| `concept-*-1024.png` | 1024px renders (RGB, no alpha — App Store ready) |
| `concept-*-180.png` / `concept-*-29.png` | 180px and 29px renders (size survival check) |
| `sheet-1024.png` | Contact sheet: all three at 1024px |
| `sheet-small.png` | Contact sheet: 180px + 29px×6 for each concept |

## How each concept was drawn

- **A — The Table:** deep indigo `#23264F` background; amber `#F5A623` rounded
  table (560×360, rx 72); four cream `#F7F3E9` seat circles (r 70) at 85% opacity
  — two on the long sides, one at each end. The 85% opacity is the Liquid Glass
  depth layer: seats over indigo blend to a warm grey, seats over amber read
  cream. Composition centered, 168px margin.
- **B — The Open Door:** teal-indigo `#1E2A3A` background; coral `#FF6B5E` door
  (480×640, rx 56) with a 48px teal gap; amber light wedge at 80% opacity with a
  40px stroke aligned to the gap edge so the slit stays visible. Centered, 160px
  margin. (v1 had the wedge stroke covering the gap and a right-heavy
  composition — fixed in v2.)
- **C — The Die:** indigo background; cream squircle (600×600, rx 170 — echoes
  the iOS mask); four white pips (r 45, 90% opacity) in the corners of a five
  layout; center pip amber (r 58). Centered, 216px margin.

## Verification (automated, pixel-level)

`verify_sketches.py` checks, all passing:

- Palette: every probe point matches the intended color (including the
  opacity-blended seat and wedge values).
- No alpha: all three 1024px icons are flattened RGB (HIG: no alpha channel,
  no pre-rounded corners — the SVGs are square masters).
- Centering: content bbox center within 12px of canvas center, margin ≥ 100px
  on all sides (HIG: keep primary content centered).
- 29px survival: each icon's signature color is present at notification size.
- Enterprise marks: transparent background, correct stroke color.

## HIG compliance notes

- Square, unmasked masters — the system applies the mask.
- Layered foregrounds with defined edges and varied opacity — import the SVGs
  into Icon Composer for Liquid Glass effects.
- No text, no photos, no UI screenshots, no static effects.
- Heavy, confident forms throughout (no hairlines) — consistent with Nathan's
  established stroke-weight register.

## Next steps (design iteration)

1. Open the SVGs in Icon Composer; tune the Liquid Glass layer groups
   (specular/refraction at group level).
2. Build dark + tinted appearance variants for the top two.
3. Mock a store grid — candidates next to real gaming/social apps.
4. A/B test the top two via App Store icon experiments once in TestFlight.
5. Lock the enterprise system for the winner (horizontal + stacked +
   symbol-only + monochrome lockups, favicon at 16px).

*Sources: logo_concepts.md (t_440fd853), apple_icon_guidelines.md (t_3a368486),
app_logo_research.md (t_642401ae), games-room-logo-brainstorm.md (t_6e2d331d).*
