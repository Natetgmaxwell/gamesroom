# Games Room finish audit — synthesis (2026-11-08)

Base: studio `~/Projects/games-room` main @ febbae3 (shipped 1.2.3). Sources: 01-notifications, 02-workflows, 03-spacing, 04-interconnect (four Opus 5.5 read-only auditors).

## Verified by TARS (independent of auditors)
- LIVE `get_active_event__inner` filters `e.played_at > now()` → a night vanishes from the server at start time; settled nights never return. (Management API, pg_proc prosrc)
- No Swift caller sets `settled_at`/`host_finalized`, or calls `leave_room`, `delete_event`, `update_event_played_at` (RPCs exist live).
- Escaped interpolation ships literally: RoomPage.swift:557/559, NotificationDispatcher.swift:266/417/418 (catch-up identifier identical for every event).
- Reminder fire times: T-168h, T-84h (3.5 days → flips AM/PM), morning-of fixed 09:00 (NotificationDispatcher.swift:161-173).

## Slices (ranked)
S1 The night works — get_active_event returns live + recently settled; host Settle action; score sheet opens on next round; reload event on pull/foreground. (migration + client, M)
S2 Notifications right moment — rebase fix/notif-claimed-state (5649888, on 1.2.1) onto febbae3; day-anchored reminders inside 09:00–20:00; morning-of before early events; opt-in asked after first claim; fix cancelRoomCadence room/event id; unmute reschedules; anchor push held to waking hours, not time-sensitive; fix escaped strings. (M). S2b server-sent reminders for members who never open the app (L).
S3 Common-sense flows — edit/reschedule/cancel night; Leave room; role-gate settings; full night hides Claim; deposit release/re-claim bugs; multi-pack actions follow selected packs not headline; land on the room after create/join. (M-L)
S4 Finish — PrimaryButtonStyle token; one secondary-action style; shared list leading edge; one card shape; ArrivalCard double inset; grey + radius tokens; Rooms screen onto room rhythm. (M)
