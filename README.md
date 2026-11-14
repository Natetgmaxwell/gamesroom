# GamesRoom

**Plans the night. Gets out of the way.**

GamesRoom is the app for your regular games night with friends. It fills the seats, sends the reminders and keeps the score, so the host stops chasing people in the group chat and gets to play.

[![Download on the App Store](https://gamesroom.nateterrence.net/app-store-badge.svg)](https://apps.apple.com/app/gamesroom/id6801997519) · [gamesroom.nateterrence.net](https://gamesroom.nateterrence.net)

## How a night runs

1. The host books the night and picks what is on the table. Every night runs on casino chips.
2. Members claim a seat. Reminders go out on a quiet cadence: week before, a few days out, morning of. Claimed seats get logistics only, declined gets silence.
3. At the table, one phone. Members take chips from the bank, play any game, and scan what is in front of them at the end. The scan is the cash-out.
4. The night settles itself. Scores land on the ledger, the recap closes on a person, and the season keeps the story.

No feed, no DMs, no streaks. The ledger is the durable social layer: real tables, real friends.

## What is in here

| Path | What it holds |
|---|---|
| `GamesRoom/` | The iOS app (SwiftUI) |
| `GamesRoomWatch/`, `GamesRoomWidgets/` | The Watch app and home-screen widgets |
| `Supabase/` | The backend: Postgres migrations, SECURITY DEFINER RPCs, row-level security policies, scheduled jobs |
| `GamesRoomUITests/` | The screenshot sweep that pins 23 named app states on every release |
| `docs/STATE-MACHINES.md` | Every state machine in the app, named once, with its owner file and its test |
| `website/` | The marketing site |

## Architecture, in four rules

- **The server owns the rules.** Every read and write goes through SECURITY DEFINER RPCs behind row-level security. The client renders server truth; it does not hold a second copy of a rule.
- **Nights end themselves.** A night's close time is known the moment it is booked (start plus the room's window), so the night's phase is derived at read time. A daily hygiene job converges the stored stamps; correctness never waits on a scheduler.
- **One scoring loop.** Chips. Withdraw to start, scan to cash out, one ledger. No other scoring path exists.
- **State machines are the contract.** Every "what state is this in" question has one named pure type, a SQL twin for the server, and a table test that pins it.

## Building it

You need Xcode 26+, [xcodegen](https://github.com/yonaskolb/XcodeGen), and your own [Supabase](https://supabase.com) project.

```sh
xcodegen generate
open GamesRoom.xcodeproj
```

`GamesRoom/Config.xcconfig` carries the backend endpoint and keys and is not committed. Point it at your own project and apply the migrations in `Supabase/` to run against a backend you control.

Unit tests run headless against a Foundation-only swiftc runner:

```sh
./build-and-run-tests.sh
```

The screenshot sweep needs a simulator and runs as `GamesRoomUITests` from the generated project.

## Credits

Built by Nathan Maxwell, with Connor. Tally, the house scorekeeper, keeps the ledger.

© 2026 Nathan Maxwell. All rights reserved.
