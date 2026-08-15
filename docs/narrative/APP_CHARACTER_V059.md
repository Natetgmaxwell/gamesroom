# Games Room iOS — Character Carry-Over (V0.59)

> Status: canonical spec. Carries the website's V0.58 character pass (Fraunces display type, mascot voice, no AI tells) into the iOS app. User directive (2026-08-14): "carry this tone and design into the iOS app. consistency is what makes it feel luxury and a joy to use."
> Website spec (sibling): docs/narrative/WEBSITE_CHARACTER_V058.md — read it for the voice register.

---

## 1. Diagnosis (app-side)

The app's design system is already strong:
- **Palette matches the website exactly** (same 5 hexes in Theme.Palette — #0A0A0B / #131315 / #F4EFE6 / #3D3D40 / #B08D57). Do NOT touch palette.
- **SectionCard.hero / .standard** already mirrors the website's full-bleed-vs-card rhythm. Do NOT restructure.
- **Layout tokens** are adaptive (V0.32). Do NOT touch.

The gaps (the AI tells + the missing character):
1. **Display type is `Font.system(design: .serif)`** = New York, the AI default. The website is moving to **Fraunces** (wonky, warm, hand-made). The app must bundle and use the same face.
2. **3 uppercase-tracking labels** (RoomPage.swift:372 `.tracking(1.4)`, RoomPage.swift:415 `.tracking(1.2)`, RoomDetailView.swift:3073 `.tracking(1.2)`) — editorial web typography, not iOS. Sentence case, no letter-spacing.
3. **SeasonStatCardView.swift:94** uses `.system(design: .serif)` — becomes Fraunces.
4. **Mascot line pool** — the website gained 2 new lines; the app's pool should match.
5. **Copy scan** — the website killed framework tells ("The host is the hero. The app is the guide." / "How you frame a thing changes what it is worth." / the Surgeon General stat). The app copy needs the same scan.

## 2. The five fixes

### 2.1 Bundle Fraunces (the big one)

- Download the Fraunces TTFs from the google/fonts repo (OFL licensed — free to bundle):
  - `ofl/fraunces/Fraunces[SOFT,WONK,opsz,wght].ttf` (variable font) — if the app targets iOS 16+, variable fonts work via `Font.custom("Fraunces", size:)` with the default instance.
  - Fallback: static instances `Fraunces-Regular.ttf`, `Fraunces-Italic.ttf`, `Fraunces-SemiBold.ttf` from the same repo.
- Add to the Xcode project:
  - Create `GamesRoom/Fonts/` directory, add the TTF files.
  - Add to `project.pbxproj` as resources (build phase + file references). Use the existing pattern for asset files.
  - Add `UIAppFonts` array to `Info.plist` with the font filenames.
- Verify the font name post-bundle: `Font.custom("Fraunces", size: 28)` — the PostScript name is `Fraunces` (check with `fc-scan` or the font's name table; the google/fonts variable font registers as "Fraunces" with the default axis values).

### 2.2 Theme.Typography.display → Fraunces

```swift
/// Display — Fraunces, ceremonial card chapter title (28pt).
/// Same face as the website's display serif. Wonky, warm, hand-made.
static let display = Font.custom("Fraunces", size: 28)
```

- Add a companion italic for the ceremonial moments:
```swift
/// Display italic — Fraunces italic, the "kept." / "compounds." moments.
static let displayItalic = Font.custom("Fraunces", size: 28).italic()
```
- If the variable font's default instance doesn't look right at 28pt, use the static SemiBold for display and Regular for italic.

### 2.3 Kill the tracking tells

- RoomPage.swift:372 and :415 — remove `.tracking(1.4)` / `.tracking(1.2)`. If the label is an uppercase section header, convert to sentence case (e.g. "MEMBERS" → "Members") and drop the tracking. If it's a decorative label, remove the tracking and keep the text as-is.
- RoomDetailView.swift:3073 — same treatment.
- Grep the whole Views/ tree for `.tracking(` after the fix — zero remaining.

### 2.4 SeasonStatCardView serif → Fraunces

- Line 94: `.font(.system(size: 14, weight: .regular, design: .serif))` → `.font(Theme.Typography.displayItalic)` scaled down, or `Font.custom("Fraunces", size: 14)`. Match the stat card's existing hierarchy — the serif moment there is the "Good Sport" / award name treatment.

### 2.5 Mascot line pool + copy scan

- Find the mascot line pool (MascotBubble.swift or wherever the typewriter/rotating lines live). Add the 2 new website lines:
  - "The deposit is the promise. The night is the payoff."
  - "You bring the chips. It brings the memory."
- Copy scan: grep Views/ for the framework tells and stat-drops:
  - "The host is the hero" / "the app is the guide" — should not exist in app copy (the app speaks to the host directly, no third-person framework talk).
  - "How you frame a thing" — should not exist.
  - "Half of US adults" / "Surgeon General" — should not exist in app copy (the app is not a landing page; the loneliness stat belongs to the website's "Why now" section only).
  - Any "measurably lonely" phrasing — same.
- If found, rewrite in the mascot voice (short, warm, specific). If not found, note "clean" in the return.

## 3. What NOT to do

- Do NOT touch the palette.
- Do NOT restructure SectionCard / the state-driven hero rotation.
- Do NOT change the layout tokens.
- Do NOT add Fraunces to body text — display moments only (same discipline as the website).
- Do NOT add new components to Theme.swift (locked rule).
- Do NOT change the mascot's personality system (MascotPersonality / MascotPoliticalIdeology stay).

## 4. Verification

1. `xcrun swiftc -parse` on every modified Swift file → exit 0.
2. Font files exist in `GamesRoom/Fonts/` and are referenced in `project.pbxproj` (grep for the filenames).
3. `Info.plist` has `UIAppFonts` with the font filenames.
4. Grep `Views/` for `.tracking(` → zero.
5. Grep `Views/` for the framework tells → zero (or documented as clean).
6. Grep for `design: .serif` → zero (all replaced with Fraunces).
7. If Xcode is available on this Mac: build the app target, confirm no font-loading warnings. If not available, state exactly what was not verified (per the V0.53 ImageRenderer precedent — a manual Xcode pass may be needed).
8. Commit per logical step (font bundle → Theme → tracking → stat card → mascot/copy). One commit per step, user steers between.

## 5. Commit + return

- FF merge to main.
- Return: commit SHAs + verification output + what was NOT verified (Xcode build? simulator screenshot?).
