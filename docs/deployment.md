# Games Room — Deployment runbook

> **Status.** Skeleton created in V0.8 closeout (B1.4). Populated in
> M6.4. The next engineer / operator should be able to build →
> TestFlight → App Store from this doc alone.

## Live environment

| Surface | Identifier | Notes |
|---------|-----------|-------|
| Supabase project | `bnrgkdcluopicqdpmrtu` | Project dashboard is the canonical source for the URL + anon key. The local build reads them from `GamesRoom/Config.xcconfig` (gitignored). |
| App Store Connect | (filled in M6.3) | Apple ID team, bundle id, TestFlight app id. |
| GitHub remote | (filled in M6.4) | The branch → release flow + tag conventions. |

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

(Filled in M6.4 once M6.3 App Store metadata + M6.5 TestFlight
build land. Sequence: archive → `xcrun altool --validate-app`
→ `xcrun altool --upload-app` → App Store Connect → TestFlight
beta review → App Store review.)

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

## Secrets

- `SUPABASE_URL` + `SUPABASE_ANON_KEY` — in `GamesRoom/Config.xcconfig`,
  gitignored. The build host reads them from the developer's local
  `~/.config/games-room/secrets.env` via the Xcode build phase.
- Apple Developer Team ID + signing identity — encoded into
  `GamesRoom.xcodeproj/project.pbxproj` (signed by the repo
  owner, not secrets).
- Mascot LLM API key — opt-in per room via
  `room.mascot_api_key`. Lives in `public.rooms` and is gated
  by RLS so only the host can read/write it for their room.

## Migration numbering convention

`Supabase/migrations/` is numbered `001…NNN` and **not** in
strictly monotonic order — migrations `037`, `038`, `042`, `043`
were added out of band during V0.26 + V0.29 work and were
appended at the next available slot rather than renumbered.
Down migrations are co-located with their up counterpart. The
convention is documented here so future operators don't try to
"fix" the gap.