# AGENTS.md

Games Room: an iOS/SwiftUI app (Supabase + Postgres) for friends-of-friends game
nights. One repo holds the app (`GamesRoom/`), the SQL (`Supabase/migrations/`),
the Foundation test runner (`Tests*.swift`, `main.swift`), the Maestro gates
(`.maestro/`) and the docs (`docs/`).

## The two gates

Both run from the repo root. Nothing ships unless both are green.

    bash .maestro/fastgate.sh --compile   # unit runner + SwiftUI parse-check + xcodebuild
    bash .maestro/gate.sh                 # the full gate, including the 19-screen sweep

- `build-and-run-tests.sh` is the unit runner. It compiles a Foundation-only
  slice: `Models/`, `Packs/`, the named services and every `Tests*.swift` you
  list in `SRC_FILES`. A new test file must be added there **and** called from
  `main.swift`.
- A fresh worktree needs `GamesRoom/Config.xcconfig` (gitignored) or `xcodegen`
  fails. Copy it from `~/Projects/games-room`; never commit it.
- Deleting iCloud ghost duplicates is part of the loop:
  `find . -name '* [0-9]*.swift' -not -path './.archive/*' -delete`.

## State machines

Every screen, notification and RPC is a consumer of one named machine. The
machine lives in one pure type in one file, with a table test, and its server
twin is named beside it. **Read `docs/STATE-MACHINES.md` before you add or
change any derived state** — it maps each machine to its states, owner file,
server twin, pinning test and a "never do" line. A second copy of a rule is a
bug even when the two copies agree today.

## Migrations

`Supabase/migrations/NNN_*.sql` are applied in order and are **append-only**.
Never edit an applied migration; add a new one. Do not change a user-visible
string, accessibility label or identifier the screenshot sweep asserts on
without changing the sweep in the same commit.
