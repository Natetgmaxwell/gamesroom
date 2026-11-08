# Games Room — Notification timing audit (read-only)

- Code audited: studio `~/Projects/games-room`, `main` @ febbae3 (shipped 1.2.3). Line numbers are for that commit.
- Fix branch checked: mini stale checkout, `fix/notif-claimed-state` @ 5649888 (base 209b78c).
- Method: I read the code over SSH. Nothing was built, run or tested on a device. Where a claim depends on iOS runtime behaviour, it says so.

## 0. Inventory: every notification the app can produce

| # | Surface | Kind | Trigger (code) | Fire time | Recipient |
|---|---|---|---|---|---|
| A | On-create briefing | local `UNCalendarNotificationTrigger` | `RoomService.addEvent` (host device, :949-981), `RealtimeEventService.handleEventInsert` (:117-174), room open `scheduleActiveEventOnCreateIfMissing` (:1882-1918), opt-in toggle (:1863), RSVP upsert (:871-889) | `now + 1s` (NotificationDispatcher.swift:154) | every opted-in, non-muted, non-declined member *in the cadence map*, scheduled on **the device that runs the code** |
| B | Week-before (T-168h) | local | same paths | `playedAt − 168h`, only if still in the future (:161, :278) | same |
| C | "In a few days" (T-84h, id `t48h`) | local | same paths | `playedAt − 84h`, only if still in the future (:162, :306) | same |
| D | Morning-of | local | same paths | 09:00 device-local on the event day. If that has passed: `playedAt − 30m`, or `now+1s` (:168-184) | same |
| E | Joined-late catch-up | local | `redeemJoinCode` → `scheduleCatchUpIfNeeded` (RoomService:338, :358-378) | `now + 1s` (Dispatcher:422) | the joiner, only if `room.notificationsEnabled` |
| F | Anchor push | APNs, `time-sensitive` | trigger `event_rsvps_anchor_push` (105_anchor_push.sql:262-318) → `anchor-nudge-push` | the instant the newcomer claims, or the instant the inviter releases | the inviter |
| G | Question Box turn | APNs, `time-sensitive` (question-turn-push/handler.ts `composePayload`) | AFTER INSERT on `question_turns` (097:958-1011). Turns come from `question_box_advance` (097:740-796), driven by pg_cron every minute if installed (097:846-850), otherwise lazily by the app's `question_box_tick` | opener at `played_at`, then every N min (default 20) until `settled_at` | the reader (opener = host) |
| H | Score Live Activity | ActivityKit, app-local | `ScoreLiveActivityDriver.apply`, called **only** from `RoomDetailView.refresh` (:1243-1247) | starts or ends at the next RoomDetailView refresh after `playedAt` / `settledAt` | the device that opened the room |
| I | Widget / Watch glance | WidgetKit timeline | `ScoreSnapshotStore.write` on room refresh; `Timeline(policy: .after(next))` (GamesRoomWidgets:63-67) | passive; never alerts | — |
| J | Calendar row | EventKit | `CalendarService.addEvent`, called only from `RoomService.addEvent` (:938). Updated on note/venue edit (:999). Removed on room delete (:1026) | no `EKAlarm` set (CalendarService.swift:93-94, 130-131 set only start/end), so the user's calendar default alert applies | **only the device that created the event**, i.e. the host |
| — | Settle, recap, season, host "members claimed" digest, escrow/deposit, kick, event cancel | **none exist** | grep for `UNUserNotificationCenter`, `UNNotificationRequest`, `Activity.request`, `EKAlarm` finds only NotificationDispatcher, QuestionBoxPush, ScoreLiveActivityDriver, MascotNotificationAttachment | — | — |

One global behaviour affects every row. `GamesRoomAppDelegate.userNotificationCenter(_:willPresent:)` (QuestionBoxPush.swift:54-62) returns `[]` for **every** notification, so nothing ever shows a banner while the app is in the foreground.

---

## Findings

