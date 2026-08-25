#!/usr/bin/env python3
"""
V0.97+ App Store screenshot generator — dual-set pipeline.

Reads raw simulator screenshots (iPhone 17 Pro Max sim, 1320x2868,
and iPad Pro 13" M5 sim, 2064x2752) and writes TWO parallel output
sets to every required size:

  screenshots/<size>/<NN>-<surface>.png       — captioned working
                                                 artifact (orchestrator
                                                 + reviewer use)
  screenshots/upload/<size>/<NN>-<surface>.png — caption-strip-stripped
                                                 upload set for App
                                                 Store Connect

Apple's iOS 26/27 SDK App Store Connect requirements:
  - 6.9" iPhone (iPhone 17 Pro Max class): 1290 x 2796 px
  - 6.5" iPhone (iPhone 11 Pro Max class): 1242 x 2688 px
  - 5.5" iPhone (iPhone 8 Plus class):    1242 x 2208 px
  - 13"  iPad  (iPad Pro 13" M5 class):   2064 x 2752 px

App Store Connect REJECTS screenshots with baked-in overlays (the
brand-background caption strip is technically an overlay). The dual
set keeps the captioned PNGs as our working artifact (orchestrator +
reviewers can read which surface is which) and emits a clean,
caption-free upload set ready for ASC drag-and-drop.

The iPhone source is 1320x2868, slightly larger than the 6.9" target —
we crop the bottom (home indicator) area. The iPad source is captured
at the exact 13" spec size, so the iPad path is a 1:1 resize.

The six source surfaces (per app-store-metadata.md):
  01-create-room     — onboarding hero / empty rooms list
  02-briefing-slot   — seat grid + Claim seat / Can't make it
  03-witness-slot    — Casino pack's at-play witness screen
  04-ceremonial-card — post-play chapter title + delta (MEMBER view)
  05-awards-card     — season-end Privacy-aware awards
  06-settings-sheet  — App settings sheet
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
UPLOAD_DIRS = {
    key: os.path.join(ROOT, "screenshots", "upload", key)
    for key in OUT_DIRS
}
for d in list(OUT_DIRS.values()) + list(UPLOAD_DIRS.values()):
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


def resize_to_target(src_path: str, tw: int, th: int) -> Image.Image:
    """Resize `src_path` to exactly (tw, th) preserving aspect by
    cropping from the bottom (the iPhone source has a slight extra
    home-indicator row we trim). Returns an RGB PIL.Image."""
    img = Image.open(src_path).convert("RGB")
    src_w, src_h = img.size
    scale = tw / src_w
    new_h = int(round(src_h * scale))
    resized = img.resize((tw, new_h), Image.LANCZOS)
    if new_h < th:
        canvas = Image.new("RGB", (tw, th), BACKGROUND)
        canvas.paste(resized, (0, 0))
        return canvas
    return resized.crop((0, 0, tw, th))


def make_caption_strip(tw: int, cap_h: int, caption: str) -> Image.Image:
    """Render the brand-background caption strip on its own image.
    Used only by the captioned (working artifact) set."""
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
    return strip


def render_captioned(base: Image.Image, caption: str, target_key: str) -> Image.Image:
    """Working artifact: paste the caption strip on top of the
    resized capture. Goes to screenshots/<size>/<NN>-<surface>.png."""
    tw, th = base.size
    cap_h = int(round(th * CAPTION_FRAC[target_key]))
    strip = make_caption_strip(tw, cap_h, caption)
    out = Image.new("RGB", (tw, th), BACKGROUND)
    out.paste(strip, (0, 0))
    out.paste(base.crop((0, cap_h, tw, th)), (0, cap_h))
    return out


def render_one(target_key: str, entry: dict) -> None:
    """Render both the captioned working artifact and the clean
    upload set for one surface at one target size."""
    src = (entry["ipad_src"]
           if target_key == "ipad-13"
           else entry["iphone_src"])
    if not os.path.exists(src):
        print(f"missing source for {target_key}: {src}", file=sys.stderr)
        sys.exit(1)
    tw, th = TARGETS[target_key]
    base = resize_to_target(src, tw, th)

    # 1. Captioned working artifact → screenshots/<size>/<stem>.png
    captioned = render_captioned(base, entry["caption"], target_key)
    captioned_path = os.path.join(OUT_DIRS[target_key], f"{entry['stem']}.png")
    captioned.save(captioned_path, "PNG", optimize=True)
    print(f"  captioned {captioned_path}  {captioned.size}")

    # 2. Clean upload set → screenshots/upload/<size>/<stem>.png
    # No caption strip, no overlays, exact (tw, th). RGB only —
    # App Store Connect rejects alpha-channel screenshots.
    upload = Image.new("RGB", (tw, th), BACKGROUND)
    upload.paste(base, (0, 0))
    upload_path = os.path.join(UPLOAD_DIRS[target_key], f"{entry['stem']}.png")
    upload.save(upload_path, "PNG", optimize=True)
    print(f"  upload    {upload_path}  {upload.size}")


def main() -> int:
    for entry in SOURCES:
        print(f"rendering {entry['stem']}")
        for target_key in TARGETS:
            render_one(target_key, entry)
    return 0


if __name__ == "__main__":
    sys.exit(main())
