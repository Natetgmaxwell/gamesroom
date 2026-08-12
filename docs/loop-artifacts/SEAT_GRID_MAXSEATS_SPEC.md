# Seat grid shows maxSeats, not member count (spec)

## Context

Bug: "I can only see 2 seats to claim even though the max seats are 6 for the room."

`SeatGridRow` (RoomDetailView.swift) renders one cell per `rsvps` row and caps
columns at 4. With 2 members the grid shows 2 cells even when the event's
`maxSeats` is 6. There is no concept of "empty seats up to maxSeats."

The seat grid IS the seat-availability visual (US-14/15 seat deposits; VISION
§5.4 "emotional design on the moments that matter" — seeing open seats drives
the "claim yours" impulse). It must render `maxSeats` cells: claimed seats
filled with the member's initial, the rest open chairs labelled "open".

## Locked decisions (do not re-litigate)

1. **Cell derivation is pure Foundation.** New `SeatGrid` enum inside
   `GamesRoom/Models/EventRSVP.swift` (next to `SocialProof`), compiled by the
   test runner. No new Swift files anywhere — pbxproj must not change.
2. **Cells = maxSeats total.** Claimed RSVPs (in input order) fill the first N
   cells; the remaining `maxSeats - N` are open seats. Declined/unclaimed
   members do NOT get a cell — they are open chairs. `maxSeats` is the only
   source of the total.
3. **Column count adapts to maxSeats, not capped at 4.** `columns =
   max(2, Int(ceil(sqrt(Double(maxSeats)))))`. 6 → 3 (3×2), 4 → 2 (2×2),
   8 → 3 (3×3), 12 → 4. Never fewer than 2.
4. **SeatGridRow signature.** Add `let maxSeats: Int`. It consumes
   `SeatGrid.cells(maxSeats:rsvps:)` and `SeatGrid.columnCount(for:)`. The
   existing per-cell rendering (chair icon, initial, "open" label, yours
   highlight, accessibility label) is preserved for claimed cells; open cells
   render the outline chair + "open" label.
5. **BriefingSlot passes `event.maxSeats`.** The grid renders whenever
   `maxSeats > 0` (drop the `!rsvps.isEmpty` gate — with 0 members the grid
   should still show all-open seats). The social-proof caption below the grid
   still gates on claimed names (unchanged).
6. **Theme discipline.** Reuse existing `Theme.Icon.chair`/`chairFill`,
   `Theme.Typography`, `Theme.Palette`. No new tokens, no hardcoded
   colors/fonts/sizes.
7. **No backend change.** No migration, no RPC change. `event.maxSeats`
   already decodes (Event.swift line 51).

## File-by-file

1. **`GamesRoom/Models/EventRSVP.swift`** — add:
   ```swift
   /// Seat-grid derivation: maxSeats cells, claimed RSVPs first,
   /// the rest open. Pure Foundation so the runner can test it.
   enum SeatGrid {
       struct Cell: Identifiable {
           let id: Int
           let rsvp: EventRSVP?   // nil = open seat
       }
       static func cells(maxSeats: Int, rsvps: [EventRSVP]) -> [Cell]
       static func columnCount(for maxSeats: Int) -> Int
   }
   ```
   `cells` returns exactly `maxSeats` cells (clamp maxSeats to >= 0; 0 → empty).
   `columnCount` per decision 3.
2. **`GamesRoom/Views/RoomDetailView.swift`** — `SeatGridRow` gains
   `let maxSeats: Int`; `columns` uses `SeatGrid.columnCount(for: maxSeats)`;
   `body` iterates `SeatGrid.cells(maxSeats:rsvps:)`; `seatCell` handles a
   `Cell` (nil rsvp → open chair + "open" label + open accessibility label).
   `BriefingSlot` passes `maxSeats: event.maxSeats` and renders the grid when
   `event.maxSeats > 0`.
3. **`main.swift`** — `SeatGrid` tests (sync `runner.run` blocks):
   - 2 claimed of 6 → 6 cells, first 2 claimed, last 4 open.
   - 0 claimed of 6 → 6 open cells.
   - 6 claimed of 6 → 6 claimed, 0 open.
   - claimed > maxSeats → clamped to maxSeats cells (extra claimed dropped).
   - maxSeats 0 → empty.
   - columnCount: 4→2, 6→3, 8→3, 12→4, 2→2, 1→2 (min 2).
   - cell order preserves claimed input order.
4. **`docs/loop-artifacts/SEAT_GRID_MAXSEATS_SPEC.md`** — this file.
5. **`docs/loop-artifacts/.seat_grid_maxseats_loop.md`** — loop contract.
6. **`docs/loop-artifacts/.seat_grid_maxseats_prompt.md`** — prompt stub.

## Out of scope

- Seat cell name labels / tooltips (initials stay; the caption carries names).
- Reordering claimed seats beyond input order.
- Watch/widget surfaces.
- Any change to `SocialProof` or the caption logic.

## Verification

1. `./build-and-run-tests.sh` from repo root — all green. Test count shifts
   from 111; report the new number.
2. `./scripts/parse-check-swiftui.sh` — green.
3. `git diff --stat` — exactly the 6 files above.
4. Do NOT commit. Report files changed, test count, parse-check result,
   deviations.
