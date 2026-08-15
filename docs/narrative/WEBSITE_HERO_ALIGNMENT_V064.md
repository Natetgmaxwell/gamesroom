# Games Room Website — Hero/Mascot Alignment Fix (V0.64)

> Status: canonical spec. Fixes the desktop hero + mascot misalignment that survived V0.60–V0.62. User report (2026-08-14, screenshot-verified): "The table says component is not aligned with the rest of the site." The screenshot (1823×1508) shows: mascot at far-left (x≈198), H1/lead right-shifted (x≈960+), cards further right — the hero's content column is NOT aligned with the card column.

---

## 1. Diagnosis (screenshot + code-verified)

The user's screenshot proves the NEW content is live (new lead, "The night dies in the thread", "Why now" all present). The problem is layout, and it's been layout all along.

Root cause — two CSS inconsistencies between `.hero` and the other full-bleed sections:

### 1.1 Stale media-query override (THE bug)

`style.css` `@media (min-width: 1024px)` block still contains the V0.56-era rule:

```css
.hero { padding: 3rem 2.2rem 2.6rem; margin-bottom: 3.2rem; }
```

This **hardcodes** 2.2rem horizontal padding and overrides the base rule's contained-full-bleed padding:

```css
.hero { padding: 1.8rem max(calc((100vw - var(--content-inner)) / 2), var(--gutter)) 2.2rem; }
```

On desktop ≥1024px, the hero is NOT using the viewport-relative padding. The mascot (inside `.hero`) therefore sits at a different column than every `.statement` / `.packs-strip` / `.features` section.

### 1.2 Missing bleed on `.hero`

`.statement` and `.packs-strip` have:

```css
width: 100vw;
margin-left: calc(50% - 50vw);
```

`.hero` has `width: 100%; margin-left: 0;` — it is NOT full-bleed. So the hero is an 1120px island centered inside main, while the statements bleed edge-to-edge. The visual rhythm is broken and the content columns don't match.

### 1.3 Why V0.60–V0.62 didn't fix it

- V0.60 (f033a0f): removed the bleed, kept viewport padding → squeeze at width.
- V0.61 (a9a0975): restored bleed + contained padding on `.statement` and `.packs-strip`, but NOT on `.hero` (kept width:100%).
- V0.62 (c688589): changed padding to `--content-inner` on `.hero` base rule — but the ≥1024px media-query override still hardcodes `2.2rem`, so the fix never takes effect on desktop.

## 2. The fix

### 2.1 `.hero` base rule — restore the full-bleed

```css
.hero {
  display: grid;
  gap: 1.6rem;
  width: 100vw;
  margin-left: calc(50% - 50vw);
  padding: 1.8rem max(calc((100vw - var(--content-inner)) / 2), var(--gutter)) 2.2rem;
  background:
    radial-gradient(120% 90% at 50% 0%, var(--accent-wash), transparent 60%);
  border-bottom: 1px solid var(--hairline);
  text-align: center;
}
```

### 2.2 DELETE the stale ≥1024px override

Remove from `@media (min-width: 1024px)`:

```css
.hero { padding: 3rem 2.2rem 2.6rem; margin-bottom: 3.2rem; }
```

Replace with nothing (the base rule now handles it) — OR, if a desktop size bump is wanted, only adjust vertical values:

```css
.hero { padding-top: 3rem; padding-bottom: 2.6rem; }
```

(prefer the latter so the horizontal containment is never re-overridden)

### 2.3 Sweep ALL media queries for stale overrides

Grep the ENTIRE file for any other rule that touches `.hero`, `.statement`, or `.packs-strip` width / margin / padding inside `@media` blocks. Known suspects to check:
- `@media (min-width: 768px)`: `.hero { text-align: left; }` (fine), `.statement { text-align: left; }` (fine), `.statement p { margin-left: 0; margin-right: 0; }` (fine), `.mascot { margin: 0; }` (fine — keeps mascot left-aligned inside hero's content column)
- `@media (min-width: 1024px)`: the hero padding override (DELETE per 2.2)
- `@media (min-width: 1440px)`: `.hero-inner { gap: 3rem; }` / `.hero-icon { width: 150px; ... }` (fine — visual scale only)

Report every hit. Zero stale width/margin/padding overrides may remain for the three sections.

### 2.4 Alignment invariant (write it in the file header)

Add to the style.css header comment:

```
/* Alignment invariant: every full-bleed section (.hero, .statement,
   .packs-strip) uses width:100vw + margin-left:calc(50% - 50vw) +
   padding: max(calc((100vw - var(--content-inner)) / 2), var(--gutter)).
   Media queries may scale vertical padding only — never horizontal. */
```

## 3. What NOT to do

- Do NOT change `.mascot` itself — it is correctly positioned inside the hero's content column; the hero's padding/width is the bug.
- Do NOT change palette, fonts, or copy.
- Do NOT touch the features grid.
- Do NOT touch mobile layout.

## 4. Verification — MANDATORY visual this time

The last four fixes were verified by code-reading only because the browser harness was blocked. This fix MUST be seen:

1. Deploy via wrangler (project games-room), wait 60s.
2. Live-fetch: content markers present, H1 unchanged.
3. **Visual check REQUIRED.** Try the browser harness first. If Chrome's "Allow remote debugging?" popup blocks you, STOP and return `NEEDS_USER_ALLOW` — the orchestrator will have the user click Allow, then re-run the visual check. Do NOT mark done without a rendered-page check.
4. Visual acceptance at 1440px AND 2560px: mascot card left edge aligns with the features card left edge; statement text column aligns with card column; no horizontal scroll; no squeeze at 2560px.

## 5. Commit + return

- Commit first, deploy second. FF merge to main. Push to origin/main.
- Return: commit SHA + deploy URL + visual-check result (screenshot-verified or NEEDS_USER_ALLOW) + media-query sweep report.
