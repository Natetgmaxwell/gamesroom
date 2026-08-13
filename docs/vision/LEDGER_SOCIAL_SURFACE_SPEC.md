# Games Room: Ledger as the Social Surface (SPEC)

> Status: **locked.** This spec makes the ledger the thing members brag
> about outside the app, without the app on-screen. It sits under V0.53
> (the vision memo) and the friendship substrate: the ledger rewards the
> game, never the friendship; awards honor the social behaviour without
> counting it.
>
> Feeds: [[docs/vision/V0.53_VISION.md]] (vision memo, locked),
> [[docs/vision/FRIENDSHIP_SUBSTRATE_SPEC.md]] (substrate, locked),
> [[docs/vision/RESEARCH_BRIEF_COUNTER_TREND.md]] (research brief, locked).
> Canon: Hall (2019), Currier (NFX 2020), Aristotle *NE* VIII-IX.

---

## 0. The thesis

Most games nights have no memory. The game ends, the chips go back in the
box, and nothing survives except a vague sense that someone won. Competitive
friendship needs an arc, not isolated evenings. The ledger is the durable
social: the record that makes the night a story and the season a chapter.

Today the ledger holds chip balances and season scores. That is the bones.
This spec makes the ledger do more:

1. **Season-end awards: eight named moments** that give the season a
   beginning, a middle, and a close.
2. **A shareable stat card: one printable PNG per member per season**, for
   sharing outside the app.
3. **The Good Sport principle: an external signal** that rewards the social
   behaviour, not the meta-game optimisation.

Two binding rules from the substrate (2.3, 1.5):

1. **The ledger rewards the game, never the friendship.** An award that
   honors social behaviour is framed by the room's voice, not counted as a
   score.
2. **No consolation prizes.** The loss stays real; the friendship is what
   softens it. An award never erases a loss.

---

## 1. What already ships (do not rebuild)

Four season-end awards are code-complete in `close_season`
(Supabase/migrations/048_season_close_and_read_rpcs.sql). They compute from
`casino_settlement` session deltas inside the season window:

| Award | Algorithm (as shipped) | Privacy |
|---|---|---|
| **Veteran** | Most sessions played | Public |
| **Whale** | Biggest single-session net positive | Public |
| **Phoenix** | Largest total climb (sum of positive session movements) | Public |
| **Drowning** | Most negative total, only when the member went negative | Private to recipient, host, opted-in |

Also shipped: the `.seasonClose` mascot slot (V0.48), the awards-card UI
(roadmap W2.5), and season history (migration 057). This spec extends all of
it. It does not rebuild any of it.

---

## 2. Season-end awards (eight total)

Four awards ship today. This spec adds four: Iron Mann, Comeback Kid, Good
Sport, and Tonight's Star. That brings the roster to eight. Every added
award states its algorithm so the build profile can implement it exactly,
and names the substrate condition it serves so a later scope cut knows what
it is giving up.

### 2.1 Iron Mann: most consecutive nights attended

The recurring-slot ritual made legible. This is the anti-flake arc (substrate
1.1: the *repeated* half of "repeated unplanned"). The person who keeps
showing up is the person the room can count on, and the room runs on that.

**Algorithm.** For each member, walk the room's sessions in the season
window in chronological order. A session counts as "attended" when the
member has at least one `casino_settlement` transaction in that session
(the same definition `close_season` uses for Veteran). The Iron Mann score
is the longest run of consecutive sessions attended, where a missed session
(a session with attendees but no transaction from this member) resets the
run. Winner: longest run. Tie-break: more total sessions attended, then
member id. **Minimum run of 3.** If no member attended three consecutive
sessions, the award is not given.

**Why it exists.** Attendance is the only number the product truly cares
about (substrate 1.4: nights that happened). Iron Mann turns that number
into a name a member can wear for a season.

### 2.2 Comeback Kid: the redemption narrative

