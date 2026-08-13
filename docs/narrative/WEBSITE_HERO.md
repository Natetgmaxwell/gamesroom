# Games Room: Website Hero + Sub-sections

> Status: canonical copy spec. Lifted by the build profile into the V0.55+
> website deploy (currently V0.43 "coming soon" at gamesroom.nateterrence.net).
> Lockstep with `docs/narrative/NARRATIVE_SPINE.md`; do not reframe the thesis.
> Every load-bearing claim carries its source in `[Source: ...]` form.

This doc gives the exact copy for seven surfaces. It is the *copy*, not the
layout. Where the V0.43 site and this spec disagree on words, this spec wins
(per the V0.43→V0.55 lift). Where they disagree on CTA, the V0.43 CTA stays.

---

## 1. HERO (above the fold)

**Eyebrow tag (6 words):**
The in-person games night app

**H1 headline (7 words):**
Plans the night. Gets out of the way.

**Sub-headline (5 words, the locked pairing):**
Real tables. Real friends. No feed.

**Hero lead (21 words, the one-line thesis from the spine §2):**
Games Room plans the night so you can live it. It brings the people to the
table, then gets out of the way.

**Primary CTA (locked, do not change):**
Get the app

> V0.43 spec: one CTA "Get the app" (App Store link, added when live). The
> beta badge in the current site header ("Beta") stays; the private-beta
> wording does not replace the CTA label. [Source: V0.43_GAMES_ROOM_WEBSITE_SPEC.md]

**Secondary (anchor link):**
How it works

> H1 and sub-headline carry the user's locked A+C directive: A teaches what
> the product is, C argues why it is better. Pairing 1 wins the website hero
> because it teaches; the sub-headline adds the cultural claim with no feed
> on either line. [Source: NARRATIVE_HEADLINE_DIRECTIVE.md, 2026-08-13]

---

## 2. THREE-UP (mid-page): host / invitee / quiet member

Each card is an icon plus a one-line outcome and a one-line emotion. Three
paragraphs, ~30 words each. The personas are the spine's three, verbatim in
outcome, trimmed for the page. [Source: NARRATIVE_SPINE.md §5]

**Host.**
Three taps and the night is on. The room is set, the RSVPs are in, nobody got
chased. You host because you want the night to happen, not because you want to
run it.

**Member (the invitee).**
Your chair card has your name on it. You walk in, sit, and the night starts.
No scanning for where you fit, no wondering if it is still on. The seat is
held.

**Quiet member.**
You read the ledger before the game. You know who is ahead and what happened
last time, so you walk in already in the story. No performance required.

---

## 3. HOW IT WORKS (3 steps, inside 48 hours)

The third step is the night itself. The app is nowhere near the table.

**1. Create your room.**
Name the night, set the day, pick the seats. Two minutes, once a week.

**2. Send the chairs.**
Each person gets a chair card with their name on it. They RSVP, and the seat
is held.

**3. Show up.**
That is the whole app. You arrive, sit at your chair card, and the night runs
itself. [Source: NARRATIVE_SPINE.md §4, §6]

---

## 4. WHAT YOU GET (4 cards)

**Rooms.** One room, your people, invite-only. Nobody joins without a seat.

**The ledger.** Every night is counted. Scores carry between nights, seasons
reset on purpose, and the group keeps its memory. [Source:
docs/vision/LEDGER_SOCIAL_SURFACE_SPEC.md]

**Anti-flake.** The RSVP is the point. A seat is held or it is not; nobody has
to chase anybody. The night survives the group chat.

**Chair cards.** A named seat for every guest. You walk in, you sit, you are
already placed. No "is this taken" at the table.

---

## 5. SOCIAL PROOF (placeholder, no fabrication)

Leave a thin slot below "WHAT YOU GET" and above the privacy section. Do NOT
write fabricated testimonials. Until real users exist, the slot holds a quiet
invitation, not invented praise.

**Slot copy (used until a real testimonial lands):**
Private beta is open to a small group. When the room has something to say, we
will say it here.

> Build note: this is a real placeholder, not marketing. Swap it for a real,
> attributed quote when one exists. No invented voices, ever.

---

## 6. PRIVACY POSTURE (one paragraph)

The bit that converts privacy-curious skeptics.

Games Room is invite-only. There is no public directory, no marketplace, no
feed, no follower counts. You build a room and you own it. The host decides who
is in, and the room stays private. Your nights, your people, your table.
[Source: docs/vision.md §1; V0.43_GAMES_ROOM_WEBSITE_SPEC.md §Acceptance-6]

---

## 7. META

**Page title:**
Games Room — In-person games nights, planned

**Meta description (≤160 chars, count 144):**
Games Room plans your in-person games night and gets out of the way. Invite-only
rooms, a ledger that remembers, no feed. Join the private beta.

**OG title (≤40 chars, count 28):**
Games Room — plans the night

**OG description (≤90 chars, count 83):**
The in-person games night app. Invite-only rooms, a ledger that remembers, no
feed.

**OG / twitter image alt:**
The Games Room mark: a warm table seen from above, four seats waiting, in dark
grey and gold.

> Alt text reuses the current site's hero-icon alt phrasing (V0.43), adjusted
> for the palette already live in style.css (#0A0A0B near-black, #F4EFE6 cream,
> #B08D57 / #c19a63 gold). [Source: website/style.css]

---

## Carry-down notes for the build

- H1 "Plans the night. Gets out of the way." and sub-headline "Real tables.
  Real friends. No feed." are the locked A+C pairing for the website hero.
  Do not reorder them and do not swap in "Real tables > real feed." as the
  H1; that is the social-channel default, not the hero. [Source:
  NARRATIVE_HEADLINE_DIRECTIVE.md §Carry-down]
- The V0.43 site's current H1 "Your games night, kept." retires on the V0.55
  lift. [Source: NARRATIVE_SPINE.md §1]
- Zero em-dashes in this copy. Zero hype verbs. Plain, builder-dry.

---

*Copy locked for the website surface. Build profile lifts the HERO, THREE-UP,
HOW IT WORKS, WHAT YOU GET, PRIVACY, and META sections into the V0.55+ deploy.*
