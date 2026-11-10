# State machines

Every screen, notification and RPC in this app is a consumer of one of the
machines below. The machine is a pure type in the file named here; that file
is the only place its transitions may be written. A second copy of a rule is
a bug even when the two copies agree today.

Line numbers are not quoted on purpose — grep the type. Every path and test
name below was read from this branch.

---

## 1. Night phase

**States** `NightPhase`: `none`, `upcoming`, `live`, `stranded`, `recap`, `past`, `cancelled`.

**Moves it** `NightPhaseResolver.phase(_ facts: NightFacts)` — a pure function of
`playedAt`, `settledAt`, the room's `autoCloseHours` and `now`. Settled wins
over the auto-close window; `playedAt <= now < playedAt + autoCloseHours` is
`.live`; at or past that line it is `.stranded`; a settle inside 24 h is
`.recap`, outside it `.past`. `.cancelled` is in the vocabulary (it is one of
the seven SQL values) and the resolver never returns it.

**Owner** `GamesRoom/Services/NightPhase.swift`

**Server twin** `public.night_phase(played_at, settled_at, auto_close_hours, now)`
in `Supabase/migrations/115_state_machine_guards.sql`; consumed by
`get_active_event__inner` (115) and `get_recent_settled_event` (107).

**Pinned by** `TestsP1.swift` — `P1: exactly at played_at + auto_close_hours is .stranded`.

**Never** write an inline `playedAt <= Date()` / `settledAt == nil` predicate in
a view, service or notification. Ask the resolver, or ask the phase a caller
already computed. Nine sites were replaced this way on 2026-11-09.

---

## 2. Room page slot

**States** `V0State`: `loading`, `justSettled(Event)`, `tonightEvent(Event)`,
`inPlay(Event)`, `upcoming(Event)`, `claimed(Event)`, `declined(Event)`,
`readStandings`.

**Moves it** `V0State.resolve(hasLoaded:phase:activeEvent:myRSVP:hasWithdrawn:)`
— first match wins, fed by `NightPhase`, never by a second clock read.

**Owner** `GamesRoom/Models/V0State.swift`

**Server twin** none (the slot is a client rendering decision; its inputs come
from `get_active_event` and `get_recent_settled_event`).

**Pinned by** `TestsP1.swift` — `P1: a night settled 25 hours ago is .readStandings, never live`.

**Never** compute the slot inline in the view body, and never use chip balance
as the "has played" signal — `hasWithdrawn` is the one definition.

---

## 3. Seat

**States** `DepositMode`: `off`, `escrow(amount:)`. `SeatPhase`: `open`,
`declined`, `claimedNoDeposit`, `held(deposit:)`, `arrived(deposit:)`,
`noShow(deposit:)`, `missingDeposit`. `SeatAvailability`: `open`, `full`,
`youHoldOne`.

**Moves it** `SeatPhase.phase(rsvp:deposit:mode:)` and
`SeatAvailability.compute(rsvp:seatsClaimed:maxSeats:)` — total over every
rsvp × deposit × mode. `missingDeposit` is the named impossible state and is
rendered, not hidden.

**Owner** `GamesRoom/Models/DepositMode.swift`, `SeatPhase.swift`,
`SeatAvailability.swift`

**Server twin** `claim_seat_with_deposit`, `upsert_event_rsvp`, `release_seat`,
`check_in_seat` (`113_seat_flows.sql`, guarded in `115`).

**Pinned by** `TestsP1.swift` — `P1: SeatPhase has exactly one answer for every rsvp x deposit x mode`
and `P1: a full night whose counts drop back to 7 of 8 is open again (the latch is gone)`.

**Never** cache a "night is full" flag. Availability is derived from counts on
every render; the deleted `nightFullEventIds` latch was the bug.

---

## 4. Deposit ledger

**States** a `seat_deposits` row's status: `held`, `returned`, `forfeited`.
No Swift type owns this; the ledger is server-side and the client only reads
the caller's own row.