Shared hardship made legible (substrate 1.5: "the comeback narrative, a
member who went deep negative and fought back"). This is the original
Felt Faction "Phoenix paid back / redemption" concept, separated from the
Phoenix that ships today.

**Why it is distinct from Phoenix.** Phoenix is raw climbing effort: it can
be won by a member who was never in the hole, just climbed a lot. Comeback
Kid *requires* the low point. Phoenix rewards how far you climbed; Comeback
Kid rewards how deep you were and that you came back. The two overlap only
in the rarest, best case: the member who did both.

**Algorithm.** For each member with at least one negative session in the
season window, compute the season-minimum net (their lowest cumulative
season score) and the season-end net. A member qualifies if season-minimum
< 0 and season-end net > 0. Winner: largest `(season_end_net −
season_minimum)`. **If no member qualifies, the award is not given.** No
consolation prize for a member who stayed underwater.

### 2.3 Good Sport: the social award

The Good Sport principle. See Part 4 for the full treatment. Algorithm
summary: among members with at least three losing sessions, the winner is
the one with the highest median net across those losing sessions, meaning
the smallest typical loss. Honored by the room's voice, never counted as a
score.

### 2.4 Tonight's Star: per-night, ephemeral, not a feed

The night needs a named protagonist. At the end of each session, the mascot
names one member as tonight's star, surfaces it once on the ceremonial card,
then lets it go. It does not accumulate, it does not persist as a badge, and
it does not feed any timeline.

**Algorithm.** At session finalize, tonight's star is the member with the
biggest single-session net positive (the same computation as Whale, but for
this one session). The mascot names them once. **The host may override with
one tap** to point at a social moment instead (the same caption mechanic the
awards card already uses): the member who ran the game, dealt the drama,
settled a side bet, brought the laughs. The override exists because the
night's star is not always its biggest winner.

**Why it is distinct from Whale.** Whale is a permanent season-end award.
Tonight's Star is a per-night voice moment that disappears. A member can be
Whale and Star; they serve different jobs and neither devalues the other.
The ephemeral nature is the point: it surfaces once, then the night is over
and the table is the memory.

**What it is not.** Not a feed entry, not a tally ("star 4 times"), not a
badge shelf item, not a notification to every member. It lives on the
ceremonial card for one window and is gone.

---

## 3. The shareable stat card (one design)

One printable PNG per member per season. It carries the memory outside the
app: the thing a member can screenshot, save, print, and put on a fridge.
It is a *personal card*, not a trophy wall, not a ranked scoreboard, not a
badge shelf (substrate 2.3: "never a badge shelf or a score").

### 3.1 Layout, top to bottom

1. **Room name + season ordinal + the season's subtitle** (the mascot's
   chapter line). This is the season as story, not as log.
2. **Member name.**
3. **The season's record:** sessions played, net chips, best single session,
   worst single session, longest attendance streak. The member's own numbers
   and no one else's.
4. **The awards the member earned.** Public awards only: Phoenix, Veteran,
   Whale, Iron Mann, Comeback Kid, Good Sport. **Drowning never appears on
   the card.**
5. **One mascot line.** The season's judgment in the room's voice, generated
   the same way the mascot generates its other lines.
6. **A quiet footer:** "Games Room. Your games night, counted."

### 3.2 Design tokens

From the locked brand register (2026-08-10): deep indigo field `#23264F`,
warm amber accent `#F5A623`, coral `#FF6B5E`, cream text `#F7F3E9`. Rounded
rectangles and circles only. Heavy confident strokes, no hairlines. One
amber accent at a time. No text inside any icon mark. Warm, not noir.

### 3.3 Constraints (the lines we will not cross)

- **Never a ranking position.** The card shows the member's own numbers and
  awards, never "3rd of 8." A position turns a personal card into a scoreboard.
- **Never a badge shelf.** Awards render as one line of earned names, not a
  grid of trophies. The card is not a collection to maximize.
- **The member shares it.** The card is generated on the member's own device
  and shared by the member through the system share sheet. The app does not
  broadcast it, does not aggregate a room leaderboard card, does not create
  a feed.
- **Privacy:** the card contains only the member's own public data.
  Drowning and any private rows are excluded before the image is rendered.

---

## 4. The Good Sport principle

The external signal that rewards the social behaviour, not the meta-game
optimisation.

### 4.1 What it is

Good Sport is the member who loses well. In a room full of competitive
streaks, the bond that holds the table together is the person who stays in a
losing session and keeps the loss small: does not tilt, does not bail, does
not make it everyone else's problem. That is the social behaviour this award
exists to honor.

### 4.2 The algorithm

For each member with **at least three** losing sessions in the season
window (a losing session is a session with negative net), compute the median
of those session nets. Winner: the highest median, meaning the smallest
typical loss (closest to zero). Tie-break: more total sessions attended,
then member id. If no member has three losing sessions, the award is not
given.

### 4.3 Why this algorithm and no other

Three reasons it is the right one:

1. **It is computable.** It derives from the ledger exactly like the other
   awards, so it is fair, deterministic, and implementable in `close_season`.
   It is not a popularity contest and not a host's whim.
2. **It rewards a social fact.** Keeping a loss small while still losing is
   the behavior that keeps a table together (substrate 1.5: shared hardship,
   the climbing-gym trust analog). It cannot be faked by winning.
