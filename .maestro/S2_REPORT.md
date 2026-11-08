# S2 report: phone notifications (branch s2/notif-client)

Base: main @ febbae3 (shipped 1.2.3). Final gate: `bash .maestro/fastgate.sh --compile` -> `Ran 328 cases: 328 passed, 0 failed.`, parse-check 66/66, `FASTGATE: PASS` (the --compile pass only prints PASS after `BUILD SUCCEEDED`).

## Commits (code, then STATE tick)
- S2.1 a1de6c1 / db04448: port fix/notif-claimed-state (reconcileBriefing) onto febbae3
- S2.2 fa75e81 / fedbe42: day-anchored reminder times inside waking hours
- S2.3 57e5fbe / b98eb22: on-create delivers to Notification Center; taps open the room
- S2.4 962fa39 / 7d98077: room opt-out, unmute and note edits reconcile; fix escaped strings
- S2.5 ed0db05 / 90a36fe: foreground reconcile + purge rooms the user left or was removed from
- S2.6 79e59c7 / 504efc3: ask for reminders right after the first claim
- S2.7 431b0e9 / 0e68c6a: calendar rows for every member who claims
- S2.8: this report

## Test counts (unit runner, per step gate)
step 3: 323 · step 4: 324 · step 5: 326 · step 6: 326 · step 7: 328 · step 8: 328. All passing, none removed or weakened.

## Step 1 conflicts and how they were resolved
04081cb and 5649888 (refs/remotes/icloud/fix/notif-claimed-state, written on 1.2.1 209b78c) were cherry-picked and squashed into a1de6c1.
- MascotEngine.swift: the fix's four claimed-state briefing cells applied on top of febbae3's em-dash-free copy.
- NotificationDispatcher.swift: the fix's version taken (body builders and identifier helpers live in BriefingReconciler; NotificationKindRaw restored by 5649888); febbae3's em-dash removal re-applied.
- BriefingReconciler.swift (new): febbae3's em-dash removal re-applied to the on-create body and the reminder title.
- RoomService.swift: febbae3's Brought By / anchor code kept; the fix's reconcileBriefing entry point added.
- RoomDetailView.swift: febbae3's layout kept, only the fix's room-open scheduling hunk applied.
- main.swift: febbae3's BroughtBy tests kept and runBriefingReconcileTests() registered.

## Integration notes for TARS
- Public entry point: `RoomService.reconcileBriefing(eventId:)` (declared `reconcileBriefing(eventId:hint:)` with `hint` defaulted to nil, so `reconcileBriefing(eventId: id)` is the call shape for `eventDidChange(eventId:)`).
- `set_room_time_zone(p_room_id, p_tz)` is called from the host's room open via `AppReconciler.reportRoomTimeZoneOnce(roomId:)`: fire and forget, `try?`, no error surfaced; the per-room flag is set only on success, so it retries until lane S2b's RPC exists.
- Calendar identifiers are now per device (`CalendarRowStore`, UserDefaults). `events.event_calendar_identifier` is no longer read or written; `RoomService.reportCalendarIdentifier` and the store method remain but are uncalled. Dropping the column is a later migration, not done here.
- Live Activity end and widget snapshot clear for a purged room are done from AppReconciler (ScoreLiveActivityDriver/ScoreSnapshotStore are outside this lane's files); they key on room name, as those surfaces do.
- The --compile gate was also run at steps 5, 6 and 7 (all PASS), so the step 3 SwiftUI/UN glue is type-checked.
- Not exercised: anything on a device or simulator (by rule). Manual checks worth doing in the full gate: the post-claim "Remind me the morning of" row, foreground purge after being kicked, and the calendar row on a deposit claim.
