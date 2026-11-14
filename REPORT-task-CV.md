---
type: research
title: "Task CV — where casino is hidden, and what a member sees"
created: 2026-11-14
tags:
  - task-cv
  - casino
  - packs
  - visibility
  - facts
related:
  - '[[GamesRoom]]'
  - '[[PackRegistry]]'
  - '[[NextNightOffer]]'
  - '[[BriefingSlot]]'
  - '[[AddEventSheet]]'
---

# Task CV — where casino is hidden

**Lane:** `cc/casino-visible` (base `6ecea667`) · **Step:** CV1 (facts) · **Date:** 2026-11-14

Nathan, 2026-11-13: *"I'm thinking that we should list the casino games in the 'what are you
playing' section when creating a new event, so it gives the members an idea into what's going to
be played on the night."*

Every night already IS a casino night — `save()` files `casino` first on every event, and the
server / older builds read the first slug as the headline `pack_slug`. This lane changes **no
scoring, no save semantics, no data model**. It only makes the existing truth visible.

This document is the CV1 deliverable: an exhaustive, line-anchored inventory of every site
that filters or hides `casino` / `CasinoPack.slug`, and every surface that shows a pack name to
a human. CV2/CV3/CV4 implement against this list.

---

## 0. The headline finding (read this first)

**The brief's premise is half true.**

| Claim in the brief | Verdict |
| --- | --- |
| "the host's picker filters casino out" | **TRUE** — one filter, `AddEventSheet.swift:245`. |
| "member-facing renders filter it out" | **FALSE** — no member-facing surface renders the night's packs **at all**, so none of them filter casino. There is nothing to un-hide; the pack list does not exist yet on the member side. |

So the lane has two halves and they are not the same shape:

1. **The picker** hides casino behind a one-line filter. Removing it is the fix Nathan asked for.
2. **The member-facing side** is *silent*, not *filtered*. Making casino visible "in what members
   see" therefore means **adding the night's games to the member event card** (the briefing slot),
   with casino first — not un-filtering an existing list. See §5 for the proposal, and the
   reasoning that makes it the only reading that satisfies Nathan's rationale clause.

Everything else in the app that shows a pack name already shows casino — those are listed in
§3 as **DOUBLE (leave alone)**.

---

## 1. Every site that filters or hides `casino` / `CasinoPack.slug`

Greps run: `CasinoPack.slug`, `!= .*casino`, `"casino"`, `chips` across `GamesRoom/Views`,
`GamesRoom/Models`, `GamesRoom/Packs`, `GamesRoom/Services`, `Supabase/`, `main.swift`,
`Tests*.swift`, `GamesRoomUITests/`.

| # | Site | Code | Who sees it | Verdict |
| --- | --- | --- | --- | --- |
| F1 | **Picker catalog** | `GamesRoom/Views/AddEventSheet.swift:245` — `PackRegistry.shared.allPacks.filter { $0.slug != CasinoPack.slug }` | Host (new-event sheet) | **HIDE → REMOVE (CV2)** |
| F2 | **Picker seed filter** | `GamesRoom/Views/AddEventSheet.swift:91-93` — `initialPackSlugs.filter { $0 != CasinoPack.slug && PackRegistry.shared.isRegistered(slug: $0) }` | Host (new-event sheet) | **KEEP** — it is the dedupe guard, not a display filter. See §4.1 |
| F3 | **Save-time prepend** | `GamesRoom/Views/AddEventSheet.swift:284` — `[CasinoPack.slug] + self.packSlugs.filter { $0 != CasinoPack.slug }` | — | **KEEP EXACTLY AS IS** (brief) — files casino first, dedupes |
| F4 | **Next-night offer** | `GamesRoom/Models/NextNight.swift:84-89` — `[chips] + settled.packSlugs.filter { $0 != chips && … isRegistered }` | Host (one-tap booking) | **DOUBLE** — casino already first. Leave, list |
| F5 | **Registry ordering** | `GamesRoom/Packs/PackRegistry.swift:43-47` — `defaultPacks = [CasinoPack.self, CardsAgainstHumanityPack.self, MonopolyDealPack.self]` | — | **KEEP** — casino is already first in the catalog; this is the ordering F1 was hiding |
| F6 | **Registry win points** | `GamesRoom/Packs/PackRegistry.swift:72` — `case CasinoPack.slug: return 0` | — | **KEEP** — scoring, not display |
| F7 | **Event decode default** | `GamesRoom/Models/Event.swift:130`, `:145`, `:166` — `packSlug = "casino"` / `packSlugs = packSlugs.isEmpty ? [packSlug] : packSlugs` | — | **KEEP** — data default, not a display filter |
| F8 | **Calendar fallback** | `GamesRoom/Services/RoomService.swift:1059` — `packSlug: packSlugs.first ?? "casino"` | — | **KEEP** — data default |
| F9 | **Room-pack defaults** | `GamesRoom/Services/InMemoryRoomStore.swift:114-118` — `defaultInstalledPacks = ["casino", "cards_against_humanity", "monopoly_deal"]` | — | **KEEP** — casino already installed in every room |
| F10 | **Scoring-type slug map** | `GamesRoom/Packs/PackScoring.swift:125` — `case .withdrawReturn: return "casino"` | — | **KEEP** — scoring contract |
| F11 | **How-to catalog** | `GamesRoom/Packs/PackHowTo.swift:73` — `"casino": PackHowTo(…)` | Host (pack how-to) | **DOUBLE** — casino has bundled how-to content. Leave, list |

