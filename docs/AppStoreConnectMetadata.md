# Games Room — App Store Connect metadata (V0.92 / build 1.2.4)

Paste-ready values for the App Store Connect record. One section per field, in
the order App Store Connect asks for them.

**Locked decisions.** Subtitle, keywords, promo text and categories were settled
by Nathan on 2026-11-08
(`originals/2026-11-08-games-room-1-2-4-listing-decisions`). This file does not
re-open them. Where the card said "pick", the locked value is used and marked.

**Why this rides 1.2.4.** Subtitle, keywords, description and promo text are
editable only on a new version submission. The live record (app `6801997519`)
currently has an empty subtitle and a 99/100 keyword field of dead terms.

Verified 2026-11-11: all four URLs below returned HTTP 200.

---

## 1. App Information

### App name (30 max) — LOCKED

```
Games Room
```
10 characters.

### Subtitle (30 max) — LOCKED 2026-11-08

```
For regular games nights
```
24 characters. Locked over the earlier teaser "Your games night, on the house"
(30, exact limit). The locked line states the promise without naming a pack and
leaves 6 characters of headroom.

### Primary category — LOCKED

```
Lifestyle
```

Why: the app's job is organising a recurring in-person night, not playing a
game. `Games` would put it in a chart next to apps that actually deal cards (5
Second Rule, Cheers, Wavelength) where it cannot compete and would mislead about
what it does. `Lifestyle` is where planning and social-organising utilities are
found, and it matches the query space the app wins: planner and tracker terms,
not game titles.

### Secondary category — LOCKED

```
Social Networking
```

Why: the room, invite codes, seats and RSVPs are a multi-person coordination
surface, and a second category is free discovery. Caveat, stated plainly: the
app is explicitly not a social network. No feed, no DMs, no follows. The
category is a listing surface, not a product claim.

---

## 2. Description (4000 max)

Length: 2,812 characters.

```
Most games nights do not fail at the table. They fail in the group chat three
weeks earlier: who is coming, which night, who brings chips, who cancelled last
time.

Games Room is the room your night lives in. One person hosts. The host makes a
room, gets a six-character code, and sends one code to each friend. The friend
types it once. After that the code stops working. Six characters, one use, one
friend.

Then the room does the boring part.

The host sets the night: date, time and which games the room plays. Everyone
sees it at the same moment.

Reminders go out one week before, three or four days before, and on the morning
of the night. They stay off until each member turns them on for that room, and
they stop the moment somebody taps Can't make it.

Members claim a seat with one tap. Their name goes on a chair and the room sees
who is coming. Release the seat and it opens for somebody else.

The host can put a deposit on a seat for a night. Tap I'm here when you arrive
and it comes back. No-show and it is forfeited.

After the night, not during it. Games Room runs before and after the night.
During play the phones stay face down and the table plays. If a game needs a
score, the host enters it. Casino runs poker, blackjack, and hi-lo with
seat-deposit escrow so a no-show costs the room chips they would have played
with — the deposit goes to the ledger as a forfeit, no one pockets it.

Chips are an in-app currency that lives in the room's ledger and never converts
to anything outside the app. Take points from a balance in the app, the host
hands out the physical chips at the table, and at the end a scan of your stack
records what you won or lost. No card is charged. No cash enters the app and
none leaves it.

Three packs ship pre-installed: Casino, Cards Against Humanity, Monopoly Deal.
Each room enables its own set, and a how-to for each pack sits in the app. More
games are on the way.

A season, not a scoreboard. Scores carry from night to night and reset when the
host ends the season. Then the awards land: Phoenix, Veteran, Whale, and
Drowning, the loser's trophy, handed over with a laugh. The point is that the
friend of a friend who turns up in week twelve is not treated as new.

Every room gets a mascot. Pick its name and personality when you make the room.
It sends the reminders, narrates the night, and wraps the session in one line.
It takes the social work off the host's plate.

What the app will not build: no feed, no DMs, no follows, no streaks. Each of
those keeps your eyes on the screen, and your eyes belong on the people at the
table.

Private by construction. Every room is invite-only. Sign in with Apple, and we
never see your email. No ads, no analytics, no third-party SDKs. Your data stays
in your rooms.

Pull up a seat. The night keeps itself.
```

Two sentences are fixed by the 2026-08-22 amendment and must survive any edit:
the Casino paragraph, and "Chips are an in-app currency that lives in the
room's ledger and never converts to anything outside the app."

---

