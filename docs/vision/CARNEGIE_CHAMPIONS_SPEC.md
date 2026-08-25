# Games Room — V0.84 Carnegie Champions Slice (SPEC)

> Status: **locked** (2026-08-19). Six features, all host-side or voice-side,
> all Carnegie-grounded, all honouring the locked substrate. Repo home:
> `docs/vision/CARNEGIE_CHAMPIONS_SPEC.md`. Brain mirror:
> `concepts/games-room-carnegie-applied-playbook`.
>
> Feeds: [[originals/2026-08-13-games-room-v053-vision-memo]],
> [[originals/2026-08-13-games-room-friendship-substrate-spec]],
> [[originals/2026-08-13-games-room-ledger-social-surface-spec]],
> [[concepts/2026-07-27-games-room-profile-aware-social-design]].
>
> **Locked directive (2026-08-19): the mascot is the only system voice.**
> Every surface where the system speaks to the room — push, recap, no-show
> prompt, seasonClose voice, the async drop, the chair card, the briefing —
> speaks as the mascot, in the mascot's personality and politics. No neutral
> system voice. No bare "system" prompt. The host is the only human voice in
> the room; the mascot is the only system voice.

---

## The six Champions (build order)

1. **C4** — `.seasonClose` voice rewrite (praise-first)
2. **S2** — Carnegie holding test added to the substrate spec (doc-only)
3. **C3** — no-show tax as host prompt + room settings
4. **C2+C5** — Tonight's Star override categories + async one-line drop (linked pair)
5. **C1** — host's pre-loaded opening line per member

---

## C4 — `.seasonClose` voice rewrite (praise-first)

