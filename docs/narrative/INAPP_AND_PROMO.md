# Games Room: In-App Onboarding + Promo Channel Narrative

> Status: canonical. Carries the locked narrative spine into the product
> surfaces that talk to a person: the first-run flow, the in-app walk-through,
> the App Store listing, social posts, and email. Every load-bearing claim
> carries its source in `[Source: ...]` form per the VISION.md convention.
> When a source and this doc disagree, the source wins.
>
> Parent: `docs/narrative/NARRATIVE_SPINE.md` (the locked spine). That doc
> holds the hero pairing, the three personas, the story arc, and the message
> triangle. This doc applies them surface by surface.
>
> Brand: **Games Room** (the commercial fork, not Felt Faction).
> [Source: kanban task t_27b11093 body]

---

## 1. In-app first run (3 screens, one CTA each)

Carry-down per the locked directive: in-app leads with the sub-headline,
closes screen 3 with the H1. [Source: NARRATIVE_HEADLINE_DIRECTIVE.md,
2026-08-13]

Each screen has one job and one CTA. No skip button that reads as a rebuke.
No feature tour. No login wall before the first promise.

### Screen 1: the thesis

Headline: **Real tables. Real friends. No feed.**

Supporting line (the promise, made concrete):
"Three taps and the night is on. The room remembers who is coming, who is
ahead, and what happened last time."

CTA: **Create your room**

### Screen 2: the chair card, in three steps

Headline: **Every night starts with a seat.**

Three steps, shown as a picture and a phrase:

1. **Host sets the night.** Three taps. Time, place, who.
2. **Members claim their seats.** Your name lands on a chair card.
3. **You show up and play.** The app steps back. The table takes over.

CTA: **Open your first room**

### Screen 3: the privacy posture

Headline: **No feed. No followers. No noise.**

Bullets (3-4):

- No feed to scroll, no likes to farm, nothing to check at 11pm.
- Invite-only. Your people, your six-character code.
- No ads, no analytics, no tracking. Sign in with Apple; we never see your email.
- The app stays out of the night. It plans it, then leaves.

Closing line (the locked H1, the last thing before the app opens):

**Plans the night. Gets out of the way.**

CTA: **I'll invite later**

That CTA is honest: the app works fine empty, so a person who is not ready
to invite does not get pushed into it. The privacy posture is the point, not
a hurdle.

### Permissions prompt copy

Every OS dialog is rewritten in the spine's voice. No "Allow / Not now"
defaults; each prompt explains what the permission does for the night and
offers a plain-language way to decline that does not shame the user.

**Notifications (used to send the invite and the reminders):**

> "Games Room sends the 'who's in Friday' so you don't have to. Turn it off
> anytime; the room still runs."

Buttons: **Keep me posted** / **The room runs without it**

**Camera or mic (deferred, only if a future pack needs it):**

> "Used only to score the night you're already playing. Nothing leaves the
> room."

Buttons: **Only during a night** / **Never**

No emoji in any dialog. One emoji per surface max, never in a hero or a
prompt. [Source: kanban task t_27b11093 body]

---

## 2. In-app chair card walk-through (first room landing)

The moment a member lands in a room for the first time. Same spine voice:
plain, warm, no hype. The reader is the person at the table, never the
metric. [Source: NARRATIVE_SPINE.md §9]

### Tooltip copy (40 characters or fewer per tooltip)

- **Your seat.** "Your name lands here." (21)
- **The ledger.** "The season, in numbers." (25)
- **The working hand.** "Tonight's pot, live." (23)
- **The invite code.** "Six letters. Your door." (23)
- **The night.** "Next table night, here." (24)

### Empty states

- **Empty ledger:** "No nights yet. The first one starts the season."
- **Empty working hand:** "The pot's empty until the first hand."
- **No upcoming night:** "Nothing on the table. Plan the next one."

Each states the fix, not just the gap. The empty state never reads as a
failure; it reads as a door.

### Confirmation patterns (the three grades of "done")

The product has three distinct confirmation moments, and they should not
sound the same. [Source: LEDGER_SOCIAL_SURFACE_SPEC.md, plan.md seat-deposit
flow]

- **Seated.** The chair card is claimed. The invitee is in. "You're seated.
  The night knows you're coming."
- **Deposit confirmed.** A seat deposit was held (the anti-flake
  commitment device). "Deposit held. Your seat is yours." The forfeit side
  is framed as the no-show tax that flows into the next night's pot, never
  as a penalty. [Source: RESEARCH_BRIEF_COUNTER_TREND.md §no-show tax]
- **Settled for the season.** The season close. "Settled for the season.
  Here's how it went." This is the ceremonial card, the arc made legible.

---

## 3. App Store / TestFlight copy

App Store is a paste-and-pray surface. Everything below is concise and
ready to paste. Do not fabricate quotes, testimonials, or reviews. [Source:
kanban task t_27b11093 body]