## 3. Promotional text (170 max) — LOCKED

```
Make a room, share the six-character code and fill the table. Games Room sends the reminders and keeps the score, so you can sit down and play.
```

143 characters. Editable without a new submission, so it is the field to rotate
for season changes.

---

## 4. Keywords (100 max) — LOCKED 2026-11-08

```
poker,host,friends,score,keeper,tracker,board,card,rsvp,invite,club,season,ladder,weekly,mates
```

94 characters, 15 terms, no spaces. Do not repeat words already in the name or
subtitle ("games", "night"): App Store Connect indexes those separately and a
repeat burns characters.

Evidence behind the pick (AU App Store, 2026-11-08): "games night"/"game night"
returns party-card apps (5 Second Rule 382 ratings, Cheers 6398, Wavelength
1697). The planner/tracker space is nearly empty (Games Night Planner 0, Klack
0, Poker Night: Home Game Tracker 0, Score Keeper for Game Night 15).

6 characters are spare. `,hi-lo` fills them exactly. Not applied, because the
keyword set is locked.

---

## 5. Support URL

```
https://gamesroom.nateterrence.net/support
```

Live, HTTP 200, verified 2026-11-11. The page lists support@gamesroom.app and
states what support can and cannot do.

## 6. Marketing URL

```
https://gamesroom.nateterrence.net
```

Live, HTTP 200, verified 2026-11-11.

## 7. Privacy policy URL

```
https://gamesroom.nateterrence.net/privacy
```

Live, HTTP 200, verified 2026-11-11. Rendered from `docs/privacy-policy.md` via
`website/privacy.html`. Nothing needs to be hosted.

## 8. Copyright

```
© 2026 Nathan Maxwell
```

Flagged below: if the app is held by a company rather than Nathan personally,
this string must name that entity.

## 9. Contact info

```
First name: Nathan
Last name:  Maxwell
Email:      support@gamesroom.app
```

The email is the one published on the support page (`website/support.html`),
not a `gamesroom.nateterrence.net` address. App Review uses this address, so it
has to be a mailbox that is actually read.

---

## 10. Age rating

**Recommended: 4+**, with "Simulated Gambling" answered **None**.

Apple's tiers changed on 2025-07-24: 4+, 9+, 13+, 16+, 18+. The old 12+ and 17+
brackets are gone, so the V0.43 draft's "12+" no longer exists as an answer, and
the new questionnaire is mandatory for submissions (deadline was 2026-01-31).

Answer sheet:

| Questionnaire item | Answer | Why |
|---|---|---|
| Gambling (real money or convertible currency) | None | No payment rails in the app. No card, no bank, no wallet, no payout. |
| Simulated Gambling | None | The app does not run or simulate a game of chance. No deal, no spin, no RNG. The table plays with physical chips and the app records the ledger afterwards. |
| Contests | Infrequent | Season standings and awards. Apple allows infrequent contests at 4+. |
| User-generated content | Yes | Room names, display names, event titles, host notes. Apple allows UGC at 4+. |
| Messaging and chat | No | None. No DMs, no room chat. |
| Advertising | No | None. |
| Social media | No | None. |
| Unrestricted web access | No | No in-app browser. |
| Loot boxes | No | No IAP at all. |
| Medical or wellness | None | None. |
| Violence, sexuality, profanity, drugs | None | None. |

Why not "Simulated Gambling: Infrequent" to be safe: **in Australia that answer
is an R 18+ rating.** Apple's AU regional table maps "Infrequent simulated
gambling" to R 18+ regardless of the global rating (Apple, age ratings values
and definitions, read 2026-11-11). Australia is the launch market. Answering a
question affirmatively that is not true, and paying an 18+ gate at home for it,
is a bad trade.

If App Review queries the call, the fallback is one questionnaire change:
Simulated Gambling = Infrequent → 13+ globally, R 18+ in Australia. Do not
change it pre-emptively.

---

## 11. Pricing

```
Free
```

No in-app purchases. No subscriptions. No ads. The Casino pack's chips are an
in-app ledger currency with no purchase path, which is why Pricing stays
"Free" and Financial Info stays "Data not collected".

## 12. Availability

Launch: **Australia and United States.** Both territories, same submission.
Other territories: **all**, once the first 1.2.4 review passes.

Why AU and US first: AU is where the rooms and the reviewers' first users are,
and US is the second-largest English store. Territory availability costs
nothing and adds no review risk, so expanding to all territories after the first
pass is a checkbox, not a submission.