**Exactly one filter hides casino from a human: F1.** (F2 hides it from the *tick set*, which is
the same thing mechanically but has a different job — §4.1.)

---

## 2. Every surface that shows a pack name to a human

| # | Surface | File:line | Audience | Shows casino today? |
| --- | --- | --- | --- | --- |
| S1 | "What are you playing?" picker rows | `GamesRoom/Views/AddEventSheet.swift:114-129` (rows), `:244-248` (catalog) | Host | **No** — filtered by F1 |
| S2 | Room settings → "Packs" toggles | `GamesRoom/Views/RoomSettingsSheet.swift:1198-1236` | Host (room settings) | **Yes** — `PackRegistry.shared.allPacks`, unfiltered |
| S3 | Pack store → "Available packs" | `GamesRoom/Views/PackStoreView.swift:28-30`, `:35`, `:65-95` | Host (reachable from room settings) | **Yes** — unfiltered |
| S4 | Pack how-to detail | `GamesRoom/Views/PackDetailView.swift` | Whoever taps a pack (reached from S2/S3) | **Yes** — casino has content (F11) |
| S5 | **Member event card (briefing slot)** | `GamesRoom/Views/RoomDetailView.swift:2320` (`private struct BriefingSlot`), used at `:990`, `:1009`, `:1036` | **Member** | **No pack list at all** — see §3 |
| S6 | Live / witness card | `GamesRoom/Views/RoomDetailView.swift:2014` (`liveCard` → `WitnessSlot`) | Member + host | **No pack list** |
| S7 | Recap card | `GamesRoom/Views/RoomDetailView.swift:2099` (`recapCard` → `CeremonialCard`) | Member + host | **No pack list** |
| S8 | Next-night offer ("Same time next Tuesday?") | `GamesRoom/Models/NextNight.swift:73-97` | Host | **Yes — casino first** (F4) |
| S9 | Room page night caption | `GamesRoom/Views/RoomPage.swift:673-681` | Member | No packs |
| S10 | Calendar entry | `GamesRoom/Services/CalendarService.swift:118-120` | Member | No packs |
| S11 | Push / mascot bodies | `GamesRoom/Services/MascotEngine.swift` | Member | No packs |

Only **S1** filters casino. S2, S3, S4, S8 already show it — leave them alone and note them
(STOP-AND-REPORT: "a render site where showing casino would DOUBLE it").

---

## 3. The member-facing gap (the important finding)

`BriefingSlot` (`GamesRoom/Views/RoomDetailView.swift:2320`) is the hero card every member sees
before a night — `.upcoming`, `.claimed` and `.declined` all render it (`RoomDetailView.swift:990`,
`:1009`, `:1036`). Its header block (`:2472-2506`) renders exactly:

