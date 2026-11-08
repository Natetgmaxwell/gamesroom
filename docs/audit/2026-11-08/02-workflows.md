# 02 — Workflows audit (common-sense pass)

Repo: macstudio `~/Projects/games-room` @ `febbae3` (1.2.3 b27). Read-only; source exported via `git archive febbae3`.
Server claims are from the repo's migration chain. The live DB was not checked (out of scope), so each server claim says "per migrations".

---

## Findings

### 1. The room page can't show a night once it has started (per migrations)
- **Severity:** High
- **Where:** `Supabase/migrations/092_multipack_events.sql:95-127` (current body, wrapped as `get_active_event__inner` by `106_room_rpc_member_guards.sql`); consumer `GamesRoom/Services/RoomStore.swift:400`, `GamesRoom/Views/RoomDetailView.swift:731-762`
- **What happens now:** 092 redefined the RPC with the filter that 063 had removed as a bug:
  ```sql
  where e.room_id = p_room_id
    and e.played_at > now()
  order by e.played_at asc
  ```
  063's header says why that filter is wrong: *"The old filter `played_at > now()` meant an event that had started … disappeared from the room page entirely — no live state, no withdraw CTA, no witness screen."* 092 says it only meant to "add pack_slugs to the return shape". It also dropped 090's `not (current_user_id() = any(e.hidden_from_user_ids))` filter and 087's `event_calendar_identifier` column. No later migration redefines the inner function.
- **Why it's wrong:** At 7:30pm, when the night starts, `activeEvent` becomes nil and the state machine falls to `.readStandings`. Withdraw chips, scan, Score a round, the Question Box live section, the ArrivalCard and HostWithdrawals all key off `activeEvent` with `playedAt <= Date()`, so the whole in-night half of the app goes dark at the moment it's needed. Hidden members can also see events they were hidden from.
- **Proposed fix:** New migration that restores 090's body and adds `pack_slugs`: `settled_at is null`, the hidden-members filter, and the calendar id. See #3 for ordering. Add a SQL test: an event with `played_at = now() - 1h` and `settled_at null` must be returned. First run `select pg_get_functiondef('public.get_active_event__inner'::regproc)` on live to confirm (read-only).
- **Effort:** S

### 2. No one can settle the night: there is no Settle or finalize action, and `.settleRound` can't be reached
- **Severity:** High
- **Where:** `RoomDetailView.swift:739` (`if isLive && event.hostFinalized { return .settleRound(event) }`); `Event.swift:74,178`; no client RPC
- **What happens now:** None of the ~90 RPCs the client calls starts, finalizes or settles an event (checked with grep over `rpc("…")`). `host_finalized` doesn't appear anywhere under `Supabase/` and `get_active_event` doesn't return it, so it always decodes to `false` (`?? false`). The only thing that writes `events.settled_at` is `auto_close_stale_events` (081), fired lazily from `RoomService.loadActiveEvent` once `played_at < now() - auto_close_hours` (default 8h).
- **Why it's wrong:** Nathan's rubric says the primary button follows the night: Claim seat → Score → **Settle**. In the shipped app the night has no end the host controls. It ends silently 8h after the *start* time, on whichever member's device next opens the room. Nothing marks the moment, and the host can't close out at 11pm while everyone is still at the table.
- **Proposed fix:** Add a host-only `settle_event(p_event_id)` RPC that sets `settled_at = now()`, closes attestations and returns deposits. Show a full-width **Settle the night** primary in the host's WitnessSlot when the event is live and at least one score, scan or withdrawal exists. Before that, Score/Withdraw stays primary. Use optimistic UI with a 5s Undo toast (Undo clears `settled_at` inside the window), then a success haptic and the ceremonial card. Delete `hostFinalized` and `.settleRound` or wire them to this, not both.
- **Effort:** M