---

## 13. App Privacy ("nutrition label")

Tracking: **No.** `GamesRoom/PrivacyInfo.xcprivacy` sets `NSPrivacyTracking` to
false, and nothing in the app fingerprints or shares data with a data broker.

| Apple data type | Collected | Linked to you | Used for tracking | Purpose |
|---|---|---|---|---|
| Contact Info → Name | Yes | Yes | No | App Functionality |
| User Content → Other User Content | Yes | Yes | No | App Functionality |
| Identifiers → User ID | Yes | Yes | No | App Functionality |
| Usage Data → Product Interaction | Yes | Yes | No | App Functionality |
| **Financial Info** | **Data not collected** | — | — | — |
| Health & Fitness | Data not collected | — | — | — |
| Location | Data not collected | — | — | — |
| Contacts | Data not collected | — | — | — |
| Browsing History | Data not collected | — | — | — |
| Search History | Data not collected | — | — | — |
| Diagnostics | Data not collected | — | — | — |
| Purchases | Data not collected | — | — | — |
| Sensitive Info | Data not collected | — | — | — |

What each "Yes" is:

- **Name**: the display name a member chooses, shown to their rooms.
- **Other User Content**: room names, event titles, host notes.
- **User ID**: the opaque identifier Sign in with Apple returns. No email is
  ever seen or stored.
- **Product Interaction**: RSVPs, seat claims, scores, season deltas, awards,
  pack enablement. Stored in Supabase, scoped per room by row-level security.

"App Functionality" only, no "Analytics", no "Advertising", no "Personalisation":
there is no analytics SDK, no ad SDK and no recommender.

**Discrepancy to fix before upload.** `GamesRoom/PrivacyInfo.xcprivacy` ships
with `NSPrivacyCollectedDataTypes` as an empty array. That under-declares the
four rows above. Apple compares the manifest to the label, and an empty array
next to a filled-in label is the kind of thing that gets a metadata rejection.
The manifest needs the same four data types added, or the label has to be
emptied, and emptying it would be false (the data is in Supabase). Fix the
manifest, not the label.

---

## Review notes (paste-ready appendix)

```
Games Room is invite-only and every surface sits behind a room membership. To
review, sign in with Apple and join the demo room:

Join code: [RE-MINT BEFORE SUBMITTING]

The demo room has a host, two members, and a night with a Casino pack so the
seat, RSVP, deposit and ledger surfaces are populated. Claim a seat to see the
member flow; end the night to see the settle and recap flow.

Chips in the Casino pack are an in-app ledger currency. No real money is
collected, held, transferred or paid out anywhere in the app, and no value
leaves it. No card, bank or wallet screen exists.

No login credentials are needed beyond Sign in with Apple.
```

The join code is single-use. The seed room from 2026-08-27 (`WSBXS4`) has been
spent. Mint a fresh code and paste it before submitting.

---

## NEEDS USER INPUT

Seven items, and only the first four block a paste.

1. **Copyright entity.** Currently "© 2026 Nathan Maxwell". If the app is held
   by a company, this must name the company that owns the rights.
2. **support@gamesroom.app.** It is published on the support page and it is the
   address App Review will use. Confirm the mailbox exists and is read. I cannot
   verify a mailbox from here.
3. **Age rating sign-off.** The recommendation is 4+ with Simulated Gambling =
   None. The alternative is 13+ global and R 18+ in Australia. This is a
   judgement call about how App Review will read the Casino pack, so it is
   yours, not mine.
4. **Reviewer join code.** Needs a fresh six-character code before submission.
5. **Mascot name.** The card says "Jodie". The app has no Jodie: the default is
   `Tally` (`GamesRoom/.../MascotConfig`, `defaultName = "Tally"`) and the name
   is user-settable per room. The description therefore names no mascot, which
   is also the safer listing copy, since a named mascot invites a reviewer to
   look for it. Say if you want a name in the listing.
6. **hi-lo.** The amendment's fixed sentence names poker, blackjack and hi-lo.
   The in-app Casino how-to says "poker, blackjack, or anything chip-based".
   Keeping hi-lo is fine. Saying so in the listing promises a game the app
   explicitly does not host, so the wording is worth one read.
7. **PrivacyInfo manifest.** Needs the four data types added (section 13). This
   is a build change, not a listing change, so it belongs to whoever ships
   1.2.4.

---

## Out of scope here

Registering the app record, uploading the build, and the website marketing copy.
This file stops at the paste.
