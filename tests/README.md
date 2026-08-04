# Games Room — Test runner (no Xcode)

The iOS app lives in `../GamesRoom.xcodeproj` and is the canonical
build target. Tests for that target run via `xcodebuild test`
on a Mac with Xcode.app installed.

This folder holds a parallel **single-shot Foundation test
runner** so P0 work can be exercised on a build host without
Xcode. It is intentionally minimal — there is no SPM target, no
XCTest, no extra dependencies — because the toolchain on this
host is the stripped-down CommandLineTools 6.2.4 SDK that
emits `.swiftmodule` files other invocations cannot read.

## Layout

```
tests/
  main.swift                  Foundation-only test cases
  build-and-run-tests.sh      compile + run script
```

## Running

```
./build-and-run-tests.sh
```

The script compiles `main.swift` together with every
`../GamesRoom/Models/*.swift` and `../GamesRoom/Packs/*.swift`
source file into a single `games-room-tests` binary (same
process — no swiftmodule interop) and runs it.

Exit code: `0` on all-pass, `1` on any failure.

## Coverage (21 cases)

- `PackRegistry` — default ordering, isRegistered gate,
  scoring-type discriminator, winPoints lookup.
- `PackScoringResolver` — both scoring families (single_winner,
  withdraw_return) + zero-returned "did_not_scan" edge.
- `ScoreEntry` JSON round-trip with typed metadata.
- `Room` decoder — full V0.26 + host_journal shape AND the
  legacy fallback path (missing V0.26 columns).
- `RedeemedRoom` — server shape + missing-name fallback.
- `BriefingSummary.seatsLeft` — derived value + zero-floor.
- `Event` JSON round-trip — venue + hostNote preserved.
- `MemberRSVPState.hasResponded` + rawValue round-trip.
- `MemberRSVP` JSON decode with `responded_at`.
- `PackMetaValue` JSON round-trip — bool, int, string.
- `LeaderboardEntry` trajectory round-trip.

## Limitations

- No `import Supabase` / `import SwiftUI` / `import
  UserNotifications` coverage. Those files (CasinoService,
  RoomStore live impl, etc.) need the iOS SDK; they're exercised
  on a Mac with Xcode via `xcodebuild test`.
- No tests for the `LiveRoomStore` RPC wrappers themselves; the
  protocol coverage comes through `InMemoryRoomStore` round-
  trips, which is what the preview/dev-without-network path
  hits.

## Adding a new test

Append a new `runner.run("name") { ... }` block at the end of
`main.swift`. Use the existing `assertEqual`, `assertTrue`,
`assertFalse`, `assertNil`, `assertNotNil` helpers (mirrors
XCTest's API). No fixtures / setup / teardown — every case is
self-contained.

Re-run `./build-and-run-tests.sh` to confirm.