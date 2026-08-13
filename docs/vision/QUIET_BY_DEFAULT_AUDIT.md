# Games Room — Quiet-by-Default Audit

Date: 2026-08-13
Owner: writing (audit). Build implements deletions/quiet-changes after.
Source: V0.53 vision memo (docs/vision/V0.53_VISION.md), GamesRoom SwiftUI surface scan.

## Summary

The app is already most of the way to quiet-by-default. No streaks, no
feed, no news, no DMs, no chat exist in the code. The room list, tonight's
room, the standings, and the working hand are the surfaces that matter, and
they are the surfaces that exist.

There is exactly one hard violation, and it is a big one: **notification
spam**. Every member gets three pushes per event (on-create, T-48h,
morning-of), the on-create push fires for everyone regardless of RSVP state,
and notification permission is requested at join, before the user has seen
any value. That is the build work.

Two soft violations need a design decision, not a deletion: the social-proof
caption on the rooms list, and the season awards. Both are argued below.

---

## Part 1 — Surface enumeration and the twice-a-week test

Test: "Would you still build this if your users checked the app twice a
week?" A PASS means the surface earns its place at that cadence. A FAIL
means it only earns time-in-app.

| # | Surface | Location | Verdict | Why |
|---|---------|----------|---------|-----|
| 1 | Rooms list | RoomPage | PASS | Core. The twice-a-week user opens this, sees their rooms. |
| 2 | Last-viewed hero ("Continue") | RoomPage | PASS | One-tap resume to tonight's room. Accelerator, not a feed. |
| 3 | Room detail (event, seats, claim/release, briefing) | RoomDetailView | PASS | This is "tonight's room". The night-of surface. |
| 4 | Seat grid + claimed-seats caption | RoomDetailView | PASS | Logistics the night needs. "Thea, Marco claimed." |
| 5 | Rooms-list social-proof caption | RoomPage | SOFT FAIL | Same data, but surfaced on every open. Pulls "who's in?" attention. See Part 3. |
| 6 | Standings / leaderboard + trajectory | LeaderboardRow, TrajectorySparkline | PASS | "This week's standings". A stated default open. Grows with play, not app time. |
| 7 | Working hand (casino play) | WorkingHand | PASS | Night-of active play. Pointless when quiet, correct when live. |
| 8 | Season / arc (subtitle, close ceremony) | Season, SeasonStatus | PASS | Season-cadence memory. The durable social. |
| 9 | Season awards (phoenix/veteran/whale/drowning) | SeasonAward, AwardType | SOFT FAIL | Season-close ceremony, not daily pull. Drowning is private-to-member (already correct). See Part 3. |
| 10 | Mascot voice / bubbles / footer captions | MascotEngine, MascotBubble | PASS | Decorative voice. Night-of and ceremony. Not a metric. |
| 11 | Pack store / pack detail | PackStoreView, PackDetailView | PASS | Host setup. A quiet surface; visited when planning, not daily. |
| 12 | Room system-event banners (pack removed/installed, season closed) | RoomSystemEvent | PASS | Rare, quiet, informative. |
| 13 | Confetti, drowning badge, haptics | ConfettiBurst, DrowningBadge, Haptics | PASS | Celebratory moments, not persistent pulls. |
| 14 | Notifications — briefing trio (on-create, T-48h, morning-of) | NotificationDispatcher | **FAIL** | Three pushes per event per member, on-create fires for everyone, default-on. See Part 2. |
| 15 | Notification permission prompt at join | JoinRoomSheet | **FAIL** | Asked before value is proven. See Part 2. |
| 16 | Settings / app settings | SettingsPage, AppSettingsView | PASS | Required. |
| 17 | Sign-in (Apple) | SignInView | PASS | Required gate. |
| 18 | Create/join room sheets | CreateRoomSheet, JoinRoomSheet | PASS | One-time setup. |
| 19 | Live Activity / score snapshot | ScoreLiveActivityDriver, ScoreSnapshotStore | PASS | Night-of live score on the lock screen. |

Verdict count: 15 PASS, 2 SOFT FAIL, 2 FAIL.

---

## Part 2 — Delete / redesign list

### HARD: Notification spam (surface 14, 15)

**What exists now:** `NotificationDispatcher.scheduleBriefingTrio` fires
three pushes per event per member — on-create (immediately, LLM-mascot voice),
T-48h, morning-of. The on-create push is sent to every member regardless of
RSVP state, so a user who declined, or who has never opened the room, still
gets a push. Authorization is requested globally at join (before the user
has seen the app work), and once granted, every room's events schedule the
full trio with no per-room or per-event opt-out.

**Redesign, not deletion.** The pushes themselves are night-of logistics and
are on the right side of the vision when opt-in. The problem is that they are
default-on and not gated by room or event. See the policy in Part 4.