**Moves it** `claim_seat_with_deposit` (held), `check_in_seat` (held →
returned), `release_seat` (held → returned), `remove_room_member` (kick:
held → returned, credited exactly once), `auto_close_stale_events`
(unresolved → forfeited at `played_at + auto_close_hours`).

**Owner** `Supabase/migrations/115_state_machine_guards.sql`

**Server twin** itself — this machine only exists in SQL.

**Pinned by** `Supabase/tests/115_probes.sql` — `115.c-kick-single-credit`,
`115.d-claim-after-forfeit`, `115.e-release-after-start`, `115.f-checkin-too-early`,
`115.g-autoclose-past`.

**Never** add a Swift-side ledger rule. The view shows the server's status and
maps refusal tokens through `ServerErrorCode`.

---

## 5. Briefing

**States** `BriefingOutcome`: `silenced(SilenceReason)` or
`scheduled([PlannedBriefingNotification])`. `SilenceReason`: `hidden`,
`roomOptOut`, `muted`, `unknownSeat`, `declined`. `BriefingCadence`: `local`,
`server`.

**Moves it** `BriefingReconciler.plan(_ context: BriefingContext, includeOnCreate:)`
— pure. `reconcile(context:)` only executes the plan (awaited adds, then
removes). `gateSilence` is the single predicate behind both the on-create keep
rule and the planner.

**Owner** `GamesRoom/Services/BriefingReconciler.swift`

**Server twin** `briefing_push_due(now)` and `briefing_push_cron_tick()` in
`Supabase/migrations/109_briefing_push.sql`. `BriefingCadence.current = .local`,
so the server path is dark.

**Pinned by** `TestsBriefingReconcile.swift` — `briefing plan: a live context schedules the cadence`.

**Never** hand-roll a notification body or a gate outside the planner; the
catch-up and the cadence pass must both read the same `BriefingContext`.

---

## 6. Device state

**States** every account-scoped key in `DeviceStateKeys.all` (notifications,
live activities, widget snapshot, calendar map, account keys). Present or
absent; there is no third state and no expiry.

**Moves it** `DeviceStateKeys.removeAll(in:)` via `DeviceStateReset.purgeDeviceState()`,
called from `AuthService.signOut()` and after `delete_my_account`.

**Owner** `GamesRoom/Services/DeviceStateKeys.swift` (+ `DeviceStateReset.swift`)

**Server twin** none — it is the device's own residue.

**Pinned by** `TestsDeviceState.swift` — `device state: the registry covers every account-scoped StorageKeys key`.

**Never** add a `StorageKeys` key without adding it to `persistedKeys` /
`devicePreferences`; sign-out must purge everything or the next account
inherits it.

---

## 7. Live Activity / widget

**States** `LiveActivityRule.Action`: `startOrUpdate`, `end`, `none`, from
`action(isLive:hasLine:isRunning:)`. Identity is `roomId`, not the room name.

**Moves it** `AppReconciler` on every foreground pass (and cold launch);
`ScoreLiveActivityDriver` matches, clears and ends by `roomId`. `staleDate` is
`playedAt + autoCloseHours`.

**Owner** `GamesRoom/Models/ScoreSnapshot.swift` (the rule) with
`GamesRoom/Services/ScoreLiveActivityDriver.swift` (the effects)

**Server twin** none.

**Pinned by** `main.swift` — `LiveActivityRule ends when the event is over and it is running`.

**Never** key a Live Activity, widget snapshot or calendar row by room name.

---

## 8. Presentation

**States** one enum per presenter node: `RoomPresentation` (`settings`,
`editEvent`, `addEvent(seed:)`, `withdraw`, `settleScan`, `createRoom`),
`RoomConfirm` (`settleEarly`), `PackEditor` (`casinoConfig`),
`RoomListPresentation` (`settings`, `createRoom`, `joinRoom`, `appSettings`),
`RoomSettingsConfirm` (`declareSeason`, `deleteRoom`, `leaveRoom`),
`QBSheet` (`editing`, `adding`).

**Moves it** presenting is `state = .case(payload)`; dismissing is
`state = nil`. `.confirmationDialog` is a separate slot and keeps its own
binding.

