# T1.4 — ui-polish audit findings

2026-08-11 · task t_aaeba4ca · design bar = VISION.md §5.4 ("we are not aiming to be mediocre")

## Audit scope

The 10 V0State surfaces in `RoomDetailView` + the shared components they render, checked against the four design-bar axes: one CTA per state, mascot footer caption, 80/20/10 palette discipline, `chair.fill` semantics.

## Findings

| Surface | One CTA | Mascot caption | Palette | chair.fill |
|---|---|---|---|---|
| .loading | n/a (spinner) | — | themed | — |
| .justSettled (CeremonialCard) | n/a (ceremonial) | — | themed | — |
| .tonightEvent (WitnessSlot) | withdraw | — | themed | — |
| .inPlay (WitnessSlot) | withdraw | — | themed | — |
| .settleRound (WitnessSlot) | scan | — | themed | — |
| .upcoming (BriefingSlot) | claim/decline | — | themed | — |
| .claimed (BriefingSlot) | release | — | themed | — |
| .declined (BriefingSlot) | re-accept/re-decline | — | themed | — |
| .seasonClose (AwardsCard) | drowning opt-in | — | themed | — |
| .readStandings | n/a (empty state) | — | themed | — |
| Room page footer | — | MascotFooterCaption | themed | — |
| Add-event CTA (host toolbar) | — | — | themed | chair.fill |
| Seat grid | — | — | themed | chair.fill |

## Verdict

No design-bar violations requiring fixes. Ad-hoc colors in the tree are semantic, not decorative: error red (`.red.opacity(0.85)`), chip identity colors in `ChipScanSheet`, camera preview black, and the `Color.orange` correction dot in `LeaderboardRow`. All structural styling routes through `Theme.Palette` / `Theme.Typography` / `Theme.Layout` / `Theme.Icon`.

## Verification

- `./build-and-run-tests.sh` → 65 passed, 0 failed
- `bash scripts/parse-check-swiftui.sh` → 34/34 pass
- `python3 scripts/verify-xcode-project.py` → exit 0
