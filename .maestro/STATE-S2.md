# STATE S2

STATE: step 7 of 8 done. Next: step 8.

STEP 1 DONE (commit a1de6c1 `S2.1: port fix/notif-claimed-state (reconcileBriefing) onto febbae3`).
The two upstream objects 04081cb and 5649888 were cherry-picked from refs/remotes/icloud/fix/notif-claimed-state and squashed into that single step commit (upstream SHAs and the conflict resolutions are recorded in the commit body).

Conflicts resolved:
- MascotEngine.swift: the fix's four claimed-state briefing cells applied on top of febbae3's em-dash-free copy.
- NotificationDispatcher.swift: the fix's version taken (body builders and identifier helpers now live in BriefingReconciler; NotificationKindRaw restored by 5649888) and febbae3's em-dash removal re-applied.
- BriefingReconciler.swift (new): febbae3's em-dash removal re-applied to the on-create body and the reminder title.
- RoomService.swift: febbae3's Brought By / anchor code kept; the fix's reconcileBriefing entry point is in.
- RoomDetailView.swift: febbae3's layout kept, only the fix's room-open scheduling hunk applied.
- main.swift: febbae3's BroughtBy tests kept and runBriefingReconcileTests() registered.

STEP 2 DONE (commit fa75e81 `S2.2: day-anchored reminder times inside waking hours`).
- GamesRoom/Services/BriefingReconciler.swift: `plan` now derives its three slots from the calendar in the device's time zone via the new `reminderSlots(playedAt:calendar:)` helper:
  - week-before = 18:00 on the calendar day 7 days before the event's day;
  - few-days (identifier `t48h` unchanged) = 18:00 on the calendar day 3 days before the event's day;
  - morning-of = the earlier of 09:00 on the event's day and playedAt - 3h, floored at 07:00 on the event's day.
- Drop rules in `plan`: a slot whose time has passed is skipped; week-before and few-days are dropped inside the on-create prompt's 24-hour window; morning-of is dropped inside its 2-hour window; few-days is dropped when it lands within 24 hours of the week-before slot.
- The old `morningFireDate(playedAt:now:)` helper (09:00 / playedAt-30m / now+1s fallback) is gone, replaced by `reminderSlots`. `plan` gained an optional `calendar: Calendar = .current` parameter; `reconcile` is unchanged and routes through `plan`, so the dispatcher path uses the new times in production. Identifier kinds and the `\(eventId)-\(kind)-\(userId)` format are untouched.
- New file TestsS2.swift (added to SRC_FILES in build-and-run-tests.sh, registered in main.swift as runS2Tests()) asserts exact local date-times for the brief's worked cases: (a) Sat 14:00 event created 14 days out at 10:00 -> Sat 18:00 (week-before), Wed 18:00 (few-days), Sat 09:00 (morning-of); (b) Fri 08:00 event -> morning floors at Fri 07:00; (c) Fri 19:30 event created Tue 09:00 -> morning Fri 09:00 only; (d) event created 85h before the start -> few-days dropped. Three extra cases cover the 24h week-before guard, the 2h morning-of guard and the unchanged identifier kinds.
- Note on the brief's case (c) wording: with the on-create at Tue 09:00 the few-days slot (Tue 18:00) is still ahead, it is dropped because it falls inside the on-create prompt's 24-hour window rather than because it is in the past. The asserted outcome (no week-before, no few-days, morning Fri 09:00) is the one the brief asks for; the same construction drops the slot on either reading.

