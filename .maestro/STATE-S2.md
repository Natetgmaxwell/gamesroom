# STATE S2

STATE: step 2 of 8 done. Next: step 3.

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

Gate: `bash .maestro/fastgate.sh` -> 320 cases, 320 passed, 0 failed; parse-check 65/65; FASTGATE: PASS.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2.md (tick the checkbox there too).