- the event name,
- the relative date + the clock,
- the venue,
- "Hosted by …".

Then the host's note (`:2509-2513`), the seat grid, and the claim/decline actions. **No pack
name appears anywhere on it.** The same is true of the live card (S6) and the recap card (S7).

The member learns what is being played **only** from the free-text "Note for the table"
(`AddEventSheet.swift:159-174`) that the host has to remember to type. That is the gap Nathan
names: *"so it gives the members an idea into what's going to be played on the night."*

**Consequence for CV3:** there is no member-facing list to un-filter. The honest implementation is
to **add** the night's games to the member card, casino first, styled like any other pack
(no special chrome) — the same shape the picker gets in CV2. The alternative reading ("do
nothing on the member side, because no filter exists") would satisfy the letter of the brief and
leave the lane title — *"make Casino visible — in the picker and in what members see"* — false.

---

## 4. Per-site notes for CV2 / CV3

### 4.1 The picker's two filters (F1, F2) — which is which

- **F1 (`availablePacks`, `:245`) must go.** Without it, `PackRegistry.shared.allPacks` yields
  `[casino, cards_against_humanity, monopoly_deal]` — **casino already first** (F5), so removing
  the filter yields the required order for free, with no re-sorting.
- **F2 (`initialPackSlugs`, `:91-93`) stays, and it still serves the dedupe.** `NextNightOffer`
  hands the picker `["casino", "monopoly_deal"]` (`NextNight.swift:84-89`, and
  `RoomDetailView.swift:2128` / `:2313` pass it in). If the seed filter were dropped, `packSlugs`
  would start with `casino` in it, and the picker's tick state would own a slug that is *not*
  toggleable — the state and the row would disagree. Keeping F2 means: **the row list shows
  casino; the tick state never contains casino; `save()` owns the casino slug** (F3, untouched).
  `togglePack` gets a guard so the casino row cannot be unticked even if it is tapped.
  *Recorded here because the brief asks for the reason whenever a filter is kept.*

### 4.2 The member-facing row (CV3 proposal)

Proposed shape on the briefing card's header block, under the venue:

```
Casino · Monopoly Deal
```

- Rendered from the event's own `packSlugs` (`GamesRoom/Models/Event.swift:71`), so it is the
  night that was booked, not a static list.
- **Casino first, always** — it is the headline slug and every night is a casino night.
  `NextNightOffer.offer` (`NextNight.swift:84-89`) already applies exactly this rule, so the
  house rule exists once and the new render copies it; §5 says how to make it literally one copy.
- **Styled like the other packs, no special chrome** — same caption typography as the venue /
  "Hosted by" line, no chip icon, no accent colour, no "always on" badge.
- Copy is a *new* string, so no sweep assertion breaks (§6).

### 4.3 Where the pure rule lives (so the test can pin it)

The Foundation runner only compiles `GamesRoom/Models/*.swift` + `GamesRoom/Packs/*.swift`
(`build-and-run-tests.sh:22-60`), so a Foundation test can only pin a rule that lives there.
Within the brief's allowed files, the only Models file is `GamesRoom/Models/NextNight.swift` —
which is already the owner of the "casino first" rule (`NextNightOffer.offer`). Proposal: put the
shared rule there as a small pure type, and have `NextNightOffer.offer` call it, so there is
**one** copy of "casino first" rather than three (F3 in `save()` stays because the brief says
keep `save()` exactly as is; it is the *write* order, the new type is the *display* order).

---

## 5. Comments that state the old rule (rewritten in CV2 — see §8)

| File:line | Old rule as written | New rule |
| --- | --- | --- |
| `GamesRoom/Views/AddEventSheet.swift:69-71` | "Every night is scored in chips, so **the casino pack is not offered here**; `save()` always files it first (it is the headline `pack_slug` the server and older builds read)." | Casino is **always on and now visible**: the row is pre-ticked and cannot be unticked, because every night is scored in chips. The tick never decided anything — `save()` files the slug either way. |
| `GamesRoom/Views/AddEventSheet.swift:85-86` | "**Chips are never listed here**; `save()` files them first either way." | Casino is listed here, first, always on: the label informs, the save semantics never depended on the tick. |
| `GamesRoom/Views/AddEventSheet.swift:282-283` (save) | "Chips first, always: the casino pack is how every night is scored, and the first slug is the event's headline pack." | **Already true** — keep. |
| `GamesRoom/Packs/PackDefinition.swift:19-20` | "the picker only surfaces the conformers" | Still true (casino is a conformer). No change. |
| `GamesRoom/Packs/PackRegistry.swift:12-16` | "so the AddEventSheet picker can submit the slug" | Still true. No change. |

---

## 6. Test surfaces (for CV4)

| Surface | Where | Encodes the old rule? | Action |
| --- | --- | --- | --- |
| Registry catalog order | `main.swift:148-151` — asserts `["casino", "cards_against_humanity", "monopoly_deal"]` | **No** — already asserts casino first. | Keep; extend the new case file to pin the picker shape on top of it |
| Next-night pack list | `TestsNextNight.swift:111`, `:137` — `offer.packSlugs == ["casino", "monopoly_deal"]` | **No** — already casino-first. | Keep |
| Picker option count / contents | `GamesRoomUITests/ScreenshotSweepTests.swift` | **No** — the sweep never opens the new-event sheet's pack section and never asserts a pack name or an option count. | Nothing to repoint. New picker shape is **UI-testable only** → noted here for the orchestrator's sweep |
| Member card pack list | — | Does not exist yet | New Foundation case (pure rule) + UI note |

**No Foundation test encodes "casino is absent from the picker"** — there is nothing to delete or
repoint on that side. The new Foundation case will pin: (a) the picker row list contains casino
**first**, and (b) the member-facing pack list contains casino **first**.

---

## 7. Open questions / stop-and-report notes

1. **DOUBLE sites, left alone and listed:** S2 (`RoomSettingsSheet.swift:1198`), S3
   (`PackStoreView.swift:28`), S4 (`PackDetailView.swift`), S8 (`NextNight.swift:84`), F11
   (`PackHowTo.swift:73`). None of them filters casino.
2. **`initialPackSlugs` callers depend on the casino filter for correctness, not display?**
   Checked — **no.** The only callers are `RoomDetailView.swift:2128` (`offer.packSlugs`),
   `:2223` (`offer.packSlugs`) and `:2313` (`event.packSlugs`); every one of them passes a list
   whose first slug is already `casino` (`NextNight.swift:84-89`) or, for `:2313`, the saved
   event's own list (`AddEventSheet.swift:284` files casino first). The filter is therefore
   purely the dedupe that keeps the **tick state** free of the always-on slug — it does not
   decide correctness, and it does not hide anything the host can see.
3. **The picker row CAN be made readonly without restructuring the section.** The section is a
   `ForEach` over `availablePacks` inside one `Section`; the casino row can be a sibling
   `HStack` above the `ForEach` (or a row whose `Button` is replaced by a non-interactive
   `HStack`). No structural change is needed → no stop-and-report needed.
4. **No sweep test asserts the picker's option COUNT.** The sweep never opens the sheet's pack
   section at all → nothing to repoint (design 4's "repoint, never delete" is satisfied
   vacuously; the new shape is recorded for the orchestrator's sweep).
5. **The one judgement call in this lane** (flagging it explicitly for the orchestrator): CV3
   **adds** the night's games to the member card, because no member-facing render currently
   shows a pack list at all (§3). If the intent was strictly "stop filtering where a filter
   exists", then CV3 is a one-line no-op (F4/S2/S3/S8 are all already correct) and the lane
   reduces to CV2 + CV4. The proposal in §4.2 is what makes *"in what members see"* true.

---

## 8. CV2 as built — the picker now shows casino

Commit `CV2: picker shows the always-on casino row`, all in `GamesRoom/Views/AddEventSheet.swift`.

**Before** — the host saw two rows, "Cards Against Humanity" and "Monopoly Deal", and was
never told the night is a casino night:

```
What are you playing?
  ○  Cards Against Humanity
  ○  Monopoly Deal
```

**After** — three rows, casino first, pre-ticked, not tappable:

```
What are you playing?
  ✓  Casino
     Every night runs on casino chips
  ○  Cards Against Humanity
  ○  Monopoly Deal
```

What changed, line by line:

| Change | Where | Note |
| --- | --- | --- |
| F1 filter **deleted** | `availablePacks` (was `:244-248`) — now `PackRegistry.shared.allPacks.map { … }`, no `.filter` | The catalog is the registry again. Casino is first because `PackRegistry.defaultPacks` lists it first (F5) — the order comes from one place, not from a sort here. |
| Casino row **readonly** | new `alwaysOnPackRow` + `packRow(_:)` | The row is an `HStack`, **not** a `Button` — there is nothing to tap, so it cannot be unticked. The tick mark (`Theme.Icon.checkmarkCircleFill`, accent) renders it as pre-ticked. Caption: "Every night runs on casino chips". |
| Caption typography | `Theme.Typography.caption` / `Theme.Palette.secondaryText` | The other rows show no description (`PackOption` carries only `slug` + `displayName`), so the brief's conditional "use its description as the secondary text **if the other rows show descriptions**" does not fire; the caption is the secondary line instead. |
| `togglePack` **guarded** | `guard slug != CasinoPack.slug else { return }` | Belt and braces: even if something else calls it, the always-on slug can never enter the tick set. |
| Seed filter **kept** | `initialPackSlugs` (`:91-93`) | Still the dedupe guard, not a display filter: it keeps the tick state free of the always-on slug so the rows and the tick state cannot disagree. Recorded here because the brief asks for the reason whenever a filter is kept. |
| `save()` **untouched** | `:284` | Still `[CasinoPack.slug] + packSlugs.filter { $0 != CasinoPack.slug }` — files casino first, dedupes. |
| Comments rewritten | `:68-72`, `:84-87`, the seed filter, `availablePacks` | The two stale statements from §5 ("the casino pack is not offered here", "Chips are never listed here") now say the new rule: casino is always on and visible; the label informs, the save semantics never depended on the tick. |

**Ordering note:** the "casino first" order is inherited from `PackRegistry.defaultPacks`
(F5) — the picker adds no sort of its own. If a future pack is registered before casino,
the row order follows the registry, which is the single source of truth.

**Not done in CV2 (by design):** the member-facing side. No member render shows a pack
list at all (§3), so CV3 has to ADD the night's games to the member card rather than
un-filter anything. §4.2 holds the proposed shape.

---

## 9. Step plan (for CV2 → CV4)

| Step | Commit | Files | Work |
| --- | --- | --- | --- |
| CV1 | `CV1: where casino is hidden — facts` | `REPORT-task-CV.md`, `.maestro/STATE-cc-cv.md` | This document. **DONE** |
| CV2 | `CV2: picker shows the always-on casino row` | `GamesRoom/Views/AddEventSheet.swift` | Remove F1; render the readonly pre-ticked Casino row first with the caption "Every night runs on casino chips"; guard `togglePack`; rewrite the two stale comments (§5). **DONE** — see §8 |
| CV3 | `CV3: member renders include casino` | `GamesRoom/Models/NextNight.swift`, `GamesRoom/Views/RoomDetailView.swift` | Shared pure "casino first" rule; member card gains the games line with casino first; F4/S2/S3/S8 left alone |
| CV4 | `CV4: tests repointed + report` | one Foundation test file (+`main.swift` call, `build-and-run-tests.sh` list line), `REPORT-task-CV.md` | Pin the picker shape (casino present, first, readonly) and the member-facing list (casino first); finish this report with the before/after a member sees |

**Files this lane may touch** (from the brief): `GamesRoom/Views/AddEventSheet.swift`,
`GamesRoom/Views/RoomDetailView.swift` (which **is** the briefing view file — `BriefingSlot` is
`private struct` at `RoomDetailView.swift:2320`), `GamesRoom/Models/NextNight.swift`, ONE
Foundation test file, `main.swift` / `build-and-run-tests.sh` (list lines only), this report,
`.maestro/STATE-cc-cv.md`. No migrations. No `PackRegistry` structural change.
