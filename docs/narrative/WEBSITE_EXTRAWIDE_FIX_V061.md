# Games Room Website — Extra-Wide Layout Fix (V0.61)

> Status: canonical spec. Fixes the extra-wide collapse introduced by V0.60. User report (2026-08-14): "the site's layout falls apart when the width is extra wide."

---

## 1. Diagnosis (code-verified)

V0.60 changed `.statement`, `.packs-strip`, and `.hero` to:

```css
width: 100%;                    /* removed the bleed */
margin-left: 0;
padding: 3.2rem max(calc((100vw - 1120px) / 2), var(--gutter));
```

**The bug:** these sections are INSIDE `<main>`, which is already `max-width: 1120px; margin: 0 auto`. The box is 1120px wide, but the padding is computed from the VIEWPORT:

| Viewport | Padding each side | Content width |
|---|---|---|
| 1440px | 160px | 800px (squeezed) |
| 1920px | 400px | 320px (squeezed) |
| 2560px | 720px | **−320px (collapse)** |

That's the "falls apart when extra wide."

**Why V0.58 was also wrong:** it had the bleed (`width: 100vw; margin-left: calc(50% - 50vw)`) but only gutter padding — content spanned the full viewport, uncontained.

**The correct pattern needs BOTH:** bleed the box to the viewport (so the background is full-bleed) AND use viewport-relative padding to center the content at 1120px.

## 2. The fix (pure CSS, 3 selectors)

### 2.1 `.statement`

```css
.statement {
  width: 100vw;
  margin-left: calc(50% - 50vw);
  padding: 3.2rem max(calc((100vw - 1120px) / 2), var(--gutter));
  border-top: 1px solid var(--hairline);
  border-bottom: 1px solid var(--hairline);
  text-align: left;
}
```

Math check: box bleeds to viewport width; padding centers content at 1120px. At 1920px: content = 1920 − 800 = 1120px. At 2560px: content = 2560 − 1440 = 1120px. At 375px mobile: padding = max(negative, 24px) = 24px → content = 327px. Correct at every width.

### 2.2 `.packs-strip`

```css
.packs-strip {
  width: 100vw;
  margin-left: calc(50% - 50vw);
  padding: 2.2rem max(calc((100vw - 1120px) / 2), var(--gutter));
  border-top: 1px solid var(--hairline);
  border-bottom: 1px solid var(--hairline);
}
```

### 2.3 `.hero`

```css
.hero {
  display: grid;
  gap: 1.6rem;
  width: 100vw;
  margin-left: calc(50% - 50vw);
  padding: 1.8rem max(calc((100vw - 1120px) / 2), var(--gutter)) 2.2rem;
  background:
    radial-gradient(120% 90% at 50% 0%, var(--accent-wash), transparent 60%);
  border-bottom: 1px solid var(--hairline);
  text-align: center;
}
```

### 2.4 Scrollbar trap note

`body { overflow-x: hidden; }` is already set (style.css line 67), so the 100vw scrollbar trap is masked. No change needed.

## 3. What NOT to do

- Do NOT move sections out of `<main>` (HTML restructure — unnecessary).
- Do NOT add wrapper divs.
- Do NOT change the card grid, palette, fonts, or copy.
- Do NOT touch mobile (the max() fallback handles it).

## 4. Verification

1. Grep style.css: `.statement`, `.packs-strip`, `.hero` all have `width: 100vw; margin-left: calc(50% - 50vw);` AND the `max(calc((100vw - 1120px) / 2), var(--gutter))` padding.
2. Deploy via wrangler (whoami first, token fallback).
3. Wait 60s for CF Pages cache.
4. Fetch live URL — all sections present, H1 unchanged.
5. Visual check at 1920px+ REQUIRED if possible. Browser harness may be blocked on Chrome permission popup — if so, state it and ask the user to hard-refresh at 2560px to confirm. Do NOT claim visual verification you didn't do.

## 5. Commit + return

- Commit first, deploy second. FF merge to main.
- Return: commit SHA + deploy URL + verification output + what was NOT verified.
