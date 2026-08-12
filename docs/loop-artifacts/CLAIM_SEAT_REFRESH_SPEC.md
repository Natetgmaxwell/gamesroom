# Claim-seat refresh fix — spec

## Bug

"Claim your seat" doesn't refresh the UI. The RPC succeeds server-side but the
seat grid, briefing seat count, and slot state don't update.

## Root cause (verified in source)

1. `RoomService.upsertEventRSVP` (GamesRoom/Services/RoomService.swift ~469)
   updates `rsvpByEvent[eventId] = row.state` but does NOT reload the event
   RSVP list (`eventRSVPsByEvent`) nor the briefing (`briefingByEvent`). The
   seat grid reads `cachedEventRSVPs(eventId:)` and the briefing reads
   `cachedBriefing(eventId:)` — both stay stale after a claim.
   - InMemoryRoomStore updates its own briefing on upsert, so the in-memory
     path looks fine; LiveRoomStore does NOT, so the live path is stale.
2. `claimSeat` / `declineSeat` / `releaseSeat` in RoomDetailView (~758-789)
   swallow errors (`catch { _ = error }`). If the RPC throws, the user sees
   nothing.

## Fix

1. In `RoomService.upsertEventRSVP`, after the store write succeeds and the
   `rsvpByEvent` cache is updated, reload the seat-grid rows and the briefing:
   `_ = await loadEventRSVPs(eventId:)` and `_ = await loadBriefing(eventId:)`.
   These are already `@Published`-backed, so the view re-renders.
2. Surface claim/decline/release errors visibly in RoomDetailView. Add a
   view-local error state + `.alert` on the body that shows
   `roomService.lastError` (or the thrown error) when a seat action fails.
   Do not swallow.

## Acceptance criteria

- Tap "Claim seat" → seat grid updates to show the claimed seat.
- The briefing slot transitions from upcoming to claimed state.
- Seat count in the briefing updates ("1 of 6 claimed").
- If the RPC fails, the user sees an error, not silence.
- Tests + parse-checks green.

## Deviations (claim-seat refresh loop)

- The store-contract test "upsertEventRSVP followed by
  fetchEventRSVPs" could not be written as-spec'd at the
  `InMemoryRoomStore` layer. Investigation: the in-memory `events`
  map is keyed by `roomId` (see `InMemoryRoomStore.swift` line 247,
  564, 890, 929) while `fetchEventRSVPs(eventId:)` looks up by
  `eventId` (line 742), so the read always returns `[]`. The seat
  grid never had a working test-fixture path on this store; the
  live `LiveRoomStore` path is the source of truth for the seat
  grid. The test in `main.swift` instead exercises the
  `upsertEventRSVP` return-value round-trip and the briefing
  seat-count mirror (`BriefingSummary.seatsClaimed` increment) —
  both of which drive the visible surfaces the bug report names
  ("the briefing slot transitions", "seat count in the briefing
  updates"). Restoring the seat-grid data-path test requires a
  follow-up that re-keys `InMemoryRoomStore.events` by `eventId`;
  out of scope here (5-file change contract).
