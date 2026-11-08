# 04 — Interconnectedness audit (read-only)

Repo: macstudio `~/Projects/games-room`, `main` @ `febbae3` (commit date 2026-10-25). Read over SSH. Nothing edited, built, or deployed. No DB access.
Anything about the live database is inferred from migrations. The newest migration that touches `get_active_event` is 106, and its wrapper hard-codes the 092 return shape, which is strong evidence that 092 is what's live. Each finding still says when it depends on that.

---

## State-flow map

| Trigger | Consumers that should react | Do they? (file:line) |
|---|---|---|
| **Host creates event** | Host local notifs | ⚠️ Yes, but it schedules **every opted-in roster member's** trio on the **host's** phone (`RoomService.swift:961`, `NotificationDispatcher.swift:202`) — F3 |
| | Member local notifs | Only when the app is running and subscribed to realtime INSERT (`RealtimeEventService.swift:94,161`), or later when the member opens the room (`RoomDetailView.swift:1326-1342`). Offline members get nothing until they open the room. |
| | Member calendar | ❌ Never. Calendar auto-add runs only in the creator's `addEvent` (`RoomService.swift:926-950`). The realtime path schedules notifications only, so a member with the toggle on gets no calendar entry. F7 |
| | Widget/watch snapshot | Only on the next `RoomDetailView.refresh` on that device (`RoomDetailView.swift:1236`). The watch never gets it at all (F10). |
| | Mascot voice/face | Face reads the client cache. Voice re-resolves on the server (F5). |
| **Event time edit** | Notifs, calendar, Live Activity, widget, mascot | ❌ **Not possible in the app.** `update_event_played_at` exists (022) but no client code calls it. `EditEventSheet` edits only note and venue (`EditEventSheet.swift:104` → `update_event_member_fields`). F6 |
| **Event note/venue edit** | Editor's calendar | ⚠️ Calls `updateEvent` (`RoomService.swift:999`), but `eventCalendarIdentifier` is always nil after 092, so it **creates a duplicate** calendar entry instead of updating (F7). |
| | Other members' notifs/calendar | ❌ No realtime UPDATE (`RealtimeEventService.swift:41-45`, gap acknowledged in a code comment). |
| **Event cancel/delete** | Everything | ❌ **Not possible in the app.** `delete_event` RPC exists (022/095) with no client caller. If deleted server-side, every device keeps its pending notifs and calendar entries. F6 |
| **Seat claim by A** | A's notifs | ⚠️ Plain path: cancel and reschedule, but A's own RSVP gets copied onto **every roster member** (`RoomService.swift:857`). Escrow path returns early with no reschedule (`RoomService.swift:1996-2003`, known bug class 1). |
| | B's device / host dashboard | ❌ No realtime on `event_rsvps`. B and the host only see it on pull-to-refresh of the RSVP grid (`loadRSVPGridIfNeeded`, 30s TTL). B's pending reminder bodies stay frozen. |
| | Anchor push (inviter) | ✅ Server trigger, checks membership status (`105_anchor_push.sql:263-315`). |
| **Night starts (played_at passes)** | "Tonight's event" resolver | ❌ `get_active_event` returns only `played_at > now()` (`092:124`), so a device that fetches fresh after start sees **no** event, or next week's event. F1 |
| | Live Activity start | Only when the room view refreshes on a device that cached the event **before** start (`RoomDetailView.swift:1243-1247`). No push-to-start, no background trigger. |
| | Question box | ✅ Server cron, `played_at <= now() and settled_at is null`, 24h window (`097:832-833`). |
| **Host scores / settles** | `events.settled_at` | ❌ **No client action ever stamps it.** The only writer is lazy `auto_close_stale_events` (`080:61`, `081:73`), and it runs only when somebody's `loadActiveEvent` executes (`RoomService.swift:421`). F2 |
| | Live Activity end | ❌ Rule is `isLive = playedAt<=now && settledAt==nil` (`RoomDetailView.swift:1246`), but the cached event never gets a `settledAt` (F1/F2). It ends only when a fresh fetch returns nil, or after the 8h system cap. |
| | Pending local notifs | Not relevant: all cadences sit before the start time. The catch-up identifier is broken, though (F4). |
| | Leaderboard/season on other devices | Pull only. No realtime on transactions or `room_memberships`. The leaderboard refreshes on `force`, but the active event does not (F1). |
| | Recap / ceremonial card / `.justSettled` | ❌ Not reachable from a fresh fetch: `settled_at` can't be non-null on a `played_at > now()` row. F1 |
| | Next-event prompt for host | ❌ No chain from settle. `AddEventSheet` is opened manually only. |
| **Season close** | Mascot voice | ❌ After the first close, the voice says "season has closed, praise standouts" **forever** (`mascot-voice/index.ts:258-264,310`). F5b |
| | Face/footer | Client `currentSeason` is refreshed in `closeSeason` (`RoomService.swift:518-531`). ✅ on the host's device; other devices pick it up on next pull. |
| **auto_close_stale_events** | Clients | Return value thrown away: `_ = try?` (`RoomService.swift:421`). The same call then re-reads `get_active_event`, which ignores `settled_at` anyway. Effective consumers: mascot-voice `settled_at` branches, the question box, and `RoomPage.swift:570` "last played". |
| **Member kicked** | Kicked user's local notifs/calendar | ❌ `refresh()` just replaces `rooms` (`RoomService.swift:239-241`). Nothing cancels pending notifs or calendar rows for rooms that disappeared. F8 |
| | Realtime INSERT to kicked user | ❌ The events RLS policy has no `membership_status` check (`090:51-59`), so the INSERT is still delivered. Notifs get scheduled whenever the local `rooms` cache is stale. F8 |
| | mascot-voice leader/member count/gate | ❌ No `membership_status` filter (`mascot-voice/index.ts:237,318,355`). F8 |
| | Host roster | ✅ `kickMember` rebuilds from the active-only roster (`RoomService.swift:755-760`). |
| **Notification opt-out (room)** | Pending notifs | ❌ `cancelRoomCadence` passes **roomId as eventId**, so nothing gets cancelled (`RoomService.swift:1954`). F3b |
| **Per-event unmute** | Re-schedule | ❌ Cancels only, never reschedules (`RoomService.swift:1945`). F3c |
| **App returns from background** | Anything | ❌ No `scenePhase` handler outside the Question Box (`QuestionBoxViews.swift:194`). No foreground refetch, no realtime resubscribe. Widget relies on its own 1-minute timeline reading a stale snapshot. F9 |

