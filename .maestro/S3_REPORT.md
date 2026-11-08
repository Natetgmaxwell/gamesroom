---
type: report
title: S3 - Common-sense flows (1.2.4 finish train)
created: 2026-11-08
tags:
  - s3
  - flows
  - migration
  - gate
related:
  - '[[00-SYNTHESIS]]'
  - '[[02-workflows]]'
  - '[[04-interconnect]]'
---

# S3 - Common-sense flows

Branch: `s3/flows`, based on `main` at `febbae3` (shipped 1.2.3).
All work is on this branch only: no merge, rebase, push, branch switch, or
touch of `main` or any sibling worktree.

## Gate

Final gate: `bash .maestro/fastgate.sh --compile` at the step 7 tip.

```text
Ran 317 cases: 317 passed, 0 failed.
parse-check-swiftui: scanning 65 file(s) with iphoneos SDK
parse-check-swiftui: pass=65 fail=0
BUILD SUCCEEDED
FASTGATE: PASS
```

The app target builds for `generic/platform=iOS Simulator` with code signing off
(derived data in `/tmp/dd-s3-flows`). The unit runner is 317 cases: 302 that
pre-dated the lane plus 15 new cases in `TestsS3.swift`.

## Commits

| Step | Commit | Subject |
| --- | --- | --- |
| 1 | `8cbddb8` | S3.1: migration 113 release returns deposits, re-claim claims, capacity |
| 2 | `989458a` | S3.2: migration 114 cancel_event; host guards on event edits |
| 3 | `8e344ae` | S3.3: release returns the deposit with Undo; a full night says so |
| 4 | `2e4afa1` | S3.4: hosts can reschedule, rename and cancel a night |
| 5 | `7e0ca11` | S3.5: settings by role; anyone can leave a room |
| 6 | `f19bd88` | S3.6: new users land in the room; invite comes first; honest Live now |
| 7 | `bcee0e8` | S3.7: arrivals wait for the grace window; keeping a deposit confirms |
| 8 | this commit | S3.8: report |

`1e48641` (S3.0) is TARS's lane bootstrap (brief, fastgate, audit references),
not this lane's work.

## Migrations (written, not applied)

Both files start from the LIVE bodies in
`docs/audit/2026-11-08/live-functions.sql`, never from an older migration. They
are for TARS to push; this lane ran no `supabase db` command and made no network
call. Every new SECURITY DEFINER function sets `search_path = public`, revokes
from `public, anon` and grants to `authenticated` (plus `service_role` where the
live neighbours do). Host checks use `public.is_room_host(...)`, never
`rooms.created_by`. Membership-derived reads filter `membership_status = 'active'`.

### `113_seat_flows.sql`

1. **`release_seat(p_event_id uuid, p_state text)`** (new). Sets the caller's
   RSVP to `unclaimed` or `declined` and, if the caller holds a `held` deposit
   for that event, returns it exactly the way `check_in_seat` does: status
   `returned`, `returned_at` set, the balance credited, a ledger row. One
   transaction. Migration 012a's dormant `release_seat(uuid)` is untouched (the
   new signature does not collide).
2. **`claim_seat_with_deposit`** (recreated). The early-return guard now skips
   the deposit insert only while a deposit is still `held`, and the RSVP is
   ALWAYS upserted to `claimed`. This is the fix for "re-claim after releasing
   did not claim".
3. **`upsert_event_rsvp`** (recreated). State `claimed` raises `P0001` with
   message `night_full` when the claimed count has reached the room's
   `max_seats` and the caller is not already claimed.
4. **`list_arrival_candidates`** (recreated). Only members whose RSVP is
   `claimed` can appear, so a member who releases politely is not on the host's
   forfeit list.

### `114_event_cancel.sql`

1. **`cancel_event(p_event_id uuid)`** (new). Host only (`is_room_host`). Every
   seat deposit still in escrow is returned on the `check_in_seat` path, then
   the event row is deleted the way live `delete_event` deletes it. One
   transaction: cancelling a night never costs anyone their deposit.