### 1. Members who don't open the app between creation and the night get no reminders at all
- **Severity:** High
- **Where:** RealtimeEventService.swift:117-174; RoomService.swift:1882-1918 (room-open path); RoomDetailView.swift:1325-1344
- **What happens now:** Every briefing notification is a *local* notification scheduled on the member's own device. The device only schedules when (a) its realtime websocket receives the `events` INSERT, which needs the app to be running at the moment the host creates the event, or (b) the member later opens *that room* (`loadActiveIfNeeded` → `scheduleActiveEventOnCreateIfMissing`). No server path sends a briefing. The edge functions are only `anchor-nudge-push`, `mascot-voice`, `question-turn-push` and `scan-settle`.
- **Why it's wrong for the user:** The member who most needs the T-168h / T-84h / morning-of touch is the one who isn't checking the app, and that member gets nothing. The engaged member who opens the room anyway gets the full set. The cadence works backwards from Nick Gray's intent. "The app brings the people to the table" fails for exactly the people it has to bring.
- **Proposed fix:** Send the briefing cadence from the server. The APNs plumbing already exists: the `device_tokens` table, `register_device_token`, `question-turn-push/apns.ts`, and the vault-secret pattern from 097 and 105. Add a `briefing_push_ledger(event_id, user_id, kind)` table plus a cron or lazy tick that selects due (event, member, kind) rows and composes the body from **current** RSVP state at send time. That also removes the baked-body bug class entirely. Keep local scheduling only as an offline fallback, de-duplicated against the server through the same identifiers.
- **Effort:** L

### 2. The on-create prompt is effectively never seen
- **Severity:** High
- **Where:** NotificationDispatcher.swift:154 and :238-272; QuestionBoxPush.swift:54-62
- **What happens now:**
  1. `let onCreateFireAt = now.addingTimeInterval(1)` is computed **before** the per-member loop. Inside the loop, for every member, the code awaits `MascotEngine.generateVoiceLLM(...)`, an edge-function round trip, before `schedule(...)`. The trigger is a full `UNCalendarNotificationTrigger(dateMatching: [.year…, .second])`. Once the LLM call takes more than 1 second, that date is already in the past. With `repeats: false` it has no next fire date, so the request is accepted and never delivered. **UNVERIFIED on device.** This is standard UNCalendarNotificationTrigger semantics.
  2. Even when it does fire, it fires 1 second after scheduling. Both member-side scheduling paths only run with the app in the foreground: the realtime echo, and the room open. `willPresent` returns `[]`, so the banner is suppressed.
- **Why it's wrong for the user:** The locked rule is "on-create is the ONLY prompt". In practice the only prompt is either dropped or swallowed. Members learn about the night from the T-168h reminder at best, or from finding #1's "never".
- **Proposed fix:** Make on-create a server push sent when the event row is inserted, to opted-in members other than the host. Exclude members who are online in that room right now: they see the in-app card. If a local fallback stays: compute `fireAt` *after* the body is ready, use `UNTimeIntervalNotificationTrigger(timeInterval: 1)`, and have `willPresent` return `[.list]` for briefing kinds so the prompt at least lands in Notification Center.
- **Effort:** M (server push), S (local patch)

### 3. Other members' reminders are scheduled on the host's (and the claimer's) phone
- **Severity:** High
- **Where:** RoomService.swift:949-981 (`addEvent`) and :844-889 (`upsertEventRSVP`)
- **What happens now:**
  - `addEvent` builds `cadence` over the whole `roster` and passes `optedInMemberIds = roster.filter { $0.notificationsEnabled }`. `get_room_members` returns `notifications_enabled` for every member (102_roster_caller_guard.sql:34), and the identifiers include each member's `userId` (Dispatcher:557). So the **host's** device schedules one T-168h, one T-84h and one morning-of *per opted-in member*, each addressed "Tally: Sam, …", "Tally: Jo, …".
  - `upsertEventRSVP` does the same fan-out on the claimer's device and stamps every member with the caller's own state: `acc[member.userId] = rsvpByEvent[event.id] ?? .unclaimed` (:848-850).
