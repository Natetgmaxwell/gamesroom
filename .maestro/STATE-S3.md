# STATE S3

STATE: step 2 of 8 done. Next: step 3.

BLOCKED: none

Notes for step 2:
- `Supabase/migrations/114_event_cancel.sql` written (NOT applied). New `cancel_event(uuid)`: host only via `public.is_room_host(room_id, caller)`, returns every deposit still held for the night on the `check_in_seat` return path (row goes `returned` + `returned_at`/`settled_at`, `room_memberships.points_balance` credited, a `seat_deposit_return` ledger row with `meta.via = 'cancel'`), then deletes the night the way live `delete_event` does (`event_packs` first, then `events`; RSVPs and deposit rows ride the cascade). One transaction: cancel or nothing.
- `delete_event(uuid)` and `update_event_played_at(uuid, timestamptz)` recreated with `set search_path = public` and the host guard moved to `public.is_room_host` only. The live bodies read `created_by = v_caller OR public.is_room_host(...)` (live `delete_event` had no `set search_path` at all), so a host who transferred the room kept the button; the membership role is now the truth. Live bodies were the base: `docs/audit/2026-11-08/live-functions.sql`.
- Fastgate passed: 302 cases, 64 files parse-check. Commit `989458a` (`S3.2: migration 114 cancel_event; host guards on event edits`).
- Nothing client-side changed this step, so `RoomService` still has no call site for `cancel_event` / `update_event_played_at` / `delete_event` (grep: none exist).

Notes for step 3 (client: release, decline, full night):
- The server side already speaks: `release_seat(p_event_id, p_state)` from migration 113 (state `unclaimed` | `declined`, returns a held deposit), and `night_full` is raised as P0001 by `claim_seat_with_deposit` and `upsert_event_rsvp`.
- `RoomService+EventChange.swift` is a NEW file (in ALLOWED FILES). `NotificationDispatcher.shared.cancelBriefingTrio(eventId:)` exists — see `GamesRoom/Services/RoomService.swift:871`. `RoomService.upsertEventRSVP(eventId:state:)` (RoomService.swift:828) is the pattern to copy: write through the store, patch the cache, then reload `loadEventRSVPs` / `loadBriefing`.
- `RoomService` is a class with `@Published` caches; the store protocol is `RoomStoreProtocol.swift` with a live impl in `RoomStore.swift` and `InMemoryRoomStore.swift`. New store methods need all three.
- Brief wants: release is instant with a bottom toast `Seat released.` + `Undo` for 5 s (Undo re-claims); a full night replaces Claim seat with a grey caption `All {n} seats are taken.`.

Ticks are in .maestro/briefs/BRIEF-S3.md (tick the checkbox there too).
