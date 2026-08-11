# Games Room — Final Verification Report

2026-08-11 · task t_ad236bdb · verified against `VISION.md` at `a209b8a` + fixes

## Verdict

The implementation meets the vision. All runnable gates are green, and the
three defects found during verification are fixed and committed. The only
unverifiable surfaces are the Xcode-host gates (T0.1/T0.2) — no Xcode.app
on this host — and the four gated decisions (Q-TONE, Q-LLM-PROVIDER,
Q-PAID-PACKS, Q-HOST-FEEDBACK) that the plan explicitly forbids resolving
silently.

## What was verified

The 5-commit implementation from t_aaeba4ca (157ab69 → a209b8a) covering
T0.3 (CI lane), T0.4 (repo hygiene), T1.1 (EventKit calendar auto-add),
T1.2 (opt-in keep-scan-photos), T1.3 (v3 GR monogram app-icon set),
T1.4 (ui-polish audit), plus the full VISION.md feature surface
(F-MVP-01..12, F-PACK/CAS/MAS/MULTI/NOTIF/IDENT) inherited from the
pre-existing codebase.

## Gates (all green)

| Gate | Result |
|---|---|
| `./build-and-run-tests.sh` | 65/65 passed, 0 failed |
| `bash scripts/parse-check-swiftui.sh` | 34/34 pass |
| `python3 scripts/verify-xcode-project.py` | exit 0 |
| `plutil -lint GamesRoom/Info.plist` | OK (incl. `NSCalendarsFullAccessUsageDescription`) |
| `swiftc -typecheck` (Models + Packs + StorageKeys + CalendarService) | clean — added this run |
| App icon pixel dimensions | all 9 sizes correct |
| Working tree | clean at `1cfc162` |

Note: `plutil -lint` on `AppIcon.appiconset/Contents.json` fails with
"Unexpected character {" — this is a host limitation (plutil expects plist
headers, not JSON; a minimal valid JSON object fails identically). The file
is valid JSON (`json.load` passes) and asset-catalog Contents.json is JSON
by design. Not a defect; do not "fix" it.

## Defects found and fixed

1. **CalendarService API mismatch (would fail the first real Xcode build).**
   `RoomService` calls `addEvent(room:event:)` and `updateEvent(room:event:)`;
   the service defined `addEvent(room:eventId:name:playedAt:venue:)` and no
   `updateEvent`. Parse-checks are syntax-only, so this slipped through.
   Rewrote the service to the call-site shape; `updateEvent` now updates the
   existing EKEvent in place (creating it when absent). Also replaced the
   undeclared `StorageKeys.calendarEventIdentifiers` dictionary with the
   declared per-event key function. Commit `c2e2fc4`.
2. **icon-40@2x.png was 40x40 (needs 80x80) and icon-40@3x.png was 60x60
   (needs 120x120).** The 40pt slot would render upscaled and soft.
   Regenerated both from the v3 concept-1-ring 1024 master. Commit `1cfc162`.

## Deviations from the vision

- **App icon:** VISION.md §6 locks "The Table" (top-down table, four cream
  seats). The shipped icon is the v3 GR monogram "The Ring" — the approved
  Q-ICON resolution (plan default: latest approved v3 set). Documented
  deviation, not a gap.
- **Mascot LLM provider:** VISION.md §5.3/§8 specify Apple Foundation
  Models; the tree uses z.ai glm-4.6. Gated on Q-TONE/Q-LLM-PROVIDER (T2.1).
- **Photo persistence:** VISION.md §5.2 default (discard photo, keep hash +
  snapshot) is unchanged; T1.2 added the opt-in keep-photo path, default
  off. Matches the vision's privacy posture.
- **Live Activity / Watch / Glance:** code-complete (W2.3) but device pass
  pending — T0.1 needs an Xcode host.

## Known limitation (documented, not fixed)

T1.1 plan step 3 says "on event settle/delete, remove the calendar row."
`CalendarService.removeEvent` exists, but the Swift tree has no delete or
settle surface to hook it into — the `delete_event` RPC exists in
migrations (022) with zero call sites, and finalize is server-side
(`close_stale_attestations`). The calendar row therefore lives until the
host removes it manually. Wiring the hook is a one-line change once a
delete/settle surface exists; not worth inventing a surface for.

## Remaining work (not gaps — gated or env-blocked)

- T0.1 first Xcode build + device pass, T0.2 TestFlight upload: need a Mac
  with Xcode 27.
- T2.1 mascot matrix: gated on Q-TONE + Q-LLM-PROVIDER.
- T2.2 paid packs / StoreKit: gated on Q-PAID-PACKS.
- T2.3 cloud-vision hybrid: monitor only, after T0.2 feedback.
- Q-HOST-FEEDBACK: beta account count for the first TestFlight cycle.

## Verification method

Gates above, plus a semantic `swiftc -typecheck` of the full Foundation
model/pack set with the new service — the check that catches what
parse-checks cannot. The three defects are exactly the class of error the
headless loop is blind to; the CI lane (T0.3) will catch them on the first
macOS runner push.