**Owner** `GamesRoom/Models/RoomPresentation.swift`,
`GamesRoom/Models/PresentationEnums.swift`

**Server twin** none.

**Pinned by** `TestsP2.swift` — `P2: a second presentation replaces the first because the id changes`;
`TestsV.swift` — `V D11: RoomSettingsConfirm ids are stable, unique and equal the case names`.

**Never** put two `.sheet` modifiers on one node, and never make an `id`
collide between two cases: `.sheet(item:)` keys on the id and will keep the
old content.

---

## 9. Settle with Undo

**States** `SettlePhase`: `idle`, `undoing(event:)`, `committing(eventId:)`,
`failed(eventId:message:)`. Events: `SettleEvent` — `begin(Event)`, `undo`,
`commitStarted(UUID)`, `commitSucceeded(UUID)`, `commitFailed(UUID, String)`,
applied by `SettlePhase.reduce(_:)`.

**Moves it** `begin` → `undoing` (5 s window, nothing sent); `commitStarted` →
`committing` (toast stays, Undo gone); `commitSucceeded` → `idle`;
`commitFailed` → `failed` (live card shows the retry). A second `begin`
replaces the window (the view cancels the old task); `begin` during
`committing` is ignored.

**Owner** `GamesRoom/Models/SettlePhase.swift`

**Server twin** `settle_event(p_event_id)` in `Supabase/migrations/107_night_lifecycle.sql`.

**Pinned by** `TestsP2.swift` — `P2: settle — the toast stays through committing (D5)`
and `P2: settle — a second settle while undoing cancels the first window`.

**Never** clear the pending settle before the RPC answers, and never offer
Undo once the write is out. "Night settled." means sent.

---

## 10. Writes

**States** `WriteState`: `idle`, `saving`, `saved(at:)`, `failed(Operation, String)`.
`Operation`: `settings`, `displayName`, `shareCode`, `declareSeason`,
`deleteRoom`. `WriteGate` serialises one write per owner and holds exactly one
refire; `SubmitOnce` drops a duplicate submit inside the echo window.

**Moves it** `WriteState.reduce(_ event: WriteEvent)` — `edited`, `begin`,
`succeed(at:)`, `fail`.

**Owner** `GamesRoom/Models/WriteState.swift`

**Server twin** none; each `Operation` names its own RPC.

**Pinned by** `TestsV.swift` — `V: WriteGate — one write at a time, exactly one refire`.

**Never** give one status row two owners: a failure belongs under the control
that caused it.

---

## 11. Scan camera *(left alone on purpose)*

**States** `ScanCameraController.State`: `idle`, `starting`, `running`,
`denied`, `unavailable`.

**Moves it** `start()` (idempotent) → `starting` → `running` / `denied` /
`unavailable`; `stop()` → `idle`. A 5 s capture valve guards the still.

**Owner** `GamesRoom/Views/ScanCameraView.swift`

**Server twin** none.

**Pinned by** nothing — the Foundation runner cannot link AVFoundation, and
this machine was audited and left as it is (it is the best one in the app).

**Never** add a state here without a caller that can leave it.

---

## 12. Night plan *(every night is scored in chips)*

**States** `NightAction`: `claimSeat`, `checkIn`, `takeChips`, `cashOut`,
`waitingForCashOut(names:)`, `settleNight`, `planNextNight`. `MyChips`:
`none`, `playing`, `cashedOut`. `NightPlan` carries `primary`,
`secondaries`, `caption`.

**Moves it** `NightPlan.plan(for: NightInput)` — pure, phase-driven. One
loop for everyone, the host included: I'm here → Take your chips → Cash
out (scan) → done. The host settles once nobody else is still playing;
while anyone is, the host's primary is the wait ("Waiting on Sam to cash
out") and "Settle the night" is the quiet line, behind a confirmation that
names who has not cashed out (`RoomConfirm.settleEarly`).

**Owner** `GamesRoom/Services/NightPlan.swift`