2. **`delete_event`** (recreated). Same body plus `search_path = public`; the
   host guard moves from `created_by = v_caller OR is_room_host(...)` to
   `is_room_host(...)` alone, so a former creator who handed the room over does
   not keep the delete button.
3. **`update_event_played_at`** (recreated) with the same `is_room_host` guard
   and `search_path = public`.
4. **`update_event_name(p_event_id uuid, p_name text)`** (new). The live
   database had no host-authorised rename: `update_event_member_fields` writes
   only note and venue, and the events RLS update policy authorises on
   `rooms.created_by`. A host who took the room over could not rename a night at
   all. The guard here reads the membership role.

## Client

### Step 3 - release, decline, a full night

- **Escrow rooms route through `release_seat`.** Release and decline push the
  optimistic RSVP, then call `RoomService.releaseSeat(eventId:state:)`, which
  uses `store.releaseSeat` when the room is in escrow mode and the ordinary
  RSVP upsert otherwise. Non-escrow rooms behave as before.
- **Release is instant with Undo.** A bottom toast `Seat released.` carries
  `Undo` for five seconds; Undo re-claims the seat (the server returns the
  deposit, and the re-claim takes it again).
- **A full night says so.** When claimed count >= `maxSeats` and the caller is
  not claimed, the occasion card replaces the claim control with the grey
  caption `All {n} seats are taken.` A `night_full` error rolls back the
  optimistic claim and shows the same line
  (`RoomService.isNightFullError` matches the P0001 text).
- **`RoomService+EventChange.swift`** (new). `eventDidChange(eventId:)` cancels
  the event's briefing trio via
  `NotificationDispatcher.shared.cancelBriefingTrio(eventId:)`, force-reloads
  the active event, and re-schedules the trio only when the night still exists.
  Called after every claim, release, decline, edit and cancel in this lane.

### Step 4 - edit and cancel a night

- **`EditEventSheet`** is titled `Edit night` with Name, When (DatePicker),
  Venue and Note. Save writes name through `update_event_name`, the date through
  `update_event_played_at`, and venue/note through the existing
  `update_event_member_fields`.
- **Cancel.** The bottom destructive row `Cancel this night` opens
  `confirmationDialog("Cancel {name}?", message: "Everyone's seat and deposit
  goes back.")`, calls `cancel_event`, then dismisses.
- **`AddEventSheet`** gained optional Venue and Note fields and
  `init(roomId:onSaved:initialPlayedAt: Date? = nil)` (exact name shared with
  lane S1) that seeds the date.
- **Headline pack.** The "last one you tap is the headline" copy is gone; the
  headline is the first selected pack in display order, and the selection is
  kept sorted to that order.
- `eventDidChange` runs after every save and cancel.

### Step 5 - settings by role, leave a room

- **`RoomSettingsSheet`** branches on `room.userRole`. Host: full hub (Social,
  Operations, Questions, Casino chips, autosave, Season, Delete room). Member:
  My notifications, My calendar, Members (read-only), Packs (read-only).