3. **It cannot be gamed into the meta-game.** You cannot win Good Sport by
   winning; you win it by losing well. The fastest route to it is to stop
   optimizing the score and just play. That is the whole point: it rewards
   the behaviour the meta-game cannot capture.

### 4.4 The line we will not cross

Good Sport is awarded by the room's voice and shown on the member's own
card. It is **never** a leaderboard position, never a ranked score, never a
points contribution, never a metric a member can climb. It honors the
social without counting it. If Good Sport ever becomes a score, it stops
being Good Sport and becomes another thing to optimize.

---

## 5. The mirror, what NOT to do

The single risk is the stat card becoming a badge shelf and the awards
becoming a score the meta-game optimizes. Each betrayal below has a
guardrail in the spec above.

| Principle | The betrayal | The guardrail |
|---|---|---|
| Season-end awards | Awards become a score to climb | Good Sport is voice-only; Comeback Kid and Iron Mann have minimums and can be withheld |
| Tonight's Star | Becomes a feed, a tally, a badge | Ephemeral; one surface, one window, gone |
| Stat card | Becomes a ranked scoreboard | The card shows only the member's own numbers |
| Stat card | Becomes a badge shelf | Awards render as one line of names, not a trophy grid |
| Stat card | The app broadcasts it | Generated on the member's device, shared by the member |
| Drowning | Leaks onto the shared card | Excluded before the image renders |
| Social behaviour | Counted as a score | Good Sport is voice-only, never a metric |

**The holding test (V0.53, verbatim):** *if a feature keeps a user looking
at the screen instead of the people across the table, it fails the
product.* A stat card you share once at season end and put down fails
nothing. A card you open every day to check your badge count fails
everything.

---

## 6. Handoff to build

### 6.1 Database

- **`close_season` (migration 048)**: add Iron Mann, Comeback Kid, Good
  Sport to the award computation, alongside Phoenix/Veteran/Whale/Drowning.
  Reuse the same `casino_settlement` session-delta CTE. Migration 049.
- **Tonight's Star**: computed at the session-finalize path (not the season
  close). Ephemeral: no `season_awards` row, no persistence beyond the
  ceremonial card. A `tonight_star` field or a small post-session RPC is
  enough.
- **`season_awards`**: `good_sport` is public. It already reads correctly
  through `get_season_awards` (no `drowning` read-set needed).

### 6.2 Model layer

- `AwardType`: add `.ironMann`, `.comebackKid`, `.goodSport`,
  `.tonightStar`. `isPrivate` stays false for all four.
- `SeasonAward`: no schema change needed; the four new types write through
  the existing row shape.
- New `SeasonStatCard` value: `(room, season, member, record, awards,
  mascotLine)`, a pure struct the view renders.

### 6.3 UI

- **Awards card (W2.5)**: extend the roster to eight rows. Tonight's Star
  is not a card row; it is the ceremonial-card moment.
- **Stat card**: one SwiftUI render exported to PNG via `ImageRenderer`,
  shareable through the system share sheet. A share action off the awards
  card and the season history.
- **Mascot**: Good Sport and Tonight's Star get their own `.seasonClose`
  voice cells (extend the V0.48 template matrix).

### 6.4 Verification

Per the repo's gate: `./build-and-run-tests.sh` (Foundation tests +
parse-check) and `python3 scripts/verify-xcode-project.py` after any pbxproj
change. The stat card PNG render needs a manual pass on an Xcode host
(`ImageRenderer` is not exercised by the parse-only gate).

---

## Sources

- Hall, J. (Univ. Kansas, JSPR 2019): the 50/90/200-hour friendship curve.
- Currier, "Your Life Is Driven by Network Effects," NFX 2020: the five
  conditions; "shared hardship" is a paraphrase of its "shared challenge /
  experience" framing.
- Aristotle, *Nicomachean Ethics* VIII-IX: utility, pleasure, virtue.
- Locked feeds: `docs/vision/V0.53_VISION.md`,
  `docs/vision/FRIENDSHIP_SUBSTRATE_SPEC.md`,
  `docs/vision/RESEARCH_BRIEF_COUNTER_TREND.md`.
- Existing code: `Supabase/migrations/048_season_close_and_read_rpcs.sql`,
  `GamesRoom/Models/AwardType.swift`, `GamesRoom/Models/SeasonAward.swift`,
  `docs/roadmap-v0.9.md` (W2.5), `docs/loop-artifacts/V0.48_MASCOT_STATE_AWARE_SPEC.md`.