**Server twin** none; its inputs are `get_event_working_hands` and the seat
RPCs. Settling does not forfeit open chips (`settle_event`, `107`); only
`finalize_casino_session` / auto-close (`074`, `080`) does.

**Pinned by** `TestsS1.swift` — `S1.3: settle is never the primary while anyone is still playing`;
`TestsP1.swift` — `P1: a stranded night asks the host to settle it`; sweep
`test_05b_chips_night_waiting_on_a_player`, `test_09_settle_early_asks_first`.

**Never** make "Settle the night" the primary while someone has chips on
the table, and never score a night any way but chips (round scoring, the
CAH count and per-pack payouts were removed on 2026-11-10; their server
RPCs remain because migrations are append-only).

---

## 13. Tonight's board *(a derivation, not a machine)*

**States** `ChipStatus` per player: `noChips`, `playing`,
`cashedOut(net:)`. `TonightScore` adds `leaders`, `headline`,
`progressCaption`.

**Moves it** `TonightScore.tally(hands:transactions:players:names:)` —
pure. "Cashed out" is `WorkingHand.isCashedOut` (scanned, and no chips
taken since); the net is the sum of the player's `casino_settlement` rows,
the same rows the season leaderboard sums.

**Owner** `GamesRoom/Models/TonightScore.swift` (with `NameList` and
`NightWhen`, the "Tonight / Tomorrow / In 3 days" label)

**Server twin** `get_event_working_hands` (`074`) and
`get_event_transactions` (`106`).

**Pinned by** `TestsTonight.swift` — `Tonight: the net is the server's settlement rows, cashed out first, highest first`.

**Never** compute "cashed out" or a player's night net anywhere else, and
never show the season total under the "Tonight" title.

---

## 14. Question Box pacing and reader *(1.2.5)*

**States** `QuestionDepth`: `light`, `deep`. Per night the depth runs
`light` (opener) → `light` … → one `deep` → `light` for the rest of the night.

**Moves it** `QuestionBoxPacing.depth(isOpener:turnsServed:deepServedTonight:playedAt:now:)`
— the opener is light; once per night, when 3 turns have been served (opener
and interval; passes do not count) or 60 minutes have passed since
`played_at`, whichever comes first, the next question is deep. The reader of an
interval turn is `QuestionBoxReaderPick.pick(...)`: never the last reader; then
fewest turns tonight, fewest nights attended in this room, rotation order from
the cursor.

**Owner** `GamesRoom/Models/QuestionBox.swift`

**Server twin** `public.question_box_advance` in
`Supabase/migrations/118_question_box_depth.sql` (with
`question_box_draw(room, event, depth)`, `question_box_nights_attended` and
`events.question_deep_at`, the once-per-night marker).

**Pinned by** `TestsQuestionDepth.swift` — `Question depth: a whole night has exactly one deeper question, never before turn 4 or 60 min`
and `Question depth: the reader pick favours newer members and never repeats`.

**Never** put the word "deep" or "level" on screen (the host's add sheet says
"Deeper", nothing else does), count or show nights attended to anyone, or
serve a deep question from anywhere but `question_box_advance`.

---

## Left alone on purpose

Copied from `~/gr-work/2026-11-09-state-machines/00-DECISION.md`:

- ScanCameraController.State
- ArrivalGrace
- the auto-return-on-settle trigger
- the 60-minute Question Box quiet rule
- the 12-hour member-note cool-down
- deposit escrow semantics on settle
- 114's night_started refusal
- the autosave serializer (wrapped, not redesigned)
- the seed-vs-edit guards
- view ephemera such as `packsExpanded` and `justClaimed`

## Known gaps on this branch

- `SettlePhase.failed` is scoped to a night id, but the live card is the only
  surface that renders it; a member never sees a settle failure (they cannot
  settle).
- `RoomPresentation.callSheet` does not exist: the Tonight's Star call sheet is
  presented from `CeremonialCard`, which is its own node with one `.sheet`.
- `Operation.packPayout` is not in `Operation` yet; the pack payout sheet's
  write lives in `RoomDetailView` and still reports through its own alert.