- **Leave room** sits at the bottom for both roles: red destructive button,
  `confirmationDialog("Leave {room}?", message: "Your season history stays with
  the room.")`, `leave_room`, then dismiss. The last host sees the grey caption
  `Make someone else host first.` instead (client-side check from the roster;
  the server's `last_host` maps to the same sentence).
- Rooms list rows (iPhone list and iPad sidebar) carry a trailing swipe action
  and a context menu `Leave room` with the same confirmation. A page-level
  watcher pops the stack when the room leaves the caller's list.
- `RoomService.leaveRoom` drops the room's caches, cancels its pending briefing
  trios, and refreshes the rooms list.
- No server work was needed: live `leave_room` (migration 093) already matches
  the brief, including `last_host`.
- Tests: three new cases (member leaves and the room disappears from their
  list; last host refused; leaving a room you are not in is a no-op).

### Step 6 - first run, create, join, Rooms list

- After create or join the new room opens immediately: both sheets gained an
  `onCreated` / `onJoined` callback that fires after dismissal plus a 400 ms
  beat; `RoomPage.openRoom(id:)` sets both `roomsPath` (iPhone) and
  `selectedRoom` (iPad).
- Empty Rooms state: primary `Enter a join code`, grey secondary `Starting your
  own games night? Create a room`.
- `JoinRoomSheet` gained a SwiftUI `PasteButton` that fills the code only when
  the pasted text normalises to six letters and digits, and the footer `Ask the
  host for the six-character code. They can share it from the room page.`
- Rooms list `Live now` only when `playedAt <= now && settledAt == nil`,
  otherwise the night's short date and time (`Fri 7:30pm`). The accent dot and
  hero label use the same check.
- Fixed the escaped `\(name)` interpolation in `RoomPage.overlapLine`; dropped
  the Resume hero when there is one room.
- Host empty-room hero (fewer than two members): primary `Invite friends`
  (ShareLink over a join code minted on demand) with grey `Add a night` beneath
  it. The Members invite row's copy icon is `doc.on.doc`.

### Step 7 - arrivals are fair

- `ArrivalCard` is hidden until the grace window has passed; before then the
  host sees one grey caption `Arrivals open at {time}` in the card's slot.
- Each row: grey `Give it back` (waive) and red `Keep` ->
  `confirmationDialog("Keep {name}'s {amount} CC?")` -> forfeit. The two Skip
  buttons are merged into `Give it back`.
- Behaviour only: no chrome restyled, so lane S4 can restyle the card freely.
- `ArrivalCard` API changed from `onForfeit` / `onSkipTexted` / `onSkipAway` to
  `onGiveBack` / `onKeep`; `resolveArrivalCandidate` lost its `reason:` param.

## Tests

`TestsS3.swift` (new, 15 cases) is a Foundation-only file added to `SRC_FILES`
in `build-and-run-tests.sh` and registered as `runS3Tests(runner)` in
`main.swift`. Cases cover:

- release returns a held deposit; `.declined` returns it too; release is
  idempotent; re-claim re-takes the deposit; release/decline free the chair in
  the briefing seat count;
- rename and reschedule (including empty name and past date refusals); cancel
  removes the night and a second cancel throws;
- member leave drops the room from their list; last host refused; leave is a
  no-op for a room you are not in.

No existing test was deleted or weakened.

## Flags for TARS

1. **`ArrivalPromptVoice.promptLine` copy.** It still ends with "Forfeit it?",
   which now reads off: giving the deposit back is the default and the red
   action is called `Keep`. `GamesRoom/Models/SeatDeposit.swift` is outside this
   lane's ALLOWED FILES, so it was left alone. Suggested: "{mascot}: {name}
   hasn't checked in. {name}'s {amount} CC deposit is still held."
2. **Arrival grace logic location.** `ArrivalGrace` lives in
   `GamesRoom/Views/ArrivalCard.swift`, not under `GamesRoom/Services/`,
   because ALLOWED FILES permits no new Services file here and the allowed new
   Services file (`RoomService+EventChange.swift`) is not in the Foundation test
   build. The brief asks for no test on step 7, so it is untested. If TARS wants
   it gated, the enum can move to an allowed Services file plus `TestsS3.swift`.
3. **Rooms list is now a real `List`.** SwiftUI only gives a row a trailing
   swipe action inside a `List`, so the iPhone Rooms list became a `List` and
   the rounded card around the rows is gone (a surface block with a hairline,
   i.e. quieter). Lane S4 owns styling tokens if the card is wanted back.
4. **New `update_event_name` RPC.** Step 4's Name field needed a host-authorised
   rename that the live database did not have; migration 114 adds it. If TARS
   does not push 114, renaming a night fails and the rest of the edit still
   saves.
5. **Migrations are unapplied by design.** `113_seat_flows.sql` and
   `114_event_cancel.sql` are for TARS to push. Verification queries are at the
   top of each file.
