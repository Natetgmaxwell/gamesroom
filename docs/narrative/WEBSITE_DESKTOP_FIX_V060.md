# Games Room Website — Desktop Layout Fix (V0.60)

> Status: canonical spec. Fixes the desktop layout regression introduced by V0.58's full-bleed hack. User report (2026-08-14): "this app layout is worse. the layout is good for mobile, but terrible for desktop — I think it's the wrapping/flexing on the components."
> The user's hypothesis is half right: the cards are fine. The problem is the full-bleed sections.

---

## 1. Diagnosis

V0.58 shipped `.statement`, `.packs-strip`, and the hero with:

```css
width: 100vw;
margin-left: calc(50% - 50vw);
```

This breaks on desktop two ways:

1. **Uncontained content.** `.statement h2` spans the full viewport width. On 1440px+ that's a 1.9rem headline running ~1400px wide, starting at the far-left edge with only a 1.5rem gutter. Paragraphs are capped at 46ch but left-aligned at the viewport edge — text hugs the left, huge void to the right.
2. **The 100vw scrollbar trap.** `width: 100vw` includes the scrollbar width on systems with non-overlay scrollbars → horizontal overflow, page shifts sideways.

The rhythm is also jarring: full-bleed → 1120px column → full-bleed → 1120px column. The full-bleed sections look like they should contain the same column as everything else, but they don't.

## 2. The fix — full-bleed background, contained content

Pure CSS. No HTML changes. The pattern: keep the full-bleed background, constrain the content to the same 1120px column as `main`.

### 2.1 `.statement` (B1 + B2)

```css
.statement {
  width: 100%;                    /* NOT 100vw — kills the scrollbar trap */
  margin-left: 0;                 /* remove the calc hack */
  padding: 3.2rem max(calc((100vw - 1120px) / 2), var(--gutter));
  border-top: 1px solid var(--hairline);
  border-bottom: 1px solid var(--hairline);
  text-align: left;
}
.statement h2 {
  max-width: 46ch;                /* headline gets a measure too */
}
```

The `max(calc((100vw - 1120px) / 2), var(--gutter))` centers the content column at 1120px on wide screens and falls back to the 1.5rem gutter on mobile. This is the modern full-bleed-with-contained-content pattern — no wrapper div needed.

### 2.2 `.packs-strip`

```css
.packs-strip {
  width: 100%;
  margin-left: 0;
  padding: 2.2rem max(calc((100vw - 1120px) / 2), var(--gutter));
  border-top: 1px solid var(--hairline);
  border-bottom: 1px solid var(--hairline);
}
.packs-strip .packs {
  max-width: 1120px;              /* contain the flex list to the column */
}
```

### 2.3 `.hero`

Same treatment — it carries the same `100vw` hack:

```css
.hero {
  width: 100%;
  margin-left: 0;
  padding: 1.8rem max(calc((100vw - 1120px) / 2), var(--gutter)) 2.2rem;
  background: radial-gradient(120% 90% at 50% 0%, var(--accent-wash), transparent 60%);
  border-bottom: 1px solid var(--hairline);
  text-align: center;
}
```

The `.hero-inner` already centers its content; the padding change just aligns the hero's content column with the rest of the page.

### 2.4 `.moral`

Already centered and contained (it's inside `main`'s 1120px column). No change.

### 2.5 Check for other `100vw` usages

Grep `style.css` for `100vw` and `calc(50% - 50vw)` — zero remaining after the fix.

## 3. What NOT to do

- Do NOT change the card grid (`.features` at 1120px is correct).
- Do NOT change the palette, fonts, or copy.
- Do NOT add wrapper divs to the HTML — the `max()` padding pattern handles it in CSS.
- Do NOT touch the mobile layout — it's good per the user.

## 4. Verification

1. Grep `style.css` for `100vw` → zero.
2. Grep for `calc(50% - 50vw)` → zero.
3. Deploy via wrangler (whoami first, token fallback).
4. Wait 60s for CF Pages cache.
5. Fetch the live URL — confirm all sections still present, H1 unchanged.
6. **Visual check on desktop is REQUIRED if possible.** The browser harness may be blocked on a Chrome permission popup ("Allow remote debugging?") — if so, state that the visual check was not performed and the user should hard-refresh the live site at 1440px+ to confirm. Do NOT claim visual verification you didn't do.

## 5. Commit + return

- Commit first, deploy second. FF merge to main.
- Return: commit SHA + deploy URL + verification output + what was NOT verified.
