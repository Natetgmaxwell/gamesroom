# Games Room Website — Micro-Interaction & Hierarchy Polish (V0.65)

> Status: canonical spec. User directive (2026-08-14): "perfecting the webpage through animations and spacing between elements and the hierarchy that directs visitor attention. work on the small things, micro interactions that make the site a joy to use."
> Investigation: gbrain canon (hydrolyze-micro-interaction-system, warmth-through-motion, ui-polish-engineering-loop) + web research (NN/g 2024 fixation, staggered reveals, vertical rhythm) + live browser audit.

---

## 1. Live audit findings (browser-verified 2026-08-14)

| Property | Current | Problem |
|---|---|---|
| Reveal stagger | 9 `.reveal` elements, **all 0s delay** | Everything fades in at once per scroll — no sequence, no attention direction |
| Spacing grid | 2.4rem (38.4px), 1.4rem (22.4px), 0.9rem (14.4px), 3.2rem (51.2px)… | **Off the 4pt grid** — the polish skill's floor. Many values are 0.4–3.2px off a multiple of 4 |
| Hero entrance | None — hero appears instantly | No crafted first impression; NN/g 2024: fixation hardens after ~400ms, so the entrance must be fast and sequenced |
| Card hover | Lift + border only | The one serif word per card (the design's signature) doesn't react |
| Focus states | `:focus-visible` count = 0 | No visible focus ring on CTA/links — a11y gap AND polish gap |
| Reduced motion | CSS media query exists for `.reveal` | Typewriter JS ignores it; hero entrance would need it too |
| Moral closer | 1.6rem (25.6px) | The emotional peak of the page is smaller than the statement H2s |

## 2. The seven fixes (one consolidated CSS/JS pass)

### 2.1 Staggered reveal (the big one — attention direction)

In the reveal JS, add a per-element transition delay, capped so the page never feels slow:

```js
var revealIndex = 0;
var io = new IntersectionObserver(function (entries) {
  entries.forEach(function (e) {
    if (e.isIntersecting) {
      e.target.style.transitionDelay = Math.min(revealIndex, 4) * 60 + "ms";
      revealIndex++;
      e.target.classList.add("is-visible");
      io.unobserve(e.target);
      // Clear the delay after the reveal so hover states aren't delayed
      e.target.addEventListener("transitionend", function handler(ev) {
        if (ev.propertyName === "opacity") {
          e.target.style.transitionDelay = "";
          e.target.removeEventListener("transitionend", handler);
        }
      }, { once: true });
    }
  });
}, { threshold: 0.12 });
```

Sections reveal in sequence (0ms → 240ms max), directing the eye down the page. The delay is cleared after reveal so card hovers stay snappy.

### 2.2 4pt grid spacing pass (consolidated — the "small things")

Every value below is off-grid → on-grid. Apply ALL of them in one pass:

| Selector | Was (px) | Becomes (px) |
|---|---|---|
| `section` margin-bottom | 2.4rem (38.4) | 2.5rem (40) |
| `.features` gap | 2.4rem (38.4) | 2.5rem (40) |
| `.card` padding | 1.4rem 1.3rem (22.4/20.8) | 1.5rem 1.25rem (24/20) |
| `.card` padding ≥1024px | 1.7rem 1.6rem (27.2/25.6) | 1.75rem 1.5rem (28/24) |
| `.statement` padding | 3.2rem (51.2) | 3rem (48) |
| `.packs-strip` padding | 2.2rem (35.2) | 2.25rem (36) |
| `.hero` padding | 1.8rem … 2.2rem (28.8/35.2) | 1.75rem … 2.25rem (28/36) |
| `.hero` padding-top ≥1024px | 3rem (48) ✓ | keep |
| `.hero` padding-bottom ≥1024px | 2.6rem (41.6) | 2.5rem (40) |
| `.mascot` padding | 0.85rem 1rem (13.6/16) | 0.875rem 1rem (14/16) |
| `.beta` padding | 0.35rem 0.85rem (5.6/13.6) | 0.375rem 0.875rem (6/14) |
| `.personas` gap | 1.2rem (19.2) | 1.25rem (20) |
| `.timeline` gap | 1.1rem (17.6) | 1.25rem (20) |
| `.beat` gap | 0.7rem (11.2) | 0.75rem (12) |
| `.packs` gap | 0.6rem (9.6) | 0.75rem (12) |
| `.packs-strip .packs` gap | 0.6rem 1.8rem (9.6/28.8) | 0.75rem 1.75rem (12/28) |
| `.hero` gap | 1.6rem (25.6) | 1.5rem (24) |
| `.hero-inner` gap | 1.6rem (25.6) | 1.5rem (24) |
| `.mascot` gap | 0.7rem (11.2) | 0.75rem (12) |
| `.brand` gap | 0.8rem (12.8) | 0.75rem (12) |
| `.site-header` padding | 1.4rem … 1.1rem (22.4/17.6) | 1.5rem … 1.125rem (24/18) |
| `main` padding | 2.6rem … 4rem (41.6/64) | 2.5rem … 4rem (40/64) |
| `h1` margin-bottom | 0.9rem (14.4) | 1rem (16) |
| `.lead` margin-bottom | 1.4rem (22.4) | 1.5rem (24) |
| `h2` margin-bottom | 0.8rem (12.8) | 0.75rem (12) |
| `.card h2` margin-bottom | 0.6rem (9.6) | 0.75rem (12) |
| `p` margin-bottom | 0.9rem (14.4) | 1rem (16) |
| `.section-head` margin-bottom | 1.2rem (19.2) | 1.25rem (20) |
| `.person-tag` margin-bottom | 0.6rem (9.6) | 0.75rem (12) |
| `.timeline` margin | 0.4rem 0 1.2rem (6.4/19.2) | 0.5rem 0 1.25rem (8/20) |
| `.trust` padding-top | 1.2rem (19.2) | 1.25rem (20) |
| `.cta-wrap` margin-top | 0.6rem (9.6) | 0.75rem (12) |
| `.coming-soon` margin-top | 0.9rem (14.4) | 1rem (16) |
| `.footer-mascot` margin | 0 auto 0.8rem (12.8) | 0 auto 0.75rem (12) |
| `.site-footer` padding | 1.6rem … 2rem (25.6/32) | 1.5rem … 2rem (24/32) |
| `.packs` margin | 0.8rem 0 0 (12.8) | 0.75rem 0 0 (12) |
| `.lead-in` margin-bottom | 1.2rem (19.2) | 1.25rem (20) |
| `.cta` padding | 0.95rem 1.8rem (15.2/28.8) | 1rem 1.75rem (16/28) |

### 2.3 Hero entrance sequence (fast, sequenced, ≤600ms total)

```css
.hero-inner > *, .mascot {
  animation: hero-rise 0.4s var(--ease-spring) both;
}
.hero-inner > *:nth-child(1) { animation-delay: 0.05s; }  /* icon */
.hero-inner > *:nth-child(2) { animation-delay: 0.15s; }  /* H1 + lead */
.mascot { animation-delay: 0.25s; }                      /* mascot */

@keyframes hero-rise {
  from { opacity: 0; transform: translateY(12px); }
  to   { opacity: 1; transform: none; }
}
```

Icon → H1 → mascot. Total 650ms worst case. The H1 (the fixation point) is visible by ~550ms.

### 2.4 Card serif-word hover (micro-delight, ties to the design language)

```css
.card .serif { transition: color 0.3s ease; }
.card:hover .serif { color: var(--accent); }
```

The one serif word per card (run, held, story, arc…) warms to brass on hover. Subtle, on-brand, cheap.

### 2.5 Focus-visible (a11y + polish)

```css
.cta:focus-visible,
a:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 3px;
  border-radius: 4px;
}
```

### 2.6 Reduced-motion completeness

- CSS: add `.hero-inner > *, .mascot { animation: none; }` to the existing `@media (prefers-reduced-motion: reduce)` block.
- JS: at the top of the typewriter IIFE, check `matchMedia("(prefers-reduced-motion: reduce)")` — if true, set the first mascot line statically and skip the typewriter loop entirely.

### 2.7 Moral closer presence

```css
.moral { font-size: 1.75rem; }  /* was 1.6rem (25.6px off-grid) → 28px on-grid */
```

The emotional peak of the page gets more presence than the statement H2s' body text.

## 3. What NOT to do

- No new looping animations (the ambient trio — icon-float, dot-pulse, caret-blink — stays as-is)
- No parallax, no scroll-jacking, no heavy JS
- No new colors, fonts, or copy
- No HTML restructure
- Do NOT touch the confetti, magnetic CTA, pips, or typewriter mechanics (they're character)
- Do NOT change the palette or the full-bleed alignment (V0.64 is locked)

## 4. Verification (falsifiable checklist — browser harness REQUIRED)

1. **Stagger**: in the live page, `.reveal` elements have transition-delay 0–240ms in 60ms steps (check via JS: `[...document.querySelectorAll('.reveal')].map(r => getComputedStyle(r).transitionDelay)` after scrolling through the page).
2. **4pt grid**: grep style.css for `padding|margin|gap` values — every numeric value is a multiple of 4 (allow 0, 4, 8, 12, 16, 20, 24, 28, 32, 36, 40, 48, 56, 64).
3. **Hero entrance**: on load, `.hero-inner > *` and `.mascot` have `animation: hero-rise` with delays 0.05/0.15/0.25s.
4. **Serif hover**: `.card .serif` has `transition: color 0.3s`; `.card:hover .serif` sets accent.
5. **Focus**: `.cta:focus-visible` rule exists in CSS.
6. **Reduced motion**: `@media (prefers-reduced-motion: reduce)` contains `.hero-inner > *, .mascot { animation: none; }`; typewriter JS has the matchMedia guard.
7. **Moral**: `.moral` font-size is 1.75rem.

Deploy via wrangler (project games-room), bump the stylesheet cache-buster `?v=64` → `?v=65` in index.html (THE lesson from V0.64 — never forget the bump), wait 60s, run the checklist against the LIVE page with the browser harness, screenshot the result.

## 5. Commit + return

- Commit first, deploy second. FF merge. PUSH to origin/main.
- Return: commit SHA + deploy URL + checklist results (7/7) + screenshot path + any deviation.