- **Why it's wrong for the user:** With 8 opted-in members, the host's phone fires 8 near-identical banners at each cadence slot. That is a burst at exactly the "quiet by default" moments. Meanwhile the actual members get nothing from this path (see #1).
- **Proposed fix:** Schedule only for `callerId`. The fix branch's `BriefingReconciler` already does this ("A device schedules for its signed-in user only — no roster fan-out").
- **Effort:** S (comes with the fix branch)

### 4. The T-84h reminder lands in the middle of the night for afternoon events
- **Severity:** High
- **Where:** NotificationDispatcher.swift:162 `let t48FireAt = playedAt.addingTimeInterval(-84 * 3600)`
- **What happens now:** 84h is 3.5 days, so the reminder fires at the event's clock time minus 12 hours. Any start between 12:00 and 21:00 fires between 00:00 and 09:00:
  - Saturday 2pm → Wednesday 2am
  - Sunday 12pm → Wednesday 00:00
  - the default Friday 7:30pm seed → Monday 7:30am (borderline)
  
  T-168h keeps the event's clock time, so it is fine for evening events. Neither slot has a quiet-hours clamp.
- **Why it's wrong for the user:** A 2am "in a few days" ping gets dismissed half-asleep. It can't change anyone's plans, and it teaches the user that the mascot is noise.
- **Proposed fix:** Anchor to the calendar, not to hours. T-84h becomes "3 days before, at 18:00 local", and T-168h becomes "7 days before, at 18:00 local". Clamp every reminder to 09:00–20:00 local. If the clamped time is already past, skip the slot. Apply the same rule in `BriefingReconciler.plan`, which copied the offsets unchanged.
- **Effort:** S

### 5. The morning-of reminder ignores the start time
- **Severity:** Med
- **Where:** NotificationDispatcher.swift:168-184
- **What happens now:** It always targets 09:00 device-local. A 9am brunch-games event gets "today" at 09:00, as it starts. An 8am event gets it **after** the start: `nineAM > now` is true, so it fires at 09:00. If the event is created on the day after 09:00, the reminder falls back to `playedAt − 30m`, which is the "already leaving the house" moment and right after the on-create prompt.
- **Why it's wrong for the user:** For non-evening events the reminder comes too late to change behaviour. For same-day creations it double-pings: on-create, then a reminder hours later.
- **Proposed fix:** `morning = min(09:00, playedAt − 3h)`, floored at 07:00. Skip it if it's under 2h after on-create, or if `playedAt − 30m` would be the only option, because on-create already covered a same-day night.
- **Effort:** S

### 6. Back-to-back pings when an event is created just outside a slot
- **Severity:** Low
- **Where:** NotificationDispatcher.swift:278, :306, :333
- **What happens now:** Past slots are correctly skipped (`if t168FireAt > now`). There is no burst. But there is no minimum gap. An event created 85h out gets on-create, then T-84h one hour later. One created 169h out gets on-create, then T-168h one hour later.
- **Why it's wrong for the user:** Two pings an hour apart for the same night read as spam.
- **Proposed fix:** Drop any reminder that falls within 24h of on-create, and drop T-84h if it is within 24h of T-168h.
- **Effort:** S

### 7. Opening the room undoes mutes, declines and claims, and can re-fire on-create
- **Severity:** High
- **Where:** RoomService.swift:1882-1918; RealtimeEventService.swift:161-173; Dispatcher:364-369, :580-587
- **What happens now:**
  - `hasPendingOnCreate` checks only **pending** requests. On-create fires 1s after it is scheduled, so it is never pending. Every room open therefore calls `scheduleBriefingTrio(... perMemberCadence: [callerId: .unclaimed], mutedMemberIds: [], hostNote: nil ...)`.
  - That re-adds T-168h, T-84h and morning-of for:
    - a **declined** member (the locked rule says declined is terminal silence)
    - a **muted** member (the mute is ignored)
    - a **claimed** member, with the unclaimed claim clause (`MascotEngine.unclaimedClause`, :474-476)
  - On-create is guarded only by `deliveredNotifications()`. Once the user taps or clears that banner, it drops out of the delivered list, and on-create fires again ("Open the room to claim your seat") on the next room open, RSVP change or opt-in toggle.
- **Why it's wrong for the user:** It breaks all four etiquette rules at once. A member who said no gets asked again. A member who said yes gets told to claim. A member who muted gets pinged.
- **Proposed fix:** Rebase the fix branch (see §FB). It replaces every path with `reconcileBriefing`, which plans from the canonical RSVP plus a persistent on-create fired-ledger (`UserDefaultsOnCreateLedger`).
- **Effort:** M (rebase + test)

### 8. Unmuting an event never brings its reminders back
- **Severity:** Med
- **Where:** RoomService.swift:1936-1965
- **What happens now:** `setEventNotificationsMuted` always ends with `cancelEventCadence(eventId:)`, which only cancels. Unmuting cancels too and schedules nothing. Reminders come back only at the next room open, and then in the wrong state (#7).
- **Why it's wrong for the user:** Someone who unmutes on Tuesday still gets no T-84h.
- **Proposed fix:** After any mute toggle, reconcile from the current state (the fix branch does this at its line 1761).
- **Effort:** S

### 9. Claiming through the escrow or waived path leaves the "claim your seat" reminder in place
- **Severity:** Med (known)
- **Where:** RoomService.swift:1995-2015
- **What happens now:** When the room's deposit trigger is escrow, `claimSeat` calls `store.claimSeatWithDeposit` and returns without `upsertEventRSVP`, so nothing reschedules. `claimSeatWaived` (host-side) also skips rescheduling. The pending T-84h and morning-of reminders keep the unclaimed claim clause.
- **Why it's wrong for the user:** The person who just put a deposit down is told to claim.
- **Proposed fix:** Call `reconcileBriefing(eventId:)` after both paths (fix branch, lines 1821 and 1843). Better still, compose the body at send time on the server (#1).
- **Effort:** S

### 10. The host's note almost never reaches the reminders it was written for
- **Severity:** Med
- **Where:** RoomService.swift:966-981 (`addEvent` passes no `hostNote`); RealtimeEventService:171 and RoomService:1913 (`hostNote: nil`); `updateEventMemberFields` (:987-1012) doesn't reschedule
- **What happens now:** "Host's note: …" (Dispatcher:477-479) is appended only on a reschedule triggered by an RSVP upsert, and only if the note already existed by then. Editing the note in EditEventSheet (:104 → `updateEventMemberFields`) updates the calendar row but not the pending reminders.
- **Why it's wrong for the user:** Logistics like "bring $20" or "new address" are what T-84h and morning-of exist to carry, and they go stale or never appear.
- **Proposed fix:** Reconcile pending reminders on every note or venue change. On the server path (#1), read the note at send time.
- **Effort:** S

### 11. Reminders keep firing for kicked members, deleted rooms and hidden members
- **Severity:** Med
- **Where:** `kickMember` (RoomService.swift:704-758); `deleteRoom` (:1020-1040)
- **What happens now:**
  - `kickMember` changes only the server and the host's cache. Nothing reaches the kicked member's device.
  - `deleteRoom` removes calendar rows on the host's device but never calls `cancelBriefingTrio`, on the host's device or anyone else's.
  - No device runs a sweep that cancels pending requests whose `event_id` (stored in `userInfo`, Dispatcher:593-596) is no longer an active event.
  - `addEvent`'s roster fan-out (#3) also ignores `hiddenFromUserIds`.
  - There is no event-date edit (EditEventSheet only edits note and venue) and no delete-event method in RoomService, so the "moved night" case can't happen. A host who wants to move a night has no supported way to do it. **UNVERIFIED** whether a delete-event RPC exists outside RoomService.
- **Why it's wrong for the user:** A kicked member still gets "Friday night is today" from a room they've been removed from, which is socially awkward. Every member of a deleted room gets reminders for a night that no longer exists.
- **Proposed fix:** On app foreground, have `refresh()` sweep pending briefing requests and cancel any whose `event_id` isn't in `activeEventByRoom` for a room the user is still in. Add a silent APNs push (`content-available`) on kick and room delete. With #1 the server simply stops sending.
- **Effort:** M

### 12. The opt-in prompt never appears at the moment a member commits
- **Severity:** Med
- **Where:** RoomDetailView.swift:608-612 (prompt gate `activeEvent == nil`); RoomService:359 (catch-up gated on `notificationsEnabled`); 105_anchor_push.sql:206 (anchor push gated on the inviter's `notifications_enabled`)
- **What happens now:** Notifications are off per room by default (Member.swift:95, 129, `?? false`). The one-time opt-in card shows only while **no** night is scheduled. A newcomer who joins with a code for the upcoming night (the usual way people join) never sees it. They don't get the catch-up push. Their inviter gets the anchor push only if the inviter separately opted in.
- **Why it's wrong for the user:** The highest-value moment to offer a reminder is right after "Claim seat". The app offers it in the one state where it's least useful.
- **Proposed fix:** Show a single inline ask after a member's first claim in a room: "Want a nudge the morning of?" Yes = enable for that room. The existing `CalendarVoiceLineRow` post-claim slot is the right place (RoomDetailView:635-639). Request iOS authorization at that tap so the OS prompt has context.
- **Effort:** S

### 13. The anchor push fires the instant someone claims, at any hour, and breaks through Focus
- **Severity:** Med
- **Where:** 105_anchor_push.sql:262-318 (fires inside the RSVP trigger); anchor-nudge-push/handler.ts `composePayload` (`"interruption-level": "time-sensitive"`); `ROOM_TIME_ZONE = "Australia/Brisbane"` hardcoded (handler.ts:18-24)
- **What happens now:** A newcomer who claims at 11:40pm sends their inviter a time-sensitive "Sam's coming Friday. Are you?" immediately. Time-sensitive breaks through Focus and Sleep. The weekday is computed in Brisbane time regardless of where the room is.
- **Why it's wrong for the user:** The nudge is meant to change behaviour ("go claim too"), and it arrives when the inviter can't act on it, through a Focus mode they chose. It isn't time-critical; the night is days away.
- **Proposed fix:**
  - Queue the ledger row, then deliver at the next 09:00–20:00 window in the room's time zone, but never later than T-24h.
  - Use the `active` interruption level.
  - Re-check "inviter still unseated" at send time, because they may have claimed in the meantime.
  - Add a `rooms.time_zone` column (set from the host's device) and use it here and in #4 and #5.
- **Effort:** M

### 14. The Question Box opener fires at the scheduled start, before anyone is there
- **Severity:** Med
- **Where:** 097_question_box.sql:756-763 (`played_at > p_now` → wait; then opener → `question_box_host`); fallback rotation 097:687-692
- **What happens now:** The opener is created as soon as `played_at <= now`, so the host's phone buzzes (time-sensitive) at 7:30:00 exactly. Under the 2-hour party format, people trickle in, and 7:30 is when the host is at the door. For packs with no bank, the rotation falls back to "claimed RSVPs in claim order", which includes people who haven't arrived or never come. They get the reader push, and an absent reader means a dead turn every 20 minutes.
- **Why it's wrong for the user:** The phone comes out at the busiest host moment. Pushes go to people who aren't at the table.
- **Proposed fix:** Gate the opener on 3 or more arrivals (withdrawals or `check_in_seat`), with `played_at + 30m` as the fallback. Build the no-bank rotation from checked-in members (`seat_deposits.checked_in` / arrival chips), not from claims.
- **Effort:** M

### 15. Turns can keep pushing readers long after the night ends if the host forgets to settle
- **Severity:** Low (conditional)
- **Where:** 097:820-850 (cron tick filters `played_at > now() - 24h and settled_at is null`); 081 (`auto_close_hours` default 8, applied by a lazy RPC; 080 says "no pg_cron")
- **What happens now:** Turns stop only at `settled_at`. If pg_cron is installed on live, an unsettled night keeps creating time-sensitive reader pushes every 20 minutes until the lazy auto-close runs or 24h pass, which can include 1–4am. If pg_cron is absent, the lazy tick only runs while someone has the QB view open (QuestionBoxViews.swift:68, :194), which limits the damage. **UNVERIFIED:** whether pg_cron is enabled on the live project (I was not allowed to touch the DB).
- **Proposed fix:** In `question_box_advance`, also stop when `p_now > played_at + auto_close_hours`, or when no turn has been read or passed in the last 60 minutes.
- **Effort:** S

### 16. The Live Activity starts late, ends late, and freezes its scores
- **Severity:** Med
- **Where:** RoomDetailView.swift:1243-1247; ScoreLiveActivityDriver.swift:39-90
- **What happens now:**
  - `apply` runs only inside the RoomDetailView refresh.
  - It **starts** at the first room refresh after `playedAt`, and never if the member doesn't open the room.
  - It **updates** only when *that* device refreshes. There are no push tokens and no `pushType`, so scores on the lock screen freeze between opens.
  - It **ends** only at that device's next refresh after `settledAt`. A member whose host settled at 11pm keeps a stale scoreboard on the lock screen until they reopen the app or the system cap removes it.
  - `staleDate: nil`.
  - The file header still says "never during play", which contradicts the shipped rule.
- **Why it's wrong for the user:** The locked rule is "scores ONLY while an event is active". In practice it shows stale scores after the event and none during it unless the phone is in hand, the opposite of "phone invisible".
- **Proposed fix:**
  - Request with `pushType: .token` and register the token.
  - Have `scan-settle` (or the score-save path) send an APNs `liveactivity` update or end event.
  - Set `staleDate = playedAt + autoCloseHours`.
  - Optionally use push-to-start (iOS 17.2+) at `playedAt` for claimed members.
- **Effort:** M/L

### 17. Calendar rows reach only the host, so members' calendar alerts never fire
- **Severity:** Med
- **Where:** RoomService.swift:927-947 (the only `CalendarService.shared.addEvent` call site in the app); CalendarService.swift:93-94
- **What happens now:** The calendar auto-add toggle is per member (`room.calendarAutoAdd`, "V0.86 — per-member toggle"). But the row is written only inside `addEvent`, on the creating (host) device. A member who turns the toggle on never gets a row: there is no add on claim, on realtime insert, or on room open. No `EKAlarm` is set, so even the host gets only their calendar's default alert, if any. **UNVERIFIED:** whether a member path exists in a view I didn't open. Grep across `GamesRoom/` found none.
- **Why it's wrong for the user:** The calendar is the most behaviour-changing "alert" there is, because it blocks the time. Members don't get it.
- **Proposed fix:** Write the member's row when they claim (and remove it on decline or release), from `claimSeat` / `upsertEventRSVP` when the member's toggle is on. Leave alarms at the calendar default to avoid doubling with the morning-of push.
- **Effort:** S/M

### 18. Remote pushes can't display for members who never opted into any room
- **Severity:** Med
- **Where:** ContentView.swift:153 (`registerForRemoteNotifications()` at sign-in); NotificationDispatcher.swift:68-96 (the only `requestAuthorization`, reached only through briefing or catch-up scheduling, which is gated on room opt-in)
- **What happens now:** The device token is registered for everyone at sign-in, but iOS alert permission is requested only on the opt-in path. A member who never opted in is still picked as the Question Box reader (`question-turn-push` doesn't check `notifications_enabled`). The push is sent and silently not shown. The host's opener has the same problem.
- **Why it's wrong for the user:** The rotation stalls at that reader for 20 minutes, until the next turn supersedes theirs.
- **Proposed fix:** Request authorization at the first claim (ties into #12) or when Question Box is enabled for a room the member is in. In `question_box_advance`, skip readers with no active token (a `device_tokens` lookup).
- **Effort:** S

### 19. The host never gets a headcount, the one alert the customer would act on
- **Severity:** Low (product gap, not a bug)
- **Where:** No such notification exists (inventory §0).
- **What happens now:** The host finds out who's coming only by opening the room. There is no settle, recap or season notification either. That fits the "quiet" rule.
- **Why it's wrong for the user:** "Host is the customer." The one ping that changes host behaviour (chase people, buy snacks, cancel) is the headcount at about T-84h. It is a one-person push, so it's allowed.
- **Proposed fix:** One host-only push at the corrected T-84h slot (#4): "5 in, 3 haven't said. Friday 7:30." Nothing for members.
- **Effort:** M (server-side, rides #1)

### 20. Tapping a briefing notification doesn't open the event
- **Severity:** Low
- **Where:** QuestionBoxPush.swift:64-69 (`didReceive` handles only `type == "question_turn"`)
- **What happens now:** Briefing notifications carry `kind` and `event_id` (Dispatcher:593-596), but a tap only launches the app. It doesn't route to the room or the Claim button. The anchor payload carries `room_id`/`event_id`, which is also unrouted. **UNVERIFIED:** whether a deep-link handler exists in ContentView via `onOpenURL`; none reads `userInfo["kind"]`.
- **Proposed fix:** Route `kind ∈ {on_create, t168h, t48h, morning_of, catch_up, anchor}` to that room's RoomDetailView, scrolled to the seat card.
- **Effort:** S

---

## §FB. Fix branch `fix/notif-claimed-state` @ 5649888: does it still apply, and what does it fix?

**Does it exist on the studio?** No. On the studio, `git cat-file -t 5649888` returns "Not a valid object name". 209b78c does exist there, and there are 75 commits in `209b78c..febbae3`. The branch has to be carried over (push from the mini, or cherry-pick by patch).

**What changed in the files it touches between 209b78c and febbae3** (`git diff --stat 209b78c febbae3`):
- `NotificationDispatcher.swift`: 8 lines, punctuation only (em-dashes removed from the on-create body and both titles). The fix rewrote this file (529 lines changed), so take the fix's version and re-apply the em-dash removal. Check that its bodies don't reintroduce "—".
- `RoomService.swift`: 174 lines changed, all additive Brought By / anchor-push methods (`cachedShowBroughtBy`, `anchorName`, `setAnchorPushEnabled` and so on). None of them touch scheduling call sites, so it should merge with routine conflicts.
- `RoomDetailView.swift`: about 1,016 lines changed on main; the fix touches 18. Expect hunk conflicts around `loadActiveIfNeeded`, but they're mechanical.
- `RealtimeEventService.swift`: unchanged on main in that range, so it applies cleanly. I didn't check `MascotEngine.swift` (8 lines in the fix).
- **Verdict:** it applies in spirit. Effort to rebase: M (conflicts in RoomDetailView and the dispatcher; re-run the 407-line `TestsBriefingReconcile.swift` harness).

**What it fixes:**
- **Wording / state (yes):**
  - plans from the canonical RSVP
  - declined → `[]`
  - claimed → no claim clause
  - on-create only when `.unclaimed` and not in the persistent ledger
  - escrow and waived claim paths reconcile (fix RoomService:1821, :1843)
  - mute toggles reconcile (:1761)
  
  That covers findings #7, #8 and #9.
- **Delivery (partly, as a side effect):**
  - removes the roster fan-out (#3)
  - drops the per-member `generateVoiceLLM` await before scheduling (no `generateVoiceLLM` in the fix's dispatcher), which removes the past-trigger race in #2(1)
- **Timing (no):** `BriefingReconciler.plan` keeps `playedAt − 168h`, `playedAt − 84h` and the identical `morningFireDate` (09:00 / `playedAt−30m` / `now+1s`). It doesn't address #1, #2(2) (foreground suppression), #4, #5, #6, #10–#18.

**Recommendation:** rebase and ship it as 1.2.4's correctness fix. In the same pass, change `plan`'s three fire-time lines (#4, #5, #6). That's about 30 lines in one pure, already-tested function. Treat the server-side cadence (#1) as the real timing fix in 1.2.5.

---

## Ranked top 5

1. **#1 Server-side briefing cadence.** Today, members who don't open the app get nothing, and those are exactly the people reminders exist for. The APNs plumbing from Question Box and the anchor push is reusable. L.
2. **#7 + #3 + #9 Rebase the fix branch onto febbae3.** Stops declined, muted and claimed members being re-prompted, and stops N banners on the host's phone. M.
3. **#4 (+ #5, #6) Calendar-anchored fire times with a 09:00–20:00 clamp.** T-84h currently fires at 2am for any afternoon event. Change it inside `BriefingReconciler.plan` during the rebase. S.
4. **#12 + #18 Ask for notifications right after the first claim.** Quiet-by-default currently means newcomers are never asked at the moment they commit, and Question Box readers' pushes are invisible. S.
5. **#13 + #14 Respect the moment for the two server pushes.** Queue the anchor push into waking hours in the room's time zone without breaking Focus. Gate the Question Box opener on arrivals rather than `played_at`. M.
