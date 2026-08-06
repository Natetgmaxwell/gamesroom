# Games Room — Deployment runbook

> **Audience.** The next engineer / operator who needs to ship a
> Games Room build from a fresh checkout: build → TestFlight →
> App Store Connect → App Store review. Created in B1.4, filled
> out in M6.4.

## Live environment

| Surface | Identifier | Notes |
|---------|-----------|-------|
| Supabase project | `bnrgkdcluopicqdpmrtu` | Project dashboard is the canonical source for the URL + anon key. The local build reads them from `GamesRoom/Config.xcconfig` (gitignored). |
| App Store Connect | app id (TBD) | Apple ID team `37S7KT7W83`, bundle id `com.gamesroom.app`. Filled in M6.3 + M6.5. |
| TestFlight | app id (TBD) | Same bundle id; the TestFlight app is auto-created the first time `xcrun altool --upload-app` lands. |
| GitHub remote | (TBD) | The branch → release flow + tag conventions; filled in below. |

## Build configurations

Four combinations of `Configuration` (Debug / Release) ×
`Credentials` (Dev / Prod) cover every ship path. The matrix
controls which Supabase project + Apple team are wired into the
build via `xcconfig` overlays.

| Configuration | Credentials | Supabase | Apple team | Ship destination |
|---------------|-------------|----------|-----------|------------------|
| Debug / Dev | Dev | `bnrgkdcluopicqdpmrtu` (dev alias if configured, else prod read-only) | `37S7KT7W83` (personal) | Local simulator + TestFlight internal |
| Debug / Prod | Prod | `bnrgkdcluopicqdpmrtu` | `37S7KT7W83` | Local simulator only |
| Release / Dev | Dev | `bnrgkdcluopicqdpmrtu` | `37S7KT7W83` | TestFlight internal (pre-prod) |
| Release / Prod | Prod | `bnrgkdcluopicqdpmrtu` | `37S7KT7W83` | TestFlight external + App Store |

## Build → TestFlight → App Store

### Prereqs (one-time per host)

- macOS with Xcode 27 (or whichever Xcode version matches the
  `GamesRoom.xcodeproj` deployment target — see `IPHONEOS_DEPLOYMENT_TARGET`
  in `project.pbxproj`).
- `xcode-select -p` points at the right Xcode.app.
- Apple ID is in the developer team `37S7KT7W83` (or the team's
  admin has added it).
- The repo's `GamesRoom/Config.xcconfig` has the Supabase URL +
  anon key (gitignored — set per host, never committed).

### Build → archive

```bash
cd games-room
xcodebuild \
    -project GamesRoom.xcodeproj \
    -scheme GamesRoom \
    -configuration Release \
    -archivePath build/GamesRoom.xcarchive \
    archive
```

The archive lands at `build/GamesRoom.xcarchive`. Sanity-check it
with:

```bash
xcodebuild -exportArchive \
    -archivePath build/GamesRoom.xcarchive \
    -exportPath build/export \
    -exportOptionsPlist build/ExportOptions.plist
```

(The `ExportOptions.plist` is checked in for the team's
signing identity.)

### Validate

```bash
xcrun altool --validate-app \
    -f build/export/GamesRoom.ipa \
    -t ios \
    --bundle-id com.gamesroom.app \
    --bundle-version 0.1.0 \
    --bundle-short-version-string "0.1.0"
```

If the validator returns non-zero, fix the metadata (usually
export-compliance or privacy labels — both covered in
`docs/app-store-metadata.md`) and re-archive.

### Upload to App Store Connect

```bash
xcrun altool --upload-app \
    -f build/export/GamesRoom.ipa \
    -t ios \
    --bundle-id com.gamesroom.app \
    --bundle-version 0.1.0 \
    --bundle-short-version-string "0.1.0"
```

The upload appears in App Store Connect under the build. Pick
the build for **TestFlight → Internal Testing** first, then
**External Testing** once the host-of-record cohort has been
set up.

### App Store review

