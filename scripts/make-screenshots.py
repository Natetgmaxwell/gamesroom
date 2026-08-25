#!/usr/bin/env python3
"""
V0.97+ App Store screenshot generator.

Reads raw simulator screenshots (iPhone 17 Pro Max sim,
1320x2868, and iPad Pro 13" M5 sim, 2064x2752) and writes
captioned PNGs at every required size under
games-room/screenshots/iphone-6.9/, /iphone-6.5/,
/iphone-5.5/, and /ipad-13/.

Apple's iOS 26/27 SDK App Store Connect requirements:
  - 6.9" iPhone (iPhone 17 Pro Max class): 1290 x 2796 px
  - 6.5" iPhone (iPhone 11 Pro Max class): 1242 x 2688 px
  - 5.5" iPhone (iPhone 8 Plus class):    1242 x 2208 px
  - 13"  iPad  (iPad Pro 13" M5 class):   2064 x 2752 px

The iPhone source is 1320x2868, slightly larger than the
6.9" target — we crop the bottom (home indicator) area.
The iPad source is captured at the exact 13" spec size, so
the iPad path is a 1:1 resize + caption strip on top.

The six source surfaces (per app-store-metadata.md):
  01-create-room    — onboarding hero / empty rooms list
  02-briefing-slot  — seat grid + Claim seat / Can't make it
  03-witness-slot   — Casino pack's at-play witness screen
  04-ceremonial-card — post-play chapter title + delta
  05-awards-card    — season-end Privacy-aware awards
  06-settings-sheet — App settings sheet
"""
from PIL import Image, ImageDraw, ImageFont  # type: ignore[attr-defined]
import os
import sys

# Output directories
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIRS = {
    "iphone-6.9": os.path.join(ROOT, "screenshots", "iphone-6.9"),
    "iphone-6.5": os.path.join(ROOT, "screenshots", "iphone-6.5"),
    "iphone-5.5": os.path.join(ROOT, "screenshots", "iphone-5.5"),
    "ipad-13":    os.path.join(ROOT, "screenshots", "ipad-13"),
}
for d in OUT_DIRS.values():
    os.makedirs(d, exist_ok=True)

# Target dimensions
TARGETS = {
    "iphone-6.9": (1290, 2796),
    "iphone-6.5": (1242, 2688),
    "iphone-5.5": (1242, 2208),
    "ipad-13":    (2064, 2752),
}

# Caption strip height as a fraction of the output height.
# iPad gets a thinner strip — its columns are wider, so a
# larger caption would visually fight the room-detail column.
CAPTION_FRAC = {
    "iphone-6.9": 0.085,
    "iphone-6.5": 0.085,
    "iphone-5.5": 0.085,
    "ipad-13":    0.055,
}

# Brand colors — captured from Theme.Palette in GamesRoom/Theme.swift
# (background=#0A0A0B, accent=#B08D57). The brief's V0.8 "indigo +
# amber + cream" palette is the documented aspirational register; the
# actual production theme is the near-black + brass pair the
# captures show. The caption strip matches the canvas so the App
# Store Connect screenshot matches the production UI.
BACKGROUND = (10, 10, 11)           # Theme.Palette.background ≈ #0A0A0B
CAPTION_TEXT = (240, 230, 210)      # warm parchment

# Source → caption + filename stem. Six sources per device class.
# Reads from the input root (default: $REPO/.worktrees/captures/
# when run by the screenshot pipeline; falls back to a sibling
# `raw/` folder next to `screenshots/` for one-off regeneration).
IPHONE_RAW = os.environ.get(
    "IPHONE_RAW",
    os.path.join(ROOT, "screenshots", "raw", "iphone")
)
IPAD_RAW = os.environ.get(
    "IPAD_RAW",
    os.path.join(ROOT, "screenshots", "raw", "ipad")
)

SOURCES = [
    {
        "iphone_src": os.path.join(IPHONE_RAW, "01-create.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "01-create.png"),
        "caption":    "Create room",
        "stem":       "01-create-room",
    },
    {
        "iphone_src": os.path.join(IPHONE_RAW, "02-briefing.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "02-briefing.png"),
        "caption":    "Briefing slot",
        "stem":       "02-briefing-slot",
    },
    {
        "iphone_src": os.path.join(IPHONE_RAW, "03-witness.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "03-witness.png"),
        "caption":    "Witness slot",
        "stem":       "03-witness-slot",
    },
    {
        "iphone_src": os.path.join(IPHONE_RAW, "04-ceremonial.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "04-ceremonial.png"),
        "caption":    "Ceremonial card",
        "stem":       "04-ceremonial-card",
    },
    {
        "iphone_src": os.path.join(IPHONE_RAW, "05-awards.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "05-awards.png"),
        "caption":    "Awards card",
        "stem":       "05-awards-card",
    },
    {
        "iphone_src": os.path.join(IPHONE_RAW, "06-settings.png"),
        "ipad_src":   os.path.join(IPAD_RAW,   "06-settings.png"),
        "caption":    "Settings",
        "stem":       "06-settings-sheet",
    },
]


def find_font(size):
    """Find a serif/sans font that ships with macOS. Fraunces is the
    V0.8 display font; fall back to system serifs / Helvetica."""
    candidates = [
        "/System/Library/Fonts/Supplemental/Fraunces-Regular.ttf",
        "/System/Library/Fonts/Supplemental/Fraunces-Italic.ttf",
        "/Library/Fonts/Fraunces-Regular.ttf",
        "/Library/Fonts/Arial.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for c in candidates:
        if os.path.exists(c):
            try:
                return ImageFont.truetype(c, size)
            except Exception:
                continue
    return ImageFont.load_default()


def render_one(src_path: str, caption: str, stem: str, target_key: str) -> None:
    img = Image.open(src_path).convert("RGB")
    src_w, src_h = img.size
    tw, th = TARGETS[target_key]
    cap_h = int(round(th * CAPTION_FRAC[target_key]))

    # Resize preserving aspect so width matches target. iPhone source
    # (1320x2868) is slightly wider than 6.9" target — we resize to
    # the target width and crop from the bottom. iPad source (2064x2752)
    # is the exact target — we still resize for safety but expect a
    # near-1:1.
    scale = tw / src_w
    new_h = int(round(src_h * scale))
    resized = img.resize((tw, new_h), Image.LANCZOS)
    if new_h < th:
        # Source shorter than target — pad with background colour.
        canvas = Image.new("RGB", (tw, th), BACKGROUND)
        canvas.paste(resized, (0, 0))
        base = canvas
    else:
        base = resized.crop((0, 0, tw, th))

    # Add the caption strip at the top with the caption text.
    out = Image.new("RGB", (tw, th), BACKGROUND)
    draw = ImageDraw.Draw(out)
    strip = Image.new("RGB", (tw, cap_h), BACKGROUND)
    sdraw = ImageDraw.Draw(strip)
    font_size = int(cap_h * 0.42)
    font = find_font(font_size)
    bbox = sdraw.textbbox((0, 0), caption, font=font)
    tw_txt = bbox[2] - bbox[0]
    th_txt = bbox[3] - bbox[1]
    max_text_width = tw - int(tw * 0.12)
    while tw_txt > max_text_width and font_size > 14:
        font_size -= 2
        font = find_font(font_size)
        bbox = sdraw.textbbox((0, 0), caption, font=font)
        tw_txt = bbox[2] - bbox[0]
        th_txt = bbox[3] - bbox[1]
    sdraw.text(
        ((tw - tw_txt) / 2, (cap_h - th_txt) / 2 - bbox[1]),
        caption,
        font=font,
        fill=CAPTION_TEXT,
    )
    out.paste(strip, (0, 0))
    # Paste the screenshot below the strip.
    out.paste(base.crop((0, cap_h, tw, th)), (0, cap_h))

    out_path = os.path.join(OUT_DIRS[target_key], f"{stem}.png")
    out.save(out_path, "PNG", optimize=True)
    print(f"  wrote {out_path}  {out.size}")


def main() -> int:
    for entry in SOURCES:
        for target_key in TARGETS:
            src = (entry["ipad_src"]
                   if target_key == "ipad-13"
                   else entry["iphone_src"])
            if not os.path.exists(src):
                print(f"missing source for {target_key}: {src}", file=sys.stderr)
                return 1
        print(f"rendering {entry['stem']}")
        for target_key in TARGETS:
            src = (entry["ipad_src"]
                   if target_key == "ipad-13"
                   else entry["iphone_src"])
            render_one(src, entry["caption"], entry["stem"], target_key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