**Carnegie:** Ch 2.2 (Schwab's "hearty in approbation, lavish in praise") +
4.6 (praise the slightest improvement). The system voice does the host's
praise-amplification work.

**What changes:** the mascot's season-close voice cells move from
informational ("Good Sport: Sam. Median loss of 40 chips.") to praise-first
("Good Sport: Sam. Three losing nights, and Sam never once tilted, never once
bailed — kept the loss small and the table laughing. That's the player who
makes a table worth sitting at.").

**The three moves (the whole pattern):**
1. Name the specific behaviour, not the stat.
2. Praise it sincerely (earned by the act, so it can't be flattery).
3. Keep it about the behaviour, never a blanket "you're great."

**Implementation:**
- `GamesRoom/Services/MascotEngine.swift` — the season-close voice cells.
  Find the `.seasonClose` template matrix (V0.48). Rewrite each award's
  voice cell to the praise-first form. Six awards: Phoenix, Veteran, Whale,
  Iron Mann, Comeback Kid, Good Sport. (Drowning stays private — no voice
  cell, per locked spec.)
- `GamesRoom/Services/MascotVoiceService.swift` — if the LLM path generates
  season-close lines, add the praise-first pattern to the prompt/system
  instruction so the LLM matches the template register.
- **Do NOT** change `MascotPersonality` / `MascotPoliticalIdeology` — the
  praise-first register is a *voice* change, not a *personality* change.
  The mascot's politics stay; only the season-close register shifts.

**Verification:** parse-check the modified files; grep the season-close
cells for the three moves (behaviour-named, sincere, behaviour-scoped).

---

## S2 — Carnegie holding test (doc-only)

**Carnegie:** the throughline. The test that catches corruption.

**What changes:** add one paragraph to
`docs/vision/FRIENDSHIP_SUBSTRATE_SPEC.md`, next to the existing V0.53
holding test:

> *If a move keeps the host looking at the technique instead of the
> members, it fails the room.*

Same shape, same severity, same direction as the product holding test.

**Implementation:** edit the doc. No code. Also mirror the line into the
brain page `concepts/games-room-carnegie-applied-playbook` (already done —
verify it's there).

---

## C3 — no-show tax as host prompt + room settings

**Carnegie:** 3.1 (don't argue) + 4.5 (let the other person save face) +
the new holding test (host looking at people, not technique).

**What changes:** the no-show tax stops auto-firing at session start. It
becomes a **host prompt** with **room-level settings**.

**Current state:** the deposit/no-show mechanism lives in
`GamesRoom/Models/SeatDeposit.swift` and the auto-debit fires at session
start (per the v1 build). The tax forfeits chips into the next pot.

**New behaviour:**
- At session start, instead of auto-debiting, the host sees a prompt:
  *"Sam claimed a seat. Sam didn't show. 200 CC into the next pot — apply?"*
  (mascot-voiced, in the mascot's register — NOT a neutral system dialog).
- Three buttons: **Apply** / **Skip (Sam texted)** / **Skip (Sam's away)**.
- The host always decides. The system never decides alone.

**Room settings (in `RoomSettingsSheet.swift`):**

| Setting | Controls | Default |
|---|---|---|
| `no_show_tax_amount` | CC forfeited per no-show | 200 |
| `no_show_tax_trigger` | `auto` / `prompt` / `manual` | `prompt` |
| `no_show_tax_grace_minutes` | late-arrival window that voids the tax | 10 |
| `no_show_tax_destination` | next pot / host charity pot / split | next pot |

**Implementation:**
- New migration `082_no_show_tax_settings.sql` — add the four columns to
  the room settings table (or a new `room_no_show_settings` table if the
  settings are not already columnar). Check the existing settings schema
  first (`073_fix_settings_save_and_dispense.sql` touched settings).
- `GamesRoom/Models/SeatDeposit.swift` — change the trigger from
  `auto_debit_on_session_start` to `prompt_host_at_session_start`.
- `GamesRoom/Views/RoomSettingsSheet.swift` — add the four settings rows.
- Host prompt UI — a mascot-voiced prompt at session start, three buttons.

**Substrate line honoured:** the chip moves into the next pot (public
record), it does NOT get recorded against the absent member's social
standing. Drowning stays private; the no-show tax stays public next-pot
money. The host's prompt is the only moment the no-show touches the room.

---

## C2+C5 — Tonight's Star override categories + async one-line drop (linked pair)

**Carnegie:** 4.9 (make the person happy to do the thing) + 4.6 (praise
the slightest improvement) + 2.4 (be a good listener). C5 feeds the host
the raw material; C2 lets the host act on it.

### C2 — Tonight's Star override categories (host pick, NOT a vote)

**Locked decision (2026-08-19):** Tonight's Star is a **host pick**, not a
member vote. A vote turns recognition into a tally (the substrate's named
betrayal of philia 2.3: "the relationship counted as points"). The host's
pick is specific and sincere; a vote is aggregate and popularity-driven.

**What changes:** the existing one-tap override gains structured categories.
The chip-swing default stays (it's the honest "you played the game well"
proxy — the user's locked preference for play-quality as the leading
factor). The override is the host's qualitative read.

**Override categories (enum `TonightStarOverrideCategory`):**
- `best_play` — "the read on the river was perfect" (host's qualitative call)
- `good_sport` — the loser who lost well (locked ledger term)
- `held_the_room` — the social role (runner, dealer, side-bet settler)
- `showed_up` — came back after a gap, first night, friend-of-friend slotted in
- `custom` — free-text, host writes their own line

**Implementation:**
- `GamesRoom/Models/AwardType.swift` — add the enum (or a new small model).
- The session-finalize path (where `tonight_star` is computed) — add
  `override_category` + `custom_text` fields.
- The ceremonial card slot — render the category + the mascot's line for it.

### C5 — async one-line drop, next morning with the recap

**Locked decision (2026-08-19):** the drop arrives **the next morning with
the recap**, not on the post-session screen. The member reflects in private,
then writes one line (or skips). The host reads it in the next prep.

**What changes:** a one-way, low-friction, no-thread channel. Member drops
one line after the night; host sees new notes in the next prep. No
threading, no replies, no feed.

**The prompt (mascot-voiced, not a bare form field):**
*"Anything you want the room to know next time?"* — one line, one tap to
dismiss, no nagging. If the member has nothing, the prompt disappears and
never returns until the next recap. No streak, no "you haven't written
anything in 3 weeks" (substrate's "no come-back engagement" line).

**Implementation:**
- New migration `083_room_member_notes.sql` — table
  `room_member_notes` (id, room_id, member_id, season_id, note_text,
  created_at, consumed_by_host_at).
- New RPC `submit_member_note` + `get_unconsumed_member_notes`.
- Member iPhone: the recap screen gains the one-line prompt (mascot-voiced).
- Host iPad: the prep screen shows new notes (mascot-framed, e.g.
  "Felty: Sam left a note for next time.").
- **No threading, no replies, no feed.** One-way only.

**C2+C5 are one feature.** C5 feeds the host the raw material ("Sam's read
on the river was the best thing I saw all night"); C2 lets the host act on
it (pick Sam for Tonight's Star). Build them together.

---

## C1 — host's pre-loaded opening line per member

**Carnegie:** Ch 2.3 (name = sweetest sound) + 4.7 (reputation to live up
to). Loads the host's first move.

**What changes:** pre-night, on the host's iPad only (the member never
sees it), show one opening line per attending member — a short, specific,
genuine opener drawn from the social-preferences + chair-card data.

**The line is a suggestion, not a script.** The host can use it or ignore
it. The host is pre-loaded, not rehearsing. The system provides the raw
material; the host delivers the move in their own voice at the table.

**Mascot boundary (locked):** the *suggestion* is mascot-framed ("Felty
suggests: …"), but the host *delivers* it in the host's own voice. The host
is the mascot's human proxy, not its puppet (the locked Felty-as-the-Bank
pattern).

**Implementation:**
- Reuse the per-member social preferences surface (spec'd in
  `concepts/2026-07-27-games-room-profile-aware-social-design`, not yet
  built). If not built, this feature builds the minimal version: a
  `member_social_preferences` table (member_id, room_id, preferences_json,
  host_opener_suggestion) — host + system see it, member does not broadcast.

> **V0.92 revert:** C1 (host opener suggestion) was deleted wholesale
> per user direction — view section (`HostOpenersSection`),
> model/derivation (`HostOpenerSuggestion.swift`), and the test block
> in `main.swift` are all gone. Spec kept here as audit trail.
- Host iPad: at session-finalize-prep, render one opener per attending
  member, derived from social preferences + chair-card history.
- **Zero new tables if the preferences surface exists; one new table if not.**

---

## Build order (locked)

**C4 → S2 → C3 → C2+C5 → C1**

- C4 first (cheapest, proves the mascot pipeline, sets the praise-first
  voice C1 reuses).
- S2 second (doc-only, locks the discipline before building on it).
- C3 third (biggest host-experience change, independent of voice work).
- C2+C5 fourth (linked pair, benefits from C4's voice being stable).
- C1 last (builds on C4's voice + C5's prep-surface).

---

## What NOT to build (the extinct list)

- No member vote for Tonight's Star (tally = corruption).
- No in-app leaderboard of "most-praised members."
- No AI-generated conversation topics per member (host becomes ventriloquist).
- No "X hasn't been to a night in 3 weeks" push (substrate 1.3 violation).
- No automated "good sport" detection (host-called, not algorithm-detected).
- No public "thanks" wall (becomes a feed).
- No host dashboard "you're X% less social than last season" (the trap).

---

## Verification (per the kanban-orchestration skill)

1. `./build-and-run-tests.sh` + parse-check after every task.
2. `python3 scripts/verify-xcode-project.py` after any pbxproj change.
3. FF-merge each task branch to main before the next task branches.
4. `git rev-list --left-right --count origin/main...main` — push after the batch.
5. The definitive gate is `xcodebuild` on the Mac Studio (this host has no
   Xcode.app — document what was NOT verified).

## Sources

- Carnegie, D. *How to Win Friends and Influence People* (1936).
- Locked Games Room canon: V0.53 vision, friendship-substrate spec,
  ledger-social-surface spec, narrative spine, profile-aware design.
- Brain: `concepts/games-room-carnegie-applied-playbook`.