**How many "tonight's event" resolvers?** Five, and they disagree:
1. `get_active_event` (server, `played_at > now()` ASC; 092)
2. `RoomService.activeEventByRoom` (client cache, never re-fetched once non-nil; F1)
3. mascot-voice "latest by `played_at DESC`, any state, ignores hidden" (`index.ts:219-227`)
4. Question-box cron (`played_at in last 24h && settled_at null`)
5. The widget snapshot (first room in `rooms` + whatever room was opened last)

---

## Findings

### F1 — High — "Tonight's event" disappears at start time and freezes in the client cache
**Where:** `Supabase/migrations/092_multipack_events.sql:95-127` (predicate at `:124`), wrapped as-is by `106_room_rpc_member_guards.sql:37-44`. Client side: `GamesRoom/Views/RoomDetailView.swift:1325-1342`, `:1392`, `:1417`.

**What happens now:**
```sql
-- 090 (intended): where e.settled_at is null and not (current_user_id() = any(e.hidden_from_user_ids)) order by e.played_at desc
-- 092 (live shape per 106):
where e.room_id = p_room_id
  and e.played_at > now()
order by e.played_at asc
limit 1;
```
```swift
private func loadActiveIfNeeded(force: Bool = false) async {
    if roomService.cachedActiveEvent(roomId: room.id) == nil {   // force is ignored once cached
        let event = await roomService.loadActiveEvent(roomId: room.id, force: force)
```
092 rewrote the 090 body while "adding pack_slugs". In doing so it:
- (a) changed the predicate to future-only;
- (b) dropped the hidden-members filter;
- (c) dropped `event_calendar_identifier` and `hidden_from_user_ids` from the return shape.

