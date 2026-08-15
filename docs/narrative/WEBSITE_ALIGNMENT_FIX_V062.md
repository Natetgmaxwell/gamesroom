# Games Room Website — Full-Bleed Alignment Fix (V0.62)

> Status: canonical spec. Fixes the 24px misalignment between full-bleed sections and the card column. User report (2026-08-14): "the 'The table says' component is not aligned with the rest of the site."

---

## 1. Diagnosis (code-verified)

The hero, `.statement`, and `.packs-strip` are full-bleed (`width: 100vw; margin-left: calc(50% - 50vw)`) with content centered at **1120px**:

```css
padding: <y> max(calc((100vw - 1120px) / 2), var(--gutter)) <y>;
```

But `<main>` is `max-width: 1120px` **with 24px gutters** (`--gutter: 1.5rem`). Main's *content* box is therefore 1120 − 48 = **1072px**, starting 24px further right than the full-bleed content.

| Element | Content starts at (1440px viewport) | Content width |
|---|---|---|
| `.hero` / `.statement` / `.packs-strip` | 160px | 1120px |
| `main` cards | 184px | 1072px |
| **Offset** | **24px** | **48px** |

The mascot card (bordered box) makes the offset obvious. The H1, lead, statement text, and packs list share the same 24px offset — they're just less visible because text without a border doesn't read as misaligned.

## 2. The fix (pure CSS, one token + three selectors)

### 2.1 Add the inner-width token to `:root`

```css
:root {
  /* existing tokens... */
  --content-inner: calc(var(--maxw-desktop) - 2 * var(--gutter)); /* 1072px */
}
```

Derived from existing tokens so it can never drift from main's actual content box.

### 2.2 Update the three full-bleed selectors

```css
.hero {
  /* ...existing... */
  padding: 1.8rem max(calc((100vw - var(--content-inner)) / 2), var(--gutter)) 2.2rem;
}

.statement {
  /* ...existing... */
  padding: 3.2rem max(calc((100vw - var(--content-inner)) / 2), var(--gutter));
}

.packs-strip {
  /* ...existing... */
  padding: 2.2rem max(calc((100vw - var(--content-inner)) / 2), var(--gutter));
}
```

Math check:
- 1440px: (1440−1072)/2 = 184px → content 1072px starting at 184px = main content. ✓
- 768px: (768−1072)/2 = −152 → max(−152, 24) = 24px → content 720px starting at 24px = main content. ✓
- 375px: max(neg, 24) = 24px → content 327px = main content. ✓

## 3. What NOT to do

- Do NOT change `main`'s max-width or gutters (mobile depends on them).
- Do NOT remove the full-bleed (the bleed is the character; the alignment is the bug).
- Do NOT change the card grid, palette, fonts, or copy.
- Do NOT touch the `.mascot` component itself — it's correctly positioned inside the hero; the hero's padding is the bug.

## 4. Verification

1. Grep style.css: `--content-inner` defined in `:root`; `.hero`, `.statement`, `.packs-strip` all use `max(calc((100vw - var(--content-inner)) / 2), var(--gutter))`.
2. Deploy via wrangler (whoami first, token fallback).
3. Wait 60s for CF Pages cache.
4. Fetch live URL — all sections present, H1 unchanged.
5. Visual check at 1440px REQUIRED if possible. Browser harness may be blocked on Chrome permission popup — if so, state it and ask the user to hard-refresh to confirm the mascot now lines up with the cards. Do NOT claim visual verification you didn't do.

## 5. Commit + return

- Commit first, deploy second. FF merge to main.
- Return: commit SHA + deploy URL + verification output + what was NOT verified.