### App name subtitle (30 characters or fewer, 3 options)

1. **Real tables. Real friends.** (26)
2. **Your games night, counted.** (26)
3. **The night, planned.** (17)

### Promotional text (170 characters or fewer, 3 options)

1. "Real tables > real feed. Games Room plans your night and gets out of
   the way. Three taps, everyone seated, nobody chased." (117)
2. "Your friend group, with a memory. The ledger holds the season, the
   awards name the arc, and the app stays out of the night." (125)
3. "Invite your people. Claim your seat. Let the night run itself." (73)

### Description (a single coherent story, not a feature list)

The description reads as one story, built on the spine's three openings.
Under 4,000 characters, ready to paste.

> Games Room plans your game night so you can live it. Your people, your
> tables, your running score. No feed to scroll, no followers to farm.
>
> You are the host. Three taps and the night is on: time, place, who's in.
> The app sends the "who's Friday" so you don't have to, and it stops
> talking once the cards hit the table.
>
> You are the guest. You claim a seat and your name lands on a chair card.
> The seat holds, the night is guaranteed, and you walk in already part of
> the story: the ledger tells you who is ahead and what happened last time.
>
> You are the quiet one. You read the season before the door, so you never
> arrive cold. The ledger, the standings, the awards. The arc of ninety
> days, one table, no wipes.
>
> When the season closes, it does not vanish. The ledger names the arc:
> the winner, the comeback, the one who kept showing up. Nights compound
> into a season, a season into a running joke, the joke into belonging.
>
> Games Room is private by design. Invite-only rooms behind a six-character
> code. No ads, no analytics, no third-party tracking. Sign in with Apple;
> we never see your email.
>
> Plans the night. Gets out of the way.

### What's New (one template, under 4,000 characters)

> The season has a memory now. When a night ends, the ledger holds it, and
> when the season closes, it names the arc: the winner, the comeback, the
> one who never missed. Your games night, counted.
>
> What's in this build: claim-your-seat chair cards, the running ledger,
> the working hand, and the season-end awards. Invite-only, no feed, no
> tracking.

### Keywords (100 characters or fewer, comma-separated, canonical)

> game night, board games, poker, card games, invite friends, group games,
> weekly games, table games, party games

---

## 4. Social post angles (1 paragraph each)

Carry-down for social: the H1 leads as topic-sentence, the sub-headline is
the punchline. [Source: NARRATIVE_HEADLINE_DIRECTIVE.md carry-down order §3]
No emoji-as-design; at most one emoji per post, never as the hook. No
fabricated testimonials. Each post is ready to post to IG, X, or Mastodon
as-is.

### The "no feed" post

> The feed taught us to collect friends and keep none of them in a room.
> Games Room plans the night, then gets out of the way. Real tables. Real
> friends. No feed.

### The "chair card" post

> Every night starts with a seat. The host sets the night in three taps,
> and each friend's name lands on a chair card. Nobody scans the room for
> where they fit. Plans the night. Gets out of the way.

### The "quiet member" post (radical honesty)

> Some friends find the night harder than everyone else. The ledger is for
> them: they read the season before the door, so they walk in already in
> the story, without performing it. Plans the night. Gets out of the way.

### The "season-end award" post

> A season is more than a string of evenings. When it closes, the ledger
> names the arc: the winner, the comeback, the one who kept showing up.
> Real tables. Real friends. No feed.

### The "host labour = 3 taps" post

> Running the night used to be the whole job. Games Room cuts it to three
> taps: time, place, who's in. Then it leaves you alone to play. Plans the
> night. Gets out of the way.

---

## 5. Email subjects (8 candidates, A/B ready)

Each line is a subject only, in the spine's voice. Grouped by the three
recipient moments. Use the opening that best matches the message triangle
slot: hero for a cold invitee, onboarding for the first-time flow, arc for
the returning member. [Source: NARRATIVE_SPINE.md §9]

### Host (invite) — the onboarding opening

1. The night plans itself now
2. Three taps. The night is on.
3. Your room is waiting. No one to chase.

### Invitee (first-time) — the hero opening

4. Your seat's claimed. Just walk in.
5. Real tables. Real friends. No feed.
6. Someone set the table. You're in.

### Returning (season-end) — the arc opening

7. The season just closed. Here's how it went.
8. One season down. The ledger remembers.

---

## Rules held (recap)

- Same spine, three openings per the message triangle. [Source:
  NARRATIVE_SPINE.md §9]
- No emoji-as-design: one emoji per surface max, never in a hero or prompt.
- App Store description reads as a single coherent story, not a feature
  list.
- No fabricated quotes, testimonials, or App Store reviews.
- Brand: Games Room (commercial fork), not Felt Faction.
- Zero em-dashes in body text. [Source: nathan voice rule]

*Narrative applied. The app plans nights; the room runs them. The reader is
always the person at the table, never the metric.*