STEP 3 DONE (commit 57e5fbe `S2.3: on-create delivers to Notification Center; taps open the room`).
- The body is built first, then the request is scheduled. `BriefingReconciler.fireMode(kindRaw:fireAt:)` (new, Foundation-only, in BriefingReconciler.swift) is the single policy: the "now" prompts (on_create, catch_up) are `.shortly`, the timed reminders are `.at(date)`. `UNCenterSink.trigger(for:fireAt:)` turns `.shortly` into `UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)` and `.at(date)` into the old `UNCalendarNotificationTrigger`. The old path computed the on-create fire date BEFORE the mascot-voice LLM round trip, so the planned second was already in the past by the time the request was added and the prompt never fired (audit 01 #2).
- The payloads now carry the room. `NotificationDispatcher.reconcileBriefing` and `scheduleCatchUp` take a `roomId`, `UNCenterSink` stamps `room_id` into `userInfo`, and `RoomService` passes the room id it already resolves (the cached event's room or the realtime hint's room). The sink protocol itself is unchanged, so `TestsBriefingReconcile.swift` and its fake sink are untouched.
- `GamesRoomAppDelegate.userNotificationCenter(_:willPresent:)` returns `[.list]` for the five local briefing kinds (on_create, t168h, t48h, morning_of, catch_up) so the on-create prompt lands in Notification Center instead of being swallowed by the foreground app; the Question Box turn keeps its old behaviour (refresh the turn, no presentation option) and everything else stays silent in the foreground.
- `userNotificationCenter(_:didReceive:)` routes the tap: briefing kinds and the server's `anchor_nudge` payload (which carries `room_id`/`event_id`) open their room; the Question Box turn keeps its old behaviour. The routing decision is pure and testable: `BriefingReconciler.kindRaw(_:)`, `isBriefingKind(_:)` and `tapRoute(_:)` (new `BriefingTapRoute` enum).
- The tap posts `Notification.Name("GamesRoomOpenRoom")` with `room_id`/`event_id` in the userInfo. `OpenRoomRequest` (new, in QuestionBoxPush.swift) latches the request before posting it, because a cold start from a notification tap posts the request before the view hierarchy exists and a posted notification nobody is listening for is lost. The latch is taken exactly once, so a request is never handled twice.
- ContentView selects the room. iPhone: the rooms tab's `NavigationStack` now owns a path (`openRoomPath`) and the tapped room is pushed onto it with a `navigationDestination(for: Room.self)` that renders `RoomDetailView` exactly as `RoomPage` renders it for a room row (`RoomPage` owns its own stack and its own destination, so there is no conflict). iPad: `RoomPage`'s split view owns the detail pane and cannot be driven from outside, so the room is presented over the split view in a `fullScreenCover` with its own "Rooms" toolbar button. The request is resolved against `roomService.rooms` (by room id, falling back to the event's cached room for requests scheduled before the payload carried a room id) and waits for the rooms list if it has not loaded yet; a room the user is no longer in is never opened.
- Tests: TestsS2.swift grew three cases (the interval trigger for the "now" prompts and the fixed clock time for the reminders, the briefing-kind set, and the tap routing for a briefing, the anchor nudge, a room-less briefing, the Question Box turn and a payload with no event id). Gate: 323 cases, 323 passed, 0 failed; parse-check 65/65; FASTGATE: PASS.
- Note: the SwiftUI/UN glue in this step is parse-checked by the fast gate but not type-checked until the compile gate in step 8 (the brief reserves `--compile` for the last step).

STEP 4 DONE (commit 962fa39 `S2.4: room opt-out, unmute and note edits reconcile; fix escaped strings`).
- RoomService.cancelRoomCadence iterates activeEventByRoom.values and cancels by event.id (the dictionary is keyed by room id, so the old key sweep cancelled nothing).
- Unmute (setEventNotificationsMuted muted=false) calls reconcileBriefing(eventId:) (already present from the step 1 port; verified).
- updateEventMemberFields (note/venue save) now ends with reconcileBriefing(eventId:) so the host note reaches pending reminders.
- Escaped interpolations fixed: NotificationDispatcher catch-up identifier/title and RoomService roomMembers cache key. The catch-up id now comes from BriefingReconciler.catchUpIdentifier(eventId:) = "<eventId>-catchup". No escaped interpolations remain in NotificationDispatcher/RoomService/BriefingReconciler.
- Test: "S2 catch-up identifiers are per event and stable". Gate: 324 cases, 324 passed; parse-check 65/65; FASTGATE: PASS.

STEP 5 DONE (commit ed0db05 `S2.5: foreground reconcile + purge rooms the user left or was removed from`).
- New GamesRoom/Services/AppReconciler.swift (@MainActor, shared). appBecameActive(roomService:): requires a live session; (1) snapshots rooms + cached event ids, roomService.refresh(), and for each removed room calls RoomService.purgeRoom(roomId:) then ends the room Live Activity and clears the widget snapshot if it shows that room (both key on room name); a failed refresh leaves rooms unchanged so nothing is purged; (2) for each still-present room with a cached night: loadActiveEvent(force: true), cancels the old event cadence if the night changed, then reconcileBriefing(eventId:); (3) RealtimeEventService stop + start. Concurrent calls coalesce.
- RoomService.purgeRoom(roomId:): NotificationDispatcher.purgeRoom (pending AND delivered, matched on userInfo room_id or one of the room event ids, plus the event-id prefix sweep), removes calendar rows, drops the room cached night/members/RSVP caches.
- Wired in ContentView: onChange(of: scenePhase) on .active, skipped while restoring the session or signed out.
- Pure helpers in BriefingReconciler (removedRoomIds, requestBelongsToRoom) with 2 new tests. Gate: 326 cases, 326 passed; parse-check 66/66; FASTGATE: PASS. Also ran --compile early (BUILD SUCCEEDED, FASTGATE: PASS) so steps 3-5 are type-checked.
- ScoreLiveActivityDriver/ScoreSnapshotStore are not in ALLOWED FILES, so the Live Activity end and snapshot clear are done from AppReconciler with ActivityKit and the same App Group key.

STEP 6 DONE (commit 79e59c7 `S2.6: ask for reminders right after the first claim`).
- RoomDetailView (claimed case of the hero switch): a grey centred caption action "Remind me the morning of" (ClaimReminderAskRow in RoomNotificationPrefs.swift) shows under the claimed BriefingSlot while the room notifications are off and the ask has not been tapped (per-room UserDefaults flag, StorageKeys.claimReminderAskAnswered). Tap: marks it (and the old prompt) answered, requests iOS authorization (alert, sound, badge), turns the room notifications on through RoomService.setNotificationsEnabled, then reconcileBriefing(eventId:).
- RoomNotifPromptCard: the activeEvent == nil gate is removed; the card now steps aside only while the post-claim ask is showing, so the two never stack.
- Room open (loadActiveIfNeeded): a host calls AppReconciler.reportRoomTimeZoneOnce(roomId:) -> rpc set_room_time_zone(p_room_id, p_tz: TimeZone.current.identifier). Fire and forget, try?, never surfaces an error; the per-room flag (StorageKeys.roomTimeZoneReported) is set only on success so a missing RPC (lane S2b) is retried on a later open.
- Gate: --compile run, 326 cases, 326 passed; parse-check 66/66; BUILD SUCCEEDED; FASTGATE: PASS. No new unit test (view-only glue).

STEP 7 DONE (commit 431b0e9 `S2.7: calendar rows for every member who claims`).
- CalendarService rewritten around a per-device map: upsertEvent(_:createIfMissing:) adds or updates the EKEvent (title, start, 2h end, venue notes, url = gamesroom://event/<eventId>) and stores the EventKit identifier; removeEvent(eventId:) removes the row this device wrote and forgets it. The room/reportIdentifier parameters and every read of Event.eventCalendarIdentifier are gone.
- CalendarRowStore (in StorageKeys.swift, key StorageKeys.calendarRowIdentifiers): UserDefaults dictionary eventId -> identifier, with an injectable defaults suite for tests.
- RoomService: syncCalendarRow(eventId:claimed:) runs after a successful claim on both paths (upsertEventRSVP .claimed, and the escrow/deposit branch of claimSeat) when room.calendarAutoAdd is on; decline and release (upsertEventRSVP .declined/.unclaimed) remove the row; purgeRoom and deleteRoom remove by event id; a note/venue edit updates only a row this device already wrote (createIfMissing: false); addEvent keeps the host row via upsertEvent.
- events.event_calendar_identifier is no longer read or written for lookups (RoomService.reportCalendarIdentifier and the store method stay, now uncalled; the column is not dropped).
- Tests: 2 new (per-event map set/overwrite/remove in a scratch suite; the gamesroom:// URL). Gate (--compile): 328 cases, 328 passed; parse-check 66/66; BUILD SUCCEEDED; FASTGATE: PASS.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2.md (tick the checkbox there too).