**Build work:**
- Make every notification opt-in per room, default off. A member who joins a
  room gets zero pushes until they turn that room's notifications on.
- Remove the on-create push to members who have not opted in. The on-create
  push may only reach members who opted into that room's notifications AND
  have not declined the event.
- Move the notification permission prompt off the join path. Ask on the
  night of a game, at the moment the member needs a logistics push, not at
  sign-up. If they deny, the briefing slot inside the app remains the
  fallback (it already is).
- Host-pinned events get the one-tap-to-mute: when a host pins an event, any
  member who receives a push for it can mute that event in one tap from the
  notification or the room screen, and the mute sticks.

### SOFT: Rooms-list social-proof caption (surface 5)

**What exists now:** `RoomPage` shows a caption under each room name like
"Thea, Marco claimed." whenever that room has a not-yet-started active event.

**Why it is soft, not hard:** It is the same night-of logistics data that the
room detail correctly surfaces, and it is only present when an event is
upcoming. It is not a feed and not a metric.

**The risk:** On the rooms list — the surface a twice-a-week user opens most —
a "who's in?" caption is the one line on screen that can nudge FOMO. It is
the closest thing the app has to a pull that grows with attention.

**Recommendation:** Keep it only for events that are **tonight or tomorrow**.
If the event is further out, or already started, show nothing (or "Tap to
open"). This keeps the night-of logistics without the ambient "people are
claiming" hum all week. Low build cost — one date check.

### SOFT: Season awards (surface 9)

**What exists now:** `SeasonAward` rows (phoenix, veteran, whale, drowning)
rendered at season close. `drowning` is already correctly private to the
recipient.

**Why it is soft, not hard:** Awards land once per season, not per open.
They are the arc memory, the durable social the vision memo wants. They do
not grow with app time; they grow with play.

**The risk:** If awards become a persistent card on every room open ("your
awards!") they drift toward a badge shelf. They should be ceremony, not
chrome.

**Recommendation:** Keep, but render awards only at the season-close
moment — in the close ceremony and the season history — not as a standing
card on the quiet room screen. No badge count, no "3 new awards" nudge.

---

## Part 3 — What is already right (no change)

- **No streaks.** Zero matches in the codebase. Do not add them.
- **No points-for-the-app.** The "points" in the code are chip balances and
  settlement attestations — game money, the ledger. They grow with play at
  the table, not with time in the app. Correct.
- **No feed, no news.** The room list and room detail are destinations, not
  streams.
- **No DMs, no chat.** Nothing simulates conversation. Correct.
- **Standings and working hand are the two "other" default opens** the brief
  names, and both exist and pass.

---

## Part 4 — Notification schedule policy

Purpose: per-room opt-in, default off, quiet except when the game is near.

**Defaults**
- New room membership: notifications OFF. Zero pushes until the member opts in.
- Opt-in is per room, never global. Turning on "Friday Night Hold'em" does
  not turn on "Campaign Night".
- Opt-in lives in the room, next to the event, so the member sees it in
  context: "Remind me about this room's nights."

**Cadence once opted in**
- T-48h: logistics reminder for the next event. Skipped if the member declined.
- Morning-of (09:00 local): final logistics push. Skipped if declined.
- No on-create push to opted-out members. The on-create push, where it still
  reaches an opted-in member, is only for members who have not declined.
- No recap pushes, no "you haven't been back" nudges, no engagement
  re-engagement. None of these exist and none may be added.

**Host-pinned events**
- When the host pins an event (calls it the night), it is the one thing that
  may reach members who are opted out — because it is the one thing that
  actually matters to showing up.
- Host-pinned events carry one-tap-to-mute: any member who gets the push can
  mute that specific event with one tap, from the notification or the room
  screen. The mute persists for that event.
- A mute is per event, not per room, and does not switch the room's
  notification preference.

**Permission prompt**
- Never request notification permission at join.
- Request it at the moment it earns its keep: the first time a member needs a
  logistics push, on the night of a game. The in-app briefing slot stays the
  documented fallback for members who deny.

**The test the policy must hold:** after the night is over, a member's phone
is silent. Nothing fires between events. Quiet is the default; a push is the
exception that earns itself by being about the next game at the table.

---

## Handoff to build

Implement in this order:
1. Per-room opt-in, default off (new membership = zero pushes). Gated in
   `NotificationDispatcher.scheduleBriefingTrio` / `RoomService`.
2. Remove on-create push to opted-out members; on-create only reaches
   opted-in, non-declined members.
3. Move the permission prompt off `JoinRoomSheet`; ask at night-of need.
4. Host-pinned event push with one-tap-to-mute (per event, persistent).
5. Rooms-list caption: show only for tonight-or-tomorrow events.
6. Awards: render at season close / history only, not as a standing card.