At the same time, the view's loader never re-fetches once the cache is non-nil, even on pull-to-refresh with `force: true`.

**What users see:**
- A device that opens fresh after 7:30pm sees no event (or next week's). The in-play, settle and recap states are unreachable for it.
- A device that had the room open before the start keeps a frozen copy all night (`settledAt` stays nil). Its in-play UI "works" only by accident.
- `.justSettled` and the ceremonial card can't come from the server at all.
- Hidden members can see events they were hidden from. The client guard at `RoomService.swift:1894` reads `hiddenFromUserIds`, which is now always nil.

(Live body UNVERIFIED without a DB read, but 106's `RETURNS TABLE` matches 092 exactly.)

**Fix:**
1. New migration restoring the 090 semantics: unresolved event the caller can see, `settled_at is null`, hidden filter, include `event_calendar_identifier`/`hidden_from_user_ids`/`pack_slugs`/`started_at`. Decide whether "active" means "next unsettled" (prefer the currently-live one, else the soonest future one).
2. Client: `loadActiveIfNeeded` must honour `force` (drop the `== nil` gate, or `if force || cached == nil`). Do the same at `:1392`/`:1417`.

This needs to be **one** resolver that every surface uses: face, voice (pass `event_id` always), widget and Live Activity.

**Effort:** M

### F2 — High — No explicit settle exists, so nothing downstream ever gets a "settled" signal
**Where:** the only `update public.events set settled_at` is in `080_auto_close_stale_events.sql:61` and `081_auto_close_hours.sql:73`. Client trigger: `RoomService.swift:417-422`.

**What happens now:**
```swift
if lastAutoCloseAt[roomId] == nil || now.timeIntervalSince(lastAutoCloseAt[roomId]!) > 60 {
    lastAutoCloseAt[roomId] = now
    _ = try? await store.autoCloseStaleEvents(roomId: roomId)
}
```
- `settled_at` is stamped only lazily, 1–72h after the start, and only when some member's client happens to run `loadActiveEvent`. Because of F1's cache gate, that is roughly the first open per app process.
- Host scoring and scan-settle never close the event.
- Everything keyed on settle depends on that lazy stamp: Live Activity end, the `.justSettled` card, mascot "post-play recap", the question box stop, the Tonight's Star window (`RoomDetailView.swift:1685`), and `RoomPage` "last played".

**What users see:**
- The Live Activity hangs on the lock screen until the 8h cap.
- The recap appears a day or more late, or never if nobody opens the app.
- The voice says "the night has started, the event is live" the next morning.

**Fix:** add a `settle_event(p_event_id)` RPC that stamps `settled_at`, called from the host's final score/scan-settle confirmation. Keep auto-close as the backstop. Optionally run auto-close on pg_cron so it doesn't depend on a client. Then a client `onEventSettled(eventId)` reconcile step:
- end the Live Activity,
- write the widget snapshot,
- cancel pending notifs for the event,
- force-reload the active event, season and leaderboard,
- prompt the host to "plan the next night".

**Effort:** M

### F3 — High — Notification fan-out runs on the wrong device, with the wrong RSVP, and toggles don't reach pending notifs
**Where:**
- `RoomService.swift:958-978` (addEvent) and `:855-885` (upsertEventRSVP)
- `NotificationDispatcher.swift:202-280`
- `RoomService.swift:1953-1957` and `:1931-1946`

**What happens now:**
```swift
// addEvent — host's device
let cadence = roster.reduce(into: [UUID: MemberRSVPState]()) { acc, member in acc[member.userId] = .unclaimed }
// upsertEventRSVP — caller's device; rsvpByEvent is the CALLER's own state
acc[member.userId] = rsvpByEvent[event.id] ?? .unclaimed
// dispatcher: no "is this the local user?" check
for (memberId, state) in perMemberCadence { ... schedule(identifier: "\(eventId)-on_create-\(memberId)" ...) }
```
- **(a)** The host's phone (and any member's phone after they RSVP) schedules on-create, T-168h, T-84h and morning reminders **for every opted-in member**, each addressed by that member's name. That's N banners on one phone, plus N `mascot-voice` LLM calls per create. Per-user identifiers mean dedupe never collapses them.
- **(b)** The caller's own RSVP state gets copied to everyone.
- **(c)** `cancelRoomCadence`:
  ```swift
  for (eventId, event) in activeEventByRoom where event.roomId == roomId {
      await NotificationDispatcher.shared.cancelBriefingTrio(eventId: eventId)
  }
  ```
  `activeEventByRoom` is keyed by **roomId** (`:111`), so it cancels prefix=roomId, which matches nothing. Opting out of a room leaves every pending reminder in place.
- **(d)** Unmuting an event cancels and never reschedules, despite the doc comment ("we cancel + reschedule"). An unmuted member gets no further reminders for that event.

**What users see:**
- The host gets a stack of "Hey Sam… / Hey Priya…" pushes.
- Members get "you've claimed" copy they didn't choose.
- Opt-out "doesn't work".
- Unmute silently kills the reminders.

**Fix:** one entry point, `NotificationReconciler.reconcile(eventId:)`, run on this device:
1. resolve the local user;
2. read their RSVP, opt-in and mute from the server (or a fresh cache);
3. cancel the event's prefix;
4. schedule for `[localUserId: state]` only.

Call it from create, RSVP/claim (both paths), the mute/unmute toggle, the opt-in toggle, the realtime insert, room open, and the foreground event. Delete the roster fan-out. Fix `cancelRoomCadence` to iterate `.values` and use `event.id`.

**Effort:** M

### F4 — High (copy/correctness) — Escaped interpolation: literal `\(mascotName)` in push titles and a constant catch-up identifier
**Where:**
- `NotificationDispatcher.swift:266` (on-create title)
- `:417-418` (catch-up identifier and title)
- `RoomPage.swift:557,559` (overlap badge)
- `RoomService.swift:317` (cache key)

All introduced in commits `f5fc331` (2026-08-20) and `e839f69` (2026-08-13), so they shipped.

**What happens now** (`od -c` confirms two backslashes):
```swift
title: "\\(mascotName): \\(eventName)",
identifier: "\\(eventId.uuidString)-catchup",
return "Shared with \\(name) in another room"
cacheTimestamps.removeValue(forKey: "roomMembers:\\(roomId.uuidString)")
```

**What users see:**
- The on-create and catch-up push titles read literally `\(mascotName): \(eventName)`. The rooms list shows `Shared with \(name) in another room`.
- The catch-up identifier is the same for every event. After one catch-up is still in Notification Center, the dispatcher's "already delivered" dedupe (`:578-581`) **suppresses every later catch-up**, and `cancelBriefingTrio`'s eventId prefix can never match it.
- Tier-2 approval never invalidates the roster cache key.

**Fix:** replace `\\(` with `\(` at those six lines. Add a lint or grep test for `"\\\\(` in Swift sources.

**Effort:** S

### F5 — High — Voice and face still resolve from different data planes (bug class 2, new instances)
**Where:** `Supabase/functions/mascot-voice/index.ts:209-228` (event), `:258-264, :310-315` (season), `:317-322` (leader). Face side: `RoomDetailView.swift:4680-4693` and `MascotFaceEngine.swift:115-125`.

- **(a) Event.** When the client has no `activeEvent` (F1 after start), it sends only `room_id`. The server then picks `order("played_at", desc).limit(1)` with no hidden filter and no future/settled rule. Result: the face is idle/readStandings while the voice says "The night has started. The event is live." A hidden member's footer can be voiced from an event they were hidden from (privacy leak of the event name).
- **(b) Season.**
  ```ts
  const { data: latestSeasons } = await serviceClient.from("seasons")...order("ordinal",{ascending:false}).limit(2);
  const latestSeason = (latestSeasons ?? []).find((s) => s.status === "ended");
  if (latestSeason?.status === "ended") { ctx.message_type = "The season has closed. Praise the season's standouts."; }
  ```
  `close_season` opens season N+1, so the top two by ordinal are always [N+1 active, N ended]. After the first close, **every** footer and push is voiced as a season-close eulogy, overriding the event message type.
- **(c) Leader.** Read from raw `room_memberships` ordered by `season_score` with no `membership_status='active'` filter. The face's margin comes from `get_room_leaderboard`. A kicked top scorer can be the voice's "leader" while the UI ranks someone else.

**Fix:**
- The client always passes the `event_id` and `room_state` it rendered (the face's `RoomState`). The server uses those, and never re-derives state when they're given.
- The season branch should fire only when the client says `.seasonClose`, or when `latestSeasons[0].status === 'ended'` (or when `ended_at` is within N days).
- Leader comes from `get_room_leaderboard` (the same RPC the UI renders) via the service role, or at minimum `.eq('membership_status','active')`.

**Effort:** S–M

### F6 — Med-High — Event time can't be edited and events can't be cancelled; server RPCs exist with no client
**Where:** `022_v0.12_host_tools.sql:56` (`delete_event`), `:91` (`update_event_played_at`), `095:762`. There is no `.rpc("delete_event"` or `.rpc("update_event_played_at"` in `GamesRoom/` (the full RPC list in `RoomStore.swift` was checked). `EditEventSheet.swift:104` only edits member fields.

**What users see:** a host who sets the wrong date or cancels a night has no recovery path. They have to create a second event and live with stray reminders and calendar entries for the first. If an admin deletes or reschedules server-side, every device's notifs and calendar entries stay frozen at the old time (no realtime UPDATE/DELETE: `RealtimeEventService.swift:41-45`).

**Fix:** add host "Change time" and "Cancel night" actions calling the existing RPCs. Add realtime UPDATE/DELETE on `events` (the publication already includes it from 077; listen for `UpdateAction` and `DeleteAction`). Both paths call the F3 `reconcile(eventId:)` plus a calendar reconcile. DELETE payloads only carry the PK unless REPLICA IDENTITY FULL is set, which is enough to cancel by eventId prefix.

**Effort:** M

### F7 — Med — Calendar mirror: identifier lost after 092, one shared column for per-device IDs, members never get entries
**Where:** `CalendarService.swift:118-150`; `RoomService.swift:926-950, 995-1010, 1021-1030`; `087` (single `events.event_calendar_identifier`); 092/106 shape (column not returned).

**What happens now:**
- `event.eventCalendarIdentifier` is always nil (F1c). So `updateEvent` falls through to `addEvent`, and **every note or venue edit adds another calendar entry**. `deleteRoom`'s `removeEvent(identifier: nil)` is a no-op.
- Even with the column restored, EventKit identifiers are per-device. One `events` column means the last reporter overwrites everyone else's. Any other device can't find its own row, so it duplicates on edit.
- Members with the toggle on never get an entry, because `RealtimeEventService` doesn't call `CalendarService`.

**What users see:**
- Duplicate calendar entries on edit.
- Stale entries after a room is deleted.
- The member calendar toggle "does nothing" for events other people create.

**Fix:**
- Move the identifier to a per-(event, user) table, e.g. `event_calendar_rows(event_id, user_id, identifier)`, or simply store it locally keyed by event id with a fallback search (`predicateForEvents` + title/URL match). A custom URL like `gamesroom://event/<id>` on the EKEvent makes lookup reinstall-proof without server state.
- Drive the calendar from the same per-device reconcile as F3: on create (realtime), on edit, on cancel, on kick or leave.

**Effort:** M

### F8 — Med — Kicked/left member residue: local notifs, calendar, realtime, edge functions
**Where:**
- `RoomService.swift:235-256` (`refresh` only replaces `rooms`)
- `090:51-59` (events RLS, no status check)
- `RealtimeEventService.swift:133` (stale-cache gate)
- `mascot-voice/index.ts:237-242, 317-322, 355-358`
- `leave_room` (`008:24`) has no client caller at all

**What happens now:**
- A kicked member's phone keeps every pending reminder and calendar entry for the room's upcoming events. Nothing diffs the old and new `rooms` lists.
- Realtime INSERTs keep arriving (RLS checks only that a membership row exists). Notifs get scheduled if the local `rooms` still lists the room, which it does until the next `refresh()`.
- mascot-voice lets a kicked user through the membership gate, and counts and ranks kicked members.
- Members can't leave a room from the app.

**What users see:** a kicked person gets "Friday Poker is tomorrow" reminders and keeps the calendar entry. The mascot cites a removed member as leader.

**Fix:**
- In `refresh()`, diff `oldRooms - newRooms` and call `purgeRoomLocalState(roomId)`: cancel notif prefixes for every cached event in that room, remove calendar rows, drop caches, end the Live Activity, clear the widget snapshot if it belongs to that room.
- Add `and m.membership_status = 'active'` to the events RLS policy (or use `is_room_member()` from 106).
- Add an `.eq('membership_status','active')` filter at all three mascot-voice reads.
- Expose "Leave room" (`leave_room`) through the same purge path.

**Effort:** M

### F9 — Med — Nothing refreshes on foreground; realtime has no reconnect or catch-up
**Where:** no `scenePhase`/`willEnterForeground` handlers in `GamesRoom/` except `QuestionBoxViews.swift:194`. `ContentView.swift:149-169` starts realtime once.

**What happens now:** returning from background re-runs nothing. `.task` doesn't re-fire on a view that stays mounted. Combined with F1's cache gate, the room page can show yesterday's state indefinitely. Whether the Supabase SDK re-subscribes after suspension is UNVERIFIED, and either way, INSERTs missed while suspended aren't replayed. The only catch-up is the on-create path, which runs only when the active-event cache is nil.

**What users see:** stale room after unlocking; host and members see different seat counts and states until they pull (and even pull doesn't fix the active event, per F1).

**Fix:** add an app-level `onChange(scenePhase == .active)` that runs `appReconcile()`:
1. `roomService.refresh()` (rooms diff → F8 purge),
2. for each room: `loadActiveEvent(force: true)` → `NotificationReconciler.reconcile` (F3) + calendar reconcile (F7),
3. stop and restart `RealtimeEventService`,
4. Live Activity and widget apply (F10).

**Effort:** S–M

### F10 — Med — Widget and watch snapshots: single global key, no reload, watch can't read it
**Where:** `ScoreSnapshotStore.swift:21-47`, `RoomService.swift:243-249`, `RoomDetailView.swift:1233-1247`, `GamesRoomWidgets.swift:63-67`, `GamesRoomWatch/GamesRoomWatchApp.swift:32-35,67`.

**What happens now:**
- One `scoreSnapshot` key for all rooms. `RoomService.refresh()` writes `rooms.first` with an empty line, and `shouldPersist` rejects empty-over-non-empty. So the widget shows **whichever room was opened last**, with `isLive` from a stale cache (F1).
- `WidgetCenter.reloadTimelines` is never called; it relies on the 1-minute `.after` policy, which iOS budgets.
- The watch app reads `UserDefaults(suiteName:)` App Group data. That does not sync from iPhone to Apple Watch, and there's no WatchConnectivity anywhere (grep: none). On a real device the watch will always show its placeholder. (UNVERIFIED on device, but that's how App Groups work.)
- The Live Activity is keyed by `roomName`, so renaming a room orphans the running activity.

**Fix:**
- Write the snapshot for one deliberately chosen room: the room with the soonest or live event from the single resolver (F1).
- Call `WidgetCenter.shared.reloadAllTimelines()` after writes.
- Feed the watch via `WCSession.updateApplicationContext`.
- Key the Live Activity by roomId.

**Effort:** M

### F11 — Low-Med — Escrow claim path skips the notification reschedule and returns a fake row (known bug class 1, still on main)
**Where:** `RoomService.swift:1995-2005`.
```swift
if roomTriggeringEscrow(forEvent: eventId) {
    try await store.claimSeatWithDeposit(eventId: eventId)
    await loadMySeatDeposit(eventId: eventId, force: true)
    return MemberRSVP(id: UUID(), eventId: eventId, roomId: UUID(), memberId: UUID(), state: .claimed, respondedAt: Date())
}
```
No RSVP or briefing reload and no reschedule. It also returns a synthetic row with random `roomId`/`memberId`, so any caller using `row.memberId` keys garbage. The fix branch exists only on the stale mini checkout (`fix/notif-claimed-state`). It's covered once F3's `reconcile(eventId:)` is called here.

**Effort:** S

### F12 — Low — Chains that should exist and don't
- **Settle → next night:** no prompt after settle or auto-close. Pair it with F2's `onEventSettled`: a host-only "Plan the next night?" card that pre-fills `AddEventSheet` with the same weekday and time.
- **Season close → other devices:** pull only. Low urgency; handled by F9's foreground reconcile.
- **Arrival/check-in → question box:** question-box eligibility uses `r.state = 'claimed'` and active membership (`097:636-637, 691-692`), not check-in. A claimed no-show can still be picked as reader. Consider gating on `seat_deposits.checked_in`/arrival when escrow is on. (Product call; not a bug.)
- **auto-close result:** the closed count is thrown away (`RoomService.swift:421`). If it's >0, it should invalidate the leaderboard, season and Live Activity (F2 reconcile).

---

## Top 5, ranked
1. **F1:** fix `get_active_event` (restore the unsettled/hidden/calendar shape) and make the room loader honour `force`. Most of the other drift starts here: start-time disappearance, the frozen cache, hidden-member leak, calendar duplicates, voice/face split.
2. **F3 + F11:** replace the roster fan-out with a per-device `NotificationReconciler.reconcile(eventId:)`. Fixes N banners on the host's phone, the wrong RSVP copy, broken opt-out (roomId-as-eventId), unmute killing reminders, and the escrow claim skipping the reschedule.
3. **F4:** six `\\(` → `\(` fixes. Literal `\(mascotName)` push titles in production, plus catch-up pushes suppressed by a shared identifier. S effort, high visibility.
4. **F2:** a real `settle_event` plus a client `onEventSettled` reconcile: Live Activity end, recap, widget, next-night prompt. Today "settled" only happens lazily 1–72h later, when someone happens to open the app.
5. **F5:** voice uses the client's rendered `event_id`/`room_state`; fix the permanent "season has closed" branch; leader from the same leaderboard RPC with the active filter.

**Unifying recommendation:** one `AppReconciler` on the client with three entry points: `reconcile(eventId:)`, `purgeRoom(roomId:)` and `appBecameActive()`. Every consumer goes through it: notifications, calendar, Live Activity, widget and watch, caches. Feed it from three sources: local writes, realtime events (INSERT/UPDATE/DELETE on `events`, plus `event_rsvps`), and `scenePhase`. On the server, one `get_active_event`, which mascot-voice calls too.
