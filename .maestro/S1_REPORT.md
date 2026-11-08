# S1 report: night works (branch s1/night-works)

Based on main @ febbae3. Nothing pushed, merged or applied. Migration 107 is written, not applied.

## Steps and commits
| Step | Commit | What |
|---|---|---|
| 1 | f7dd73e | Migration 107: `get_active_event` priority (live, settled 24h, next future), restored columns, `settle_event` |
| 2 | 2d9469e | `settleEvent` plumbing; active event honours `force` |
| 3 | cb86a21 | `NightPlan` (pure) picks the one next action |
| 4 | 33c6de2 | Live card follows NightPlan and `event.packSlugs`; `Score which game?`; `I'm here`; `Waiting for the table` caption; grey secondaries |
| 5 | 4d8b674 | `Settle the night` with 5 s Undo toast, failure caption, haptic, Live Activity end, forced reloads; `Plan the next night` (AddEventSheet `initialPlayedAt`); `.settleRound` removed |
| 6 | 58d884c | Score sheet starts on max round + 1 across packs; `Round {n}` and `Last: {winner} won round {n-1}` |
| 7 | f575799 | Season awards as their own section for every member (7 days, `Done`); settled-night recap section above the next night (TARS) |
| 8 | this commit | Sweep seeds `night-arrivals`, `night-one-round`, `night-settled`; this report |

Each step has a follow-up commit ticking the brief and STATE.

## Tests
- Before the lane: 302 cases. After: 333 cases, 0 failed (`build-and-run-tests.sh`).
- Final gate: `bash .maestro/fastgate.sh --compile` -> `FASTGATE: PASS` (xcodebuild simulator build succeeded).
- Not run (lane rules): `.maestro/gate.sh`, simulator, xcodebuild test, screenshot sweep of the new seeds.

## Open for TARS
1. **Migration 107 ranks a settled night (24h) above a future night.** For 24h after a settle, `get_active_event` never returns a future night, so (a) a night scheduled before the settle stays hidden, and `Plan the next night` can show and then hit the one-upcoming-event rule; (b) other devices see only the recap until the 24h pass. Client side, the host who schedules on this device lands on the new night (RoomService `scheduledNextByRoom`) with the recap above it. Full fix: rank future above settled in 107; the client already keeps the recap from its own cache (`recentlySettledByRoom`). Not changed per your instruction.
2. `settle_event` returns no deposits (see STATE step 1): held deposits come back via `I'm here`, play, or the host's arrival card.
3. `NightPlan` never emits `claimSeat` (no claim state in `NightInput`); RSVP stays with the briefing card.
4. Arrival on rooms without escrow has no signal, so claimed seats and the host count as arrived; `Waiting for the table` only shows on escrow rooms before anyone checks in or plays.
5. The iPad scoring dashboard still scores `event.packSlug`; the phone sheet is used when the chosen pack is not the headline pack.
6. The `chip-scan` seed's header comment still names the removed `eventHasSingleWinnerPack()` (existing seeds left untouched per the brief).