### 3. The post-night recap (ceremonial card, Tonight's Star, notes for next time) never shows on the room page
- **Severity:** High
- **Where:** `RoomDetailView.swift:734-737` (`.justSettled` needs `event.settledAt != nil`); RPC filters `settled_at is null` (063/087/090) or `played_at > now()` (092)
- **What happens now:** `.justSettled` needs `activeEvent.settledAt` set within the last 24h. No version of `get_active_event` since 063 can return a settled event: 063–090 filter `settled_at is null`, and 092 only returns future events, which can't be settled.
- **Why it's wrong:** This removes the completion moment for the night: `CeremonialCard`, the host's Tonight's Star pick (`setTonightStarPick`) and the member "note for next time" (`submitMemberNote`). The host's `UnconsumedMemberNotesSection` then has no input. The relationship-building half of the product doesn't run.
- **Proposed fix:** In the #1 migration, return in priority order: (a) an unsettled event with `played_at <= now()` (live), else (b) an event settled in the last 24h, else (c) the next future event. Add `next_event_id` so the host can pre-schedule next week without hiding tonight. 063's `order by played_at desc` already lets a newly scheduled future night replace a live one.
- **Effort:** S (bundled with #1)

### 4. Deposit rooms: the "I'm here" check-in button can never appear
- **Severity:** High
- **Where:** `RoomDetailView.swift:2032-2036` (button gate); `:756-760` (BriefingSlot renders only in pre-play states)
- **What happens now:** The reclaim button needs the night to have started:
  ```swift
  if let deposit = heldDeposit, deposit.status == .held,
     room.seatDepositTrigger == .escrow,
     event.playedAt <= Date(),        // started
     let onCheckIn {
  ```
  But `BriefingSlot` only renders for `.upcoming/.claimed/.declined`, and the state machine reaches those only when `playedAt > now`. Once `playedAt <= now` the page switches to `WitnessSlot`, which has no check-in parameter.
- **Why it's wrong:** The escrow is designed as "claim → deposit leaves balance; arrive → 'I'm here' returns it" (085 header). The member's half can't be done, so a deposit comes back only through a play transaction or the host's ArrivalCard. Someone who turns up but doesn't withdraw chips (a CAH-only night, a spectator, the host's partner) is listed to the host as a no-show to forfeit.
- **Proposed fix:** Put the check-in on `WitnessSlot` in `.tonightEvent` as the primary when a held deposit exists: "I'm here · reclaim 200 CC". Withdraw drops to secondary until the member has checked in or played. Better still, return the deposit automatically on the first withdraw, scan or CAH tally (the 085 trigger already does this for play kinds) and drop the extra tap.
- **Effort:** S

### 5. Deposit rooms: Release/Can't make it keeps the deposit, and re-claiming silently does nothing
- **Severity:** High
- **Where:** `RoomDetailView.swift:1538-1549` (`releaseSeat` → `upsertEventRSVP(.unclaimed)`), `:1504` (decline); `RoomService.swift:1995-2005`; `085_seat_deposit_escrow.sql` `claim_seat_with_deposit` idempotency guard; `106_room_rpc_member_guards.sql:187-226` (`upsert_event_rsvp`), `:266-280` (`list_arrival_candidates`)
- **What happens now:**
  1. Release and decline go through `upsert_event_rsvp`, which only writes `event_rsvps.state`. It never touches `seat_deposits`, so the deposit stays `held`.
  2. `list_arrival_candidates` picks every `held` deposit with no play transaction and doesn't check the RSVP, so a member who released politely two days early shows up on the host's ArrivalCard with **Forfeit** as an option.
  3. Re-claiming calls `claim_seat_with_deposit`, which returns early *before* its RSVP upsert:
     ```sql
     if exists (select 1 from public.seat_deposits
                where event_id = p_event_id and user_id = v_caller) then
       return true;
     end if;
     ```
     The RSVP stays `unclaimed` on the server. The client shows "You're in." optimistically (`applyOptimisticRSVP`) with a success haptic. The escrow branch never reloads RSVPs, so the next refresh quietly puts the member back to unclaimed.
- **Why it's wrong:** Releasing a seat is the considerate thing to do, and here it gets a member fined. The "change your mind" path tells them they're in when they aren't.
- **Proposed fix:** Add a `release_seat(p_event_id, p_state)` RPC that sets the RSVP and, if a deposit is `held`, marks it `returned` and credits the balance, in one transaction. Route decline and release in escrow rooms through it. In `claim_seat_with_deposit`, have the idempotency guard check `status = 'held'` and still upsert the RSVP. Filter `list_arrival_candidates` to `rsvp.state = 'claimed'`. Then make Release instant with a 5s Undo toast instead of the current silent flip.
- **Effort:** M

### 6. A full night still offers "Claim seat", and the extra claimant doesn't appear in the grid
- **Severity:** Med
- **Where:** `RoomDetailView.swift:1962-1973` (no capacity check); `Models/EventRSVP.swift:47-53` (`Array(claimed.prefix(clampedMax))`); neither `upsert_event_rsvp` (106) nor `claim_seat_with_deposit` (085) reads `max_seats`
- **What happens now:** `.unclaimed` always renders the full-width **Claim seat**. The server accepts any number of claims. The grid clamps to `maxSeats`, so the 9th claimant on an 8-seat night is told "You're in." but has no chair, and the host can't see them in the grid.
- **Why it's wrong:** A table has a fixed number of chairs. If the app says you're in when you aren't on the grid, someone turns up to a full table.
- **Proposed fix:** Enforce capacity on the server (`count(claimed) >= max_seats` → raise `P0001 'Night is full'`). On the client, when `briefing.seatsUnclaimed == 0`, swap the primary to grey copy, "All N seats are taken. The host can add one.", with a "Tell me if one opens" secondary. Optionally add an overflow row to the grid for the host.
- **Effort:** S–M

### 7. "Score a round" always opens on Round 1, so scoring the second round overwrites the first
- **Severity:** High
- **Where:** `HostScoreEntrySheet.swift:64` (`@State private var roundIndex: Int = 1`), `:111-115`; server `095_role_based_host_guards.sql` `record_round_score` (`on conflict (room_id, event_id, round_index) do update` and `delete from public.transactions … round_index = p_round_index`)
- **What happens now:** The sheet is rebuilt each time it opens (`.sheet(item: $hostScoreEvent)`), so `roundIndex` resets to 1. The server key is `(room_id, event_id, round_index)`, which has no pack in it, and a repeat submit *replaces* the round and reverses its ledger rows.
- **Why it's wrong:** At the table the host taps Score a round → picks the winner → Save, once per game. Unless they remember to step the counter every time, round 2 deletes round 1's points. Nothing on screen says a round was replaced. On a two-game night (Monopoly Deal + CAH), "Round 1" of each game also collides.
- **Proposed fix:** Seed `roundIndex` from `max(cachedEventRounds(eventId).roundIndex) + 1` and show "Round 3 · last: Sam won round 2" so the host sees where they are. Add `pack_slug` to the unique key, or make round_index per-pack. Make correcting a past round an explicit action: tap a row in `RoundBreakdownSection`, then a sheet in correction mode with `p_correction_of`. Never let an overwrite happen by accident.
- **Effort:** S (client seed) + S (migration)

### 8. On multi-pack nights the buttons and sheets follow the "headline pack", not the game being played
- **Severity:** High
- **Where:** `AddEventSheet.swift:95-100,118` ("The last one you tap is the headline pack"); `RoomDetailView.swift:926,992,1044` (`isCAH = event.packSlug == "cards_against_humanity"`), `:996` (`cta: isCAH ? .scan : .withdraw`), `:1720,1736,1756` (`openScan`/`openHostScore` switch on `event.packSlug`), `:281` (`isCasinoPlayActive` uses `event.packSlug == "casino"`), `:464-470` (score sheet gets `event.packSlug`)
- **What happens now:**
  - A Monopoly Deal-only night (no casino) shows **Withdraw to play** as every member's primary in `.tonightEvent` (`cta: isCAH ? .scan : .withdraw`). It opens the casino `WithdrawChipsSheet` for a pack that isn't in play. With no withdrawal the state never leaves `.tonightEvent`.
  - On a Casino + Monopoly Deal night with casino as headline, **Score a round** appears (`eventHasSingleWinnerPack()` is true), but `openHostScore` switches on `event.packSlug` → `.withdrawReturn` → opens **ChipScanSheet**. The host can't score Monopoly Deal on that night.
  - The host's "Chips to dispense" list needs `event.packSlug == "casino"`, so it disappears whenever casino isn't the headline, even though members can withdraw.
- **Why it's wrong:** The host chose packs as a set, and a hidden "last tap wins" rule decides which buttons appear later. The primary action stops matching the game on the table.
- **Proposed fix:** Drop "headline pack". Work out in-night actions from `event.packSlugs`: `withdraw` only if `casino ∈ packSlugs`; `Score a round` opens a game picker when more than one single-winner or count-based pack is selected (or one row per pack in the sheet); `isCasinoPlayActive` uses `packSlugs.contains("casino")`. Pass the chosen slug into `HostScoreEntrySheet`. If no pack has a member action (MD only), the member primary is the check-in (#4) or nothing, with a grey "Host is keeping score tonight."
- **Effort:** M

### 9. The host can't reschedule, rename or cancel a night (the server RPCs exist but nothing calls them)
- **Severity:** High
- **Where:** `EditEventSheet.swift` (fields: Note, Venue only; title "Edit event"); `BriefingSlot` "Edit details" (`RoomDetailView.swift:1928-1939`); server has `public.delete_event` and `public.update_event_played_at`, but no Swift calls either (grep of every `rpc("…")` site)
- **What happens now:** The host's only edit is the note and venue. There's no way to move the date, change packs, rename, or cancel. AddEventSheet doesn't ask for venue or note at all, so every night needs a second trip through "Edit details".
- **Why it's wrong:** Rescheduling and cancelling are routine for a weekly group (someone's sick, a long weekend). Today a wrong date can only be "fixed" by making a second event. Depending on the `get_active_event` ordering, the wrong one keeps the hero card and members keep claiming seats on it.
- **Proposed fix:** EditEventSheet gets Name, When (wired to `update_event_played_at`; tell claimants via the existing dispatcher), Packs, Venue, Note and Seats, plus a red **Cancel this night** at the bottom with a confirmation dialog. That's destructive and it refunds held deposits (via `delete_event` or a new `cancel_event`). Add Venue and Note to AddEventSheet so one sheet sets up the night.
- **Effort:** M

### 10. Members see host-only controls in Room settings (Delete room, Declare season end, seat/deposit steppers, mascot)
- **Severity:** High
- **Where:** `RoomSettingsSheet.swift:321-325` (`hubSections` composes every section with no role gate), `:517-600` (Season + Delete room), `:376-475` (Social/Operations links), `RoomSettingsOperationsSheet` `:916-958` (steppers ungated; only "Show who brought newcomers" is `if isHost` at `:966`); gear is member-visible (`RoomDetailView.swift:367-386`, "The settings sheet self-gates its host-only sections")
- **What happens now:** The file header says "The host-only gate is enforced by the caller", but since V0.79 the caller opens it for everyone. A member who opens the gear to change their notifications sees, all live: **Declare season end**, **Delete room**, Max seats, Starting bonus, Auto-close, Seat deposit amount/trigger/grace, mascot name/personality. Edits go through autosave (`bumpDraft` → `writeAll`). The server rejects them, so the member sees a red autosave failure line.
- **Why it's wrong:** A member's whole job in settings is notifications and calendar. Instead they see dangerous host controls that look as if they'll work and then error. It also makes the member's real controls hard to find.
- **Proposed fix:** Branch the hub at the top: `if room.userRole == .host { full hub } else { My notifications, My calendar, Members (read-only), Pack store (read-only), Leave room }`. Wrap `statusAndSeasonSections` and the Operations/Social links in `if isHost`. Add a UI test that opens settings as a member and asserts "Delete room" doesn't exist.
- **Effort:** S

### 11. Nobody can leave a room
- **Severity:** High
- **Where:** `RoomSettingsSheet.swift:1201-1208` (host-only copy: "To leave the room, ask another host to demote you."); member branch renders no leave action; server has `public.leave_room` but no Swift calls it
- **What happens now:** A member has no Leave button anywhere: room page, settings, Members, Rooms list (no swipe or context menu, `RoomPage.swift:466-516`). A host is told to get demoted first. After that they're a member, who has no Leave action either. The only way out of a room is **Delete account** (`delete_my_account`).
- **Why it's wrong:** People move away and friend groups split. A room you can't leave keeps pushing reminders, so the user turns notifications off for the whole app or deletes it.
- **Proposed fix:** Add a red **Leave room** at the bottom of the member settings hub, plus a trailing swipe action and context menu on the Rooms list row. Confirm it (destructive) → `leave_room` → pop to Rooms. For the last host, block with "Make someone else host first" and a button that opens Members with the promote menu ready.
- **Effort:** S

### 12. Members never see the season awards; only the host who closed it does, and only on that device
- **Severity:** Med
- **Where:** `RoomDetailView.swift:108-112` (comment: "`close_season` opens the next season straight away, so without this the page would skip the awards card"), `:725-730`, `:393-399`
- **What happens now:** `.seasonClose` renders if `justClosedSeason` is set (a local `@State`, set only in the host's `onSeasonClosed` callback) or if `currentSeason.status == .ended`, which never holds because the server opens the next season immediately. On every member's phone the season ends silently. A `SystemBanner` row may say "season closed", but the AwardsCard, stat-card share and Drowning opt-in don't appear. The host loses the card too once they leave the view (`@State`).
- **Why it's wrong:** Season close is the biggest completion moment the app has, and the rubric asks for it explicitly. It currently happens only for the person who pressed the button, and they already know.
- **Proposed fix:** Find "just closed" on the server: show `.seasonClose` for the most recent ended season while `ended_at > now() - 7d` and the member hasn't dismissed it (dismissal stored per user). Give the AwardsCard a "Done" secondary that drops back to standings, and keep the next night's Claim seat reachable below it (see #13).
- **Effort:** M

### 13. Season-close state takes over the room page and hides Claim seat for the next night
- **Severity:** Med
- **Where:** `RoomDetailView.swift:720-730` ("season-close takes priority over active-event branches")
- **What happens now:** While `.seasonClose` holds, `activeSlot` renders only `AwardsCard`. A scheduled next night (`.upcoming`) can't be reached, so there's no Claim seat. For the host it lasts until they create an event (`justClosedSeason = nil` in `AddEventSheet.onSaved`). If the host scheduled next week *before* closing the season, the claim CTA is hidden until they leave the page.
- **Why it's wrong:** One primary per screen should be whatever the user can do next. Awards are something to look at; claiming a seat is something to do.
- **Proposed fix:** Render awards *above* the briefing as a dismissible section, not as a replacement state. Or keep `.seasonClose` only when `activeEvent == nil`.
- **Effort:** S

### 14. Forfeiting a deposit is the filled primary button, has no confirm or undo, and is offered inside the grace window
- **Severity:** Med
- **Where:** `ArrivalCard.swift:85-100` (Forfeit = accent-filled, one tap → `onForfeit`); `RoomDetailView.swift:1452-1476`; `SeatDepositCandidate.withinGrace` is decoded (`SeatDeposit.swift:135`) but no view reads it
- **What happens now:** The row offers `Forfeit` (filled), `Skip: texted`, `Skip: away`. One tap on Forfeit burns the member's deposit on the server, with a light haptic and no Undo. It's shown even while `within_grace` is true, i.e. two minutes after start time while the member is parking.
- **Why it's wrong:** The rubric says confirm destructive actions, and taking a friend's points is destructive. Making it the visually dominant choice at 7:32pm, while the host is setting up the table, leads to mis-taps and arguments.
- **Proposed fix:** Hide the ArrivalCard until `withinGrace == false`, and show a grey "Arrivals open at 7:40" before then. Make "Return deposit" the default and Forfeit a red text action that needs a confirmation dialog ("Keep Sam's 200 CC?"). Also give a 10s Undo toast. Merge "Skip: texted" and "Skip: away" into one "Give it back" with an optional reason, since both do the same thing (`waiveSeatDeposit`).
- **Effort:** S

### 15. A new room's first step is "Add an event" in an empty room; inviting is buried in a collapsed section and takes three taps
- **Severity:** Med
- **Where:** `RoomDetailView.swift:1135-1154` (`.readStandings` host hero = "No nights on the books yet" + **Add an event**); `:668` + `:4346-4399` (`MembersSection`, collapsed by default, at the very bottom of the page after Standings, Seasons, Packs); `:4038-4053` (code row: Share icon + a **`plusCircle`** icon whose action is *copy*); `CreateRoomSheet.swift:173-181` and `JoinRoomSheet.swift:120-130` (`_ = try await …; dismiss()`, no navigation)
- **What happens now:** Create room → the sheet dismisses back to the **Rooms list** (no push), so the host taps the new room again. There the hero says "Add an event". To invite, they scroll to the bottom, find "Members", tap the small `+` (expands the section and mints a code), then tap Share. The copy button's icon is a plus. JoinRoomSheet's footer says "Ask the host for the six-character code from their Room Settings", which is the older location. There's no join link or deep link (no `onOpenURL` in the target), so a friend has to type the code.
- **Why it's wrong:** A night with nobody invited has nobody to claim seats. For a new host, the obvious next step is getting the friends in. For a joiner, it's landing in the room they just joined.
- **Proposed fix:** After create or join, push straight into the room (`roomsPath = [room]` / `selectedRoom = room`). Host hero in a room with fewer than 2 members: primary **Invite friends** (opens the share sheet with the code in one tap), secondary grey "Add an event". Change the copy icon to `doc.on.doc`. Fix the JoinRoomSheet footer. Later: a `gamesroom://join/CODE` universal link inside the share text.
- **Effort:** S (M with universal links)

### 16. First launch makes "Create your own room" primary, though most new users arrive with an invite
- **Severity:** Med
- **Where:** `RoomPage.swift:652-718`
- **What happens now:** The empty state's filled primary is **Create your own room** (or "Create one to get started"). Joining is an outlined secondary labelled "Ask a friend for a join code", which describes asking rather than entering. The subhead logic keys off `isKnownHost`, which a first-time user can't be.
- **Why it's wrong:** The product grows by invitation ("the app brings the people to the table"). Most first-launchers have a code in a text message. With the primary on Create they'll make a throwaway room, and stray empty rooms are what the "never empty" rule is meant to prevent.
- **Proposed fix:** Primary **Enter a join code**. Paste-detect a six-character code from `UIPasteboard` (with `detectPatterns`) and pre-fill the field. Secondary grey text: "Starting your own games night? Create a room".
- **Effort:** S

### 17. The Rooms list says "Live now" for any scheduled night (even three weeks out), and shows a literal `\(name)`
- **Severity:** Low
- **Where:** `RoomPage.swift:602-608` (`hasActiveEvent ? "Live now" : "Last opened"`, keyed on `activeEventByRoom[room.id] != nil`), `:475-480` (same dot means "Active session"); `:557,559` (`"Shared with \\(name) in another room"`, `"\\(room.overlapCount) shared …"`, an escaped backslash, so the string prints `\(name)` as written)
- **What happens now:** `get_active_event` returns the next *future* event (092, default 21 days ahead per `AddEventSheet.defaultPlayedAt`), so most rooms show "Live now" and the accent dot all the time. The overlap line prints the interpolation as source text. The "Continue / Resume" hero also duplicates the row right under it (two targets for the same room).
- **Why it's wrong:** "Live now" is the signal for "go to the table". When it's always on, it means nothing. The overlap bug puts a code fragment in front of every user who shares a room with someone.
- **Proposed fix:** Only call it live when `playedAt <= now && settledAt == nil`. Otherwise caption "Fri 7:30pm · 5 of 8 seats". Remove the doubled backslashes. Drop the Resume hero when there's only one room. With several, replace it with tonight's room pinned first.
- **Effort:** S

### 18. The notification opt-in only appears when nothing is scheduled, so members who join for an upcoming night never get it
- **Severity:** Med
- **Where:** `RoomDetailView.swift:603-630` (`if activeEvent == nil, … RoomNotifPromptCard`); comment says "'schedules a night' is the moment"
- **What happens now:** The one-time prompt needs `activeEvent == nil`. Members are usually invited *because* a night is coming up, so that's when they first open the room, and the prompt is hidden. Notifications are quiet by default (066). The member gets no T-48h or day-of reminder for their first night unless they find Room settings → My notifications.
- **Why it's wrong:** The first night is the one most likely to be missed, and it's the one where the reminder is suppressed. The gate is the opposite of what the comment says it intends.
- **Proposed fix:** Show the opt-in *after a successful claim* as the one secondary under "You're in." ("Remind me the day before"), the same way the calendar ask already works (`:631-638`). Drop the `activeEvent == nil` gate.
- **Effort:** S

### 19. Up to four stacked accent buttons in the night card; "Score a round" shows before anyone has arrived
- **Severity:** Low
- **Where:** `RoomDetailView.swift:2602-2680` (primary + `Withdraw more` + `Count your CAH cards` + `Score a round`, all accent-outlined), `:1002-1004` (host `onScore` already in `.tonightEvent`)
- **What happens now:** A host on a Casino + CAH + Monopoly Deal night sees four tinted buttons at once. `Score a round` appears the moment start time passes, before any arrival or withdrawal.
- **Why it's wrong:** The rubric asks for one primary, with secondaries as plain grey text, and for the primary to follow the night. Here the host has to read four buttons to find theirs.
- **Proposed fix:** Host primary follows the night: before anyone is in, "Waiting for the table · 3 of 6 here". Once arrivals exist, **Score a round**. Once a round is scored, **Settle the night** (see #2). Member primary: withdraw/scan for casino, else check-in. Other actions become `TrailingTextAction` grey text.
- **Effort:** S

### 20. Seat-change reminders are scheduled using the caller's own RSVP for every member
- **Severity:** Low (UNVERIFIED impact: depends on whether `scheduleBriefingTrio` fires per member locally)
- **Where:** `RoomService.swift:856-858`
- **What happens now:**
  ```swift
  var cadence = roster.reduce(into: [UUID: MemberRSVPState]()) { acc, member in
      acc[member.userId] = rsvpByEvent[event.id] ?? .unclaimed   // caller's state, for everyone
  }
  ```
- **Why it's wrong:** After I decline, the dispatcher treats everyone as declined (and the reverse after a claim). If the trio is used for anything beyond the caller's own reminders, cadence is wrong for the room.
- **Proposed fix:** Build the cadence from `cachedEventRSVPs(eventId:)`, mapping each `memberId → state`.
- **Effort:** S

---

## Journey map: where each path ends (code path → verdict)

| Journey | Code path | Verdict |
|---|---|---|
| First launch / sign in | `ContentView` sheet `signInBinding` → `RoomPage.emptyState` | Works; primary is wrong (#16) |
| Create room | `CreateRoomSheet.save` → dismiss | Lands on list, not in the room (#15) |
| Invite / join | `MembersSection.invite` → ShareLink; `JoinRoomSheet.redeemJoinCode` | Buried, three taps, no deep link (#15) |
| New member first screen | `.upcoming` → BriefingSlot "Claim seat" | Good, one tap; notif opt-in suppressed (#18) |
| Create event | `AddEventSheet` (name, packs, date; default +21d 19:00) | No venue/note/seats; hidden headline-pack rule (#8, #9) |
| Edit / reschedule / cancel | `EditEventSheet` (note, venue only) | Can't reschedule or cancel (#9) |
| Claim / decline / release | `claimSeat`/`declineSeat`/`releaseSeat` | Optimistic + haptic ✓; no capacity (#6); deposit rooms broken (#4, #5) |
| Night: start / arrival | `get_active_event` → `.tonightEvent` | Unreachable per migrations (#1); check-in unreachable (#4) |
| Withdraw / scan / CAH | `WithdrawChipsSheet`, `ChipScanSheet`, `CAHCardScanSheet` | Routed by headline pack (#8) |
| Score entry | `HostScoreEntrySheet` | Round resets to 1 and overwrites (#7) |
| Settle / cash-out | none; `auto_close_stale_events` after N h | No action (#2) |
| Recap / Tonight's Star / notes | `.justSettled` → `CeremonialCard` | Unreachable (#3) |
| Season close | Settings → Declare → `justClosedSeason` | Host-only, one device (#12, #13) |
| Room settings / notifs / calendar | `RoomSettingsSheet` | Host controls shown to members (#10) |
| Leave room | none (`leave_room` unwired) | Dead end (#11) |
| Multi-host | Members ⋯ → Make host / Demote (confirm alert) | OK; last-host leave dead end (#11) |

## Ranked top 5

1. **#1 + #3: fix `get_active_event`** (one migration). Restores the whole in-night and recap half of the app. Effort S, highest value. Confirm the live function body first (read-only `pg_get_functiondef`).
2. **#2: add a host "Settle the night"** with Undo. The night currently has no host-controlled end. M.
3. **#7: score sheet round index** (seed the next round, make pack part of the key). Without it, scores are silently lost from round 2 on. S.
4. **#4 + #5: deposit escrow** (check-in on the night card, refund on release, re-claim really claims, arrival list filters by RSVP). Stops members being fined for releasing a seat. M.
5. **#10 + #11: settings by role, plus Leave room.** Members stop seeing Delete/Declare and can finally leave. S.

Then: #8 (multi-pack routing), #9 (reschedule/cancel), #15/#16 (first-run path).
