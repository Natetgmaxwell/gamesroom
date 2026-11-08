# STATE S2

STATE: step 1 of 8 done. Next: step 2.

STEP 1 DONE (commit a1de6c1 `S2.1: port fix/notif-claimed-state (reconcileBriefing) onto febbae3`).
The two upstream objects 04081cb and 5649888 were cherry-picked from refs/remotes/icloud/fix/notif-claimed-state and squashed into that single step commit (upstream SHAs and the conflict resolutions are recorded in the commit body).

Conflicts resolved:
- MascotEngine.swift: the fix's four claimed-state briefing cells applied on top of febbae3's em-dash-free copy.
- NotificationDispatcher.swift: the fix's version taken (body builders and identifier helpers now live in BriefingReconciler; NotificationKindRaw restored by 5649888) and febbae3's em-dash removal re-applied.
- BriefingReconciler.swift (new): febbae3's em-dash removal re-applied to the on-create body and the reminder title.
- RoomService.swift: febbae3's Brought By / anchor code kept; the fix's reconcileBriefing entry point is in.
- RoomDetailView.swift: febbae3's layout kept, only the fix's room-open scheduling hunk applied.
- main.swift: febbae3's BroughtBy tests kept and runBriefingReconcileTests() registered.

Gate: `bash .maestro/fastgate.sh` -> 313 cases, 313 passed, 0 failed; parse-check 65/65; FASTGATE: PASS.
BriefingReconciler.swift and TestsBriefingReconcile.swift are in SRC_FILES in build-and-run-tests.sh.

BLOCKED: none

Ticks are in .maestro/briefs/BRIEF-S2.md (tick the checkbox there too).