- Open App Store Connect → My Apps → Games Room.
- Add the build to a new version (or an existing draft).
- Fill in the metadata per `docs/app-store-metadata.md`.
- Submit for review. Standard review SLA is 24–48 hours.

## Rollback

- **App Store:** ship a follow-up build that supersedes the
  broken one. App Store does not roll back versions; the fastest
  fix is a hotfix release on the existing branch.
- **TestFlight:** remove the build from TestFlight in App Store
  Connect, expire testers. Tester installs are not auto-revoked
  once they accepted the build.
- **Supabase:** every V0.8 migration is paired with a
  `down.sql` in `Supabase/migrations/` for fast local rollback.
  Production rollbacks are gated on a separate ops runbook
  (not in this repo).

## Offline dev path (no Supabase)

The default `RoomStore` is `InMemoryRoomStore.shared`. Running
the app with no Supabase configuration falls back to this store
and the seeded demo data (`seeds/seed-rooms.json` — TBD path;
currently in `main.swift` test fixtures). Useful for:

- Previews / `#Preview` blocks (`SeatGridView`,
  `LeaderboardRow`, etc.).
- Simulator runs without a Supabase project.
- Local verification of M0 onboarding flows before the live
  Supabase project is wired up.

Switch to `LiveRoomStore` by setting both:

```bash
export SUPABASE_URL=https://bnrgkdcluopicqdpmrtu.supabase.co
export SUPABASE_ANON_KEY=<the-key>
```

…and launching the app — `SupabaseClientProvider` reads the env
vars on first access.

## Secrets

- `SUPABASE_URL` + `SUPABASE_ANON_KEY` — in `GamesRoom/Config.xcconfig`
  (gitignored). The Xcode build sets them as build settings; the app
  reads them out of `Info.plist` via `Bundle.object(forInfoDictionaryKey:)`
  in `GamesRoom/Services/SupabaseClient.swift`. The xcconfig path is the
  canonical source — no other secrets layer is wired in.
- Apple Developer Team ID + signing identity — encoded into
  `GamesRoom.xcodeproj/project.pbxproj` (signed by the repo
  owner, not secrets).
- Mascot LLM API key — opt-in per room via
  `room.mascot_api_key`. Lives in `public.rooms` and is gated
  by RLS so only the host can read/write it for their room.
- App Store Connect API key — used by `xcrun altool`. Lives
  in `~/.appstoreconnect/private_keys/AuthKey_<id>.p8`. Never
  committed.

## Migration numbering convention

`Supabase/migrations/` is numbered `001…NNN`. Two slots are
deliberately unused: `037` and `038` were reserved during V0.26
broadcast-calendar work that ended up landing in different slots.
Future migrations should continue at the next available slot
(`044`+); do not renumber existing files to fill the gap — the
numbers are stable references in issue trackers and the V0.8 build
phase commit history.

Down migrations are co-located with their up counterpart. The
convention is documented here so future operators don't try to "fix"
the gap.

## CI / CD

The CI lane (`.github/workflows/ci.yml`, added in M6.2) runs the
Foundation test runner + parse-check + pbxproj validator on every
PR + push to `main`. The lane is **not** required to hit the live
Supabase project — the Foundation runner is local-only.

The CD lane (TestFlight / App Store uploads) is **not** wired in
CI — it requires the App Store Connect API key + macOS signing
host. The plan calls this out as a future improvement; the
current release flow is local-xcodebuild → manual `xcrun altool`
upload (covered above).

## What ships in this repo vs not

In this repo:

- Xcode project, Swift source, Foundation tests, parse-check.
- CI lane (`.github/workflows/ci.yml`).
- `docs/deployment.md` (this file).
- `docs/app-store-metadata.md`.
- Supabase migrations (`Supabase/migrations/`).
- `scripts/verify-xcode-project.py`.

Not in this repo (host / external):

- `GamesRoom/Config.xcconfig` with the real Supabase keys.
- Apple Developer certificates / signing identities.
- App Store Connect API key.
- TestFlight tester rosters.