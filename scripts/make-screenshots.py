#!/usr/bin/env python3
"""
V0.92 App Store screenshot generator.

Input: raw simulator screenshots (1320x2868 from iPhone 17 Pro Max sim).
Output: captioned PNGs at every required iPhone size in
        games-room/screenshots/iphone-6.9/, /iphone-6.5/, /iphone-5.5/.

Apple's iOS 26 SDK App Store Connect requirements:
  - 6.9" iPhone (iPhone 16 Pro Max class): 1290 x 2796 px
  - 6.5" iPhone (iPhone 11 Pro Max class): 1242 x 2688 px
  - 5.5" iPhone (iPhone 8 Plus class):    1242 x 2208 px

Each shot is:
  1. Resized to target width preserving aspect (h gets cropped a bit
     on 5.5"), then top-cropped to the exact target height.
  2. Padded with a top caption strip in the dark canvas color so the
     viewer knows which screen they're looking at (App Store reviewers
     prefer captioned shots per the V0.92 brief).

The resize preserves aspect ratio; the 6.5" / 5.5" target aspect
differs from the source, so we crop the bottom (home indicator area)
rather than stretching.
"""
from PIL import Image, ImageDraw, ImageFont
import os
import sys

# Output directories
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT_DIRS = {
    "6.9": os.path.join(ROOT, "screenshots", "iphone-6.9"),
    "6.5": os.path.join(ROOT, "screenshots", "iphone-6.5"),
    "5.5": os.path.join(ROOT, "screenshots", "iphone-5.5"),
}
for d in OUT_DIRS.values():
    os.makedirs(d, exist_ok=True)

# Target dimensions
TARGETS = {
    "6.9": (1290, 2796),
    "6.5": (1242, 2688),
    "5.5": (1242, 2208),
}

# Caption strip height as a fraction of the output height
CAPTION_FRAC = 0.085

# Brand colors (from Theme.Palette)
BACKGROUND = (8, 8, 8)            # near-black canvas (V0.88 icon base)
CAPTION_TEXT = (240, 230, 210)    # warm parchment

# Source → caption + filename stem
SOURCES = [
    {
        "src": os.path.expanduser("~/Documents/VS Code/games-room/.worktrees/t_f86ae80f/.sshot-10.png"),
        "caption": "Sign in",
        "stem": "01-signin",
    },
    {
        "src": os.path.expanduser("~/Documents/VS Code/games-room/.worktrees/t_f86ae80f/.sshot-13.png"),
        "caption": "Your rooms",
        "stem": "02-rooms",
    },
    {
        "src": os.path.expanduser("~/Documents/VS Code/games-room/.worktrees/t_f86ae80f/.sshot-14.png"),
        "caption": "Tonight's game",
        "stem": "03-casino-live",
    },
    {
        "src": os.path.expanduser("~/Documents/VS Code/games-room/.worktrees/t_f86ae80f/.sshot-11.png"),
        "caption": "Your preferences",
        "stem": "04-settings",
    },
]


def find_font(size):
    """Find a serif/sans font that ships with macOS. Falls back to PIL default."""
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


def render_one(src_path: str, caption: str, stem: str) -> None:
    img = Image.open(src_path).convert("RGB")
    src_w, src_h = img.size
    for size_key, (tw, th) in TARGETS.items():
        # Step 1 — resize preserving aspect so width matches target.
        scale = tw / src_w
        new_h = int(round(src_h * scale))
        resized = img.resize((tw, new_h), Image.LANCZOS)
        # Step 2 — top-crop to target height (preserve top content, drop
        # bottom = home indicator area + bleed).
        if new_h < th:
            # Source shorter than target — pad with background colour
            canvas = Image.new("RGB", (tw, th), BACKGROUND)
            canvas.paste(resized, (0, 0))
            base = canvas
        else:
            base = resized.crop((0, 0, tw, th))

        # Step 3 — caption strip at the top. Strip height scales with
        # the image so it reads consistently across sizes.
        cap_h = int(round(th * CAPTION_FRAC))
        out = Image.new("RGB", (tw, th), BACKGROUND)
        # Draw caption strip
        draw = ImageDraw.Draw(out)
        strip = Image.new("RGB", (tw, cap_h), BACKGROUND)
        sdraw = ImageDraw.Draw(strip)
        # Pick a font size proportional to the strip height
        font_size = int(cap_h * 0.28)
        font = find_font(font_size)
        # Centre the caption, leaving 6% horizontal padding on each side
        bbox = sdraw.textbbox((0, 0), caption, font=font)
        tw_txt = bbox[2] - bbox[0]
        th_txt = bbox[3] - bbox[1]
        max_text_width = tw - int(tw * 0.12)
        # If text overflows, shrink font iteratively
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
        # Paste the screenshot below the strip
        out.paste(base.crop((0, cap_h, tw, th)), (0, cap_h))

        out_path = os.path.join(OUT_DIRS[size_key], f"{stem}.png")
        out.save(out_path, "PNG", optimize=True)
        print(f"  wrote {out_path}  {out.size}")


def main() -> int:
    for entry in SOURCES:
        if not os.path.exists(entry["src"]):
            print(f"missing source: {entry['src']}", file=sys.stderr)
            return 1
        print(f"rendering {entry['stem']}")
        render_one(entry["src"], entry["caption"], entry["stem"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
