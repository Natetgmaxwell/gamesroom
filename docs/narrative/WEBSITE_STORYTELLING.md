# Games Room: Website Storytelling (V0.57)

> Status: canonical copy spec for the storytelling lift. Extends the V0.56 page
> in place. Lockstep with `docs/narrative/NARRATIVE_SPINE.md` and
> `docs/narrative/WEBSITE_HERO.md`; do not reframe the thesis. Every load-bearing
> claim carries its source in `[Source: ...]` form. External frameworks are
> attributed inline per the task rule.
>
> This doc is the COPY. The build profile implements the HTML/CSS in a follow-up
> task. Do not deploy from here.

## What changed and why

The V0.56 page explained the product. This lift makes it tell a story. The reader
leaves knowing (a) what the product is, (b) what life feels like with it, (c) why
this matters now, and (d) what to do.

Two sections are added, both load-bearing per the research:

- **The night dies in the thread** (the problem as the hero's call-to-adventure).
  The problem was buried in spine §3; this lift brings it to the page. (Pixar
  story spine: "every day... because of that...")
- **Why now** (the counter-trend). The page never said why this matters now. This
  section makes the cultural claim concrete. (Rory Sutherland, *Alchemy*: frame
  beats substance.)

The existing sections are tightened, not rewritten. The H1 "Your games night,
kept." stays per the user's instruction to keep the character.

---

## Section A: Revised copy for each existing section

### A1. HERO (stays, verbatim)

**H1:** Your games night, *kept.*

**Lead:** A private app for in-person games nights. You bring your people. Games
Room plans the night, runs the scores, and stays quiet during play.

> Kept intact per the user's instruction. The H1 carries the "kept." voice; the
> lead already does the StoryBrand inversion (the reader brings the people, the
> app plans). No change.

### A2. What it is (stays, tightened)

**Heading:** What it is

A host creates a room and shares a six-character invite code. Members join,
claim seats, and RSVP. Every room is invite-only.

> This is the GUIDE beat (StoryBrand: the app is the guide, the host is the
> hero). Keep the concrete mechanics; they are specificity, not jargon.

### A3. Seasons give each pack a score arc (stays)

Scores carry between nights and reset when the season ends. The leaderboard
tracks who actually wins across months, not just who won last Tuesday.

> This is the ARC beat. Keep.

### A4. Four packs ship pre-installed (stays, flagged)

Casino, Cards Against Humanity, Monopoly Deal, Pluto Chess.

> Concrete specificity (technique #5). This is the most cuttable card on the
> page: a reader who skips it still gets the product. Keep for now because it is
> the one concrete proof that the app is real and shippable. If the page ever
> needs to lose weight, this card goes first.

### A5. Every room gets a mascot (stays, optional line added)

Pick its personality at room-create, and it sends the reminders, narrates the
night, and wraps each session in one line. Quiet, witty, on your side.

> The mascot is the page's character and the voice of the "kept" night. Keep.
>
> Optional: add one problem-led line to the typewriter rotation to tie the
> character to the new story spine:
> "The night used to die in the thread. Not anymore."
> Low-risk, on-voice, reinforces the new problem beat. Build profile's call.

### A6. Who this is for (tightened: host leads as the hero)

**Heading:** Who this is for

**Lead-in (new):** The host is the hero. The app is the guide. (StoryBrand: the
reader is the hero, the product is the guide.)

**The host.** Three taps and the night is on. The room is set, the RSVPs are in,
nobody got chased. You host because you want the night to happen, not because
you want to run it.

**The member.** Your chair card has your name on it. You walk in, sit, and the
night starts. No scanning for where you fit, no wondering if it is still on. The
seat is held.

**The quiet member.** You read the ledger before the game. You know who is ahead
and what happened last time, so you walk in already in the story. No performance
required.

> The three personas are the spine's three heroes, verbatim in outcome. The new
> lead-in makes the StoryBrand inversion explicit: the reader is the hero, the
> app is the guide.

### A7. What a season looks like (stays, tightened close)

Week 1: the chair card. The first RSVP that actually held.
Week 4: someone brought chips, unprompted, because the night had become a thing.
Week 8: the season-end award. The loser took the Drowning trophy and laughed.
Week 12: a friend-of-friend showed up, and did not feel new.

**Close:** The arc runs itself. The night keeps itself.

> This is the ARC beat, the compounding promise. Keep. The close already lands
> the "kept" voice.

### A8. Trust line (stays)

No ads. No analytics. No third-party SDKs. Sign in with Apple; we never see
your email.

### A9. CTA (stays)

Coming soon. Games Room is in beta. App Store launch is on the way.

### A10. Footer pull quote (stays)

"Pull up a seat. The night keeps itself."

---

## Section B: New sections (2)

### B1. The night dies in the thread (the call-to-adventure)

**Placement:** immediately after the hero, before "What it is."

**Heading:** The night dies in the thread.

**Copy:**

Every Friday, the chat scrolls on. Because of that, the night dies in the
thread. (Pixar story spine: "every day... because of that...")

Not because nobody wanted it. Because the host had to chase RSVPs, hold the
date, and keep the group from flaking. That is the whole job, and the group chat
is bad at it.

Games Room takes that job off the host's hands. It plans the night, holds the
seats, and gets out of the way. The host is the hero. The app is the guide.
(StoryBrand: the reader is the hero, the product is the guide.)

**Justification:** The problem was buried in spine §3. Techniques #1 and #3
demand it lead the page: the reader must feel the cost of the absence before the
product means anything. This is the stakes beat.

### B2. Why now (the counter-trend)

**Placement:** after "What it is," before "Who this is for."

**Heading:** Why now

**Copy:**

The feed taught a generation to collect friends and keep none of them in a room.
No memory, no arc, no season. Just isolated evenings that never quite became a
thing. [Source: NARRATIVE_SPINE.md §3]

The loneliness numbers are not subtle. Half of US adults report feeling measurably
lonely, and the Surgeon General calls it a public-health epidemic. [Source: US
Surgeon General's Advisory on Loneliness, 2023]

The fix is not another feed. It is the opposite: a small group that meets on a
schedule and keeps a memory. Real tables. Real friends. No feed.

How you frame a thing changes what it is worth. (Rory Sutherland, *Alchemy*.)
Games Room is not a calendar app. It is the counter-trend to social media: tech
that gets people to the table, then gets out of the way.

**Justification:** The design ship target requires the reader to know why this
matters now. The page never said it. This section makes the cultural claim
concrete and closes on the thesis. (Sutherland: frame beats substance.)

---

## Section C: Meta tags + meta description

**Page title:**
Games Room — Your games night, kept

**Meta description (≤160 chars, count 156):**
The night keeps dying in the group chat. Games Room plans it, holds the seats,
and gets out of the way. Invite-only rooms, a ledger that remembers, no feed.

**OG title (≤40 chars, count 28):**
Games Room — your night, kept

**OG description (≤90 chars, count 73):**
The in-person games night app. Plans the night, holds the seats, no feed.

**OG / twitter image alt:**
The Games Room mark: a warm table seen from above, four seats waiting, in dark
grey and gold.

> The meta now leads with the problem (the night dying in the thread) and the
> outcome (kept), not the feature list. This matches the story spine: open with
> the cost, close with the kept night. The em-dash in the two title strings is
> the established title-separator convention (matches the current page and the
> locked WEBSITE_HERO meta), not a prose crutch.

---

## Section D: Story spine map

How the page reads as one narrative:

```
OPEN    →  HERO: "Your games night, kept." The promise.
CALL    →  THE NIGHT DIES IN THE THREAD: the problem, the cost of the absence.
GUIDE   →  WHAT IT IS + WHY NOW: the app as guide, and why it matters now.
ARC     →  SEASONS + WHAT A SEASON LOOKS LIKE: the compounding promise.
RETURN  →  WHO THIS IS FOR + CTA: the three heroes return to the table; the action.
```

Each beat earns its place:

- **OPEN:** the promise, one line.
- **CALL:** the stakes. The reader must feel the cost before the product means
  anything. (Pixar spine: "every day... because of that...")
- **GUIDE:** the app as guide, not hero. (StoryBrand inversion.)
- **ARC:** the compounding. Nights become a season, a season becomes belonging.
  (Hall 2019: 90 to 200 hours together.)
- **RETURN:** the three heroes, then the action. The reader is the person at the
  table, never the metric.

---

## Section E: A/B candidate headlines (3)

1. **"Your games night, kept."** (current, control). Keeps the established voice
   and the "kept" character the user asked to preserve. The strongest emotional
   claim: the night is held, not lost.

2. **"The night that used to die in the thread."** (problem-led). Opens with the
   cost, per techniques #1 and #3. Risk: names the problem but not the product;
   works only if the sub-headline teaches.

3. **"Plans the night. Gets out of the way."** (the spine's locked pairing).
   The product claim from the narrative spine. Teaches what the app does in
   seven words. Risk: loses the "kept" voice the user asked to keep; this is
   the V0.55 hero, not the V0.57 one.

> Recommendation: keep #1 as the H1 (per the user's instruction to keep the
> character) and test #2 as the problem-section heading, which is where the
> problem-led line earns its place.

---

## CSS diff

No new CSS required. The two new sections reuse the existing `.card`,
`.section-head`, and `.reveal` classes. The problem section (B1) can use the
`.hero-card` accent-wash treatment to mark it as the emotional open. The build
profile should add the new sections as `.reveal col-full` cards, matching the
existing pattern. No palette change: dark grey + gold stays.

---

*Copy locked for the V0.57 storytelling lift. Build profile implements the HTML
in a follow-up task. Zero em-dashes in the body prose. Zero hype verbs. Plain,
warm, no hype.*
