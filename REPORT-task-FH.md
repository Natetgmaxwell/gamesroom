---
type: report
title: Task F+H - store contract (InMemory vs Live) and the server boundary
created: 2026-11-11
tags:
  - store-contract
  - in-memory
  - rls
  - divergence
related:
  - '[[STATE-cc-fh]]'
---

# Task F+H - pinning the store contract

Branch: `cc/store-contract`, cut from `7e7bf4b`. This report pins CURRENT
behaviour. It changes no store behaviour and deletes no filter.

Status: all four steps complete. F1 inventory (above), F2 contract suite
(`TestsStoreContract.swift`), F3 RLS probes
(`Supabase/probes/contract-rls-probes.sql`), F4 final table and recommendation
(below). The probes are **written but unexecuted** — this worktree has no psql
or local Postgres and the brief forbids touching the live DB.

## 1. Function inventory

Both stores were reduced to `func` names. They share **68** public contract
names. The in-memory store carries 22 private/seed helpers that the live store
does not (`adjustBriefingSeats`, `autoCloseHours`, `backdateSettledAt`,
`currentSyntheticMemberId`, `eventById`, `history`, `phase`, `qbCurrentMemberId`,
`rebuildCarwoolaEvent`, `replacingEvent`, `resolveDeposit`, `roomById`,
`roomIdForEvent`, `screenshotStateArg`, `seedEventRound`, `seedExtraMember`,
`seedForKick`, `seedGrid`, `seedHeldDeposit`, `seedInvite`, `syntheticRoster`,
`upsertEvent`). The live store carries one private helper the fake lacks,
`parsePostgresTimestamp`.

Shared names (both sides):

```
fetchRooms, createRoom, generateJoinCode, generateInviteCode, approveTierTwoJoin,
redeemJoinCode, fetchMyInviteRewards, fetchRoomMembers, setMemberTeam,
transferHostRole, kickMember, fetchEventRounds, fetchActiveEvent,
fetchRecentSettledEvent, autoCloseStaleEvents, settleEvent, fetchBriefing,
fetchLeaderboard, fetchCurrentSeason, fetchSeasonAwards, closeSeason,
fetchSeasonHistory, fetchSeasonGrid, fetchRoomPacks, updateRoomPacks,
fetchShowBroughtBy, setShowBroughtBy, fetchAnchorPushEnabled,
setAnchorPushEnabled, fetchRoomSystemEvents, acknowledgeSystemEvent,
setDrowningOptIn, setNotificationsEnabled, setEventNotificationsMuted,
fetchEventRSVPs, fetchRoomPackConfigs, setRoomPackConfig, fetchCasinoConfig,
updateCasinoConfig, fetchCurrentMemberRSVP, upsertEventRSVP, addEvent,
updateEventName, updateEventPlayedAt, cancelEvent, updateEventMemberFields,
writeChapterLine, fetchEventChapterLine, setSeasonSubtitle, deleteRoom,
leaveRoom, updateRoom, setMemberCalendarAutoAdd, reportCalendarIdentifier,
updateHostJournal, claimSeatWithDeposit, releaseSeat, claimSeatWaived,
checkInSeat, loadArrivalCandidates, forfeitSeatDeposit, waiveSeatDeposit,
fetchMySeatDeposit, fetchTonightStarCard, setTonightStarPick,
fetchUnconsumedMemberNotes, submitMemberNote, markMemberNotesConsumed
```

## 2. Known suspects - both sides

### (a) RSVP upsert -> briefing mirror

| side | behaviour | file:line |
| --- | --- | --- |
| In-memory | Writes `rsvps[eventId][currentSyntheticMemberId()]`. If a briefing exists, applies a **state-only** delta: `.claimed` does `seatsClaimed + 1`, `seatsUnclaimed - 1`; `.declined` does `seatsDeclined + 1`, `seatsUnclaimed - 1`; `.unclaimed` does `seatsClaimed - 1`, `seatsUnclaimed + 1`. It never reads the member's **previous** state, so a repeated `.claimed` counts the seat again, and `.unclaimed` after `.declined` decrements `seatsClaimed` (not `seatsDeclined`). | `GamesRoom/Services/InMemoryRoomStore.swift:1641` (delta block 1649-1680) |
| Live | Calls `upsert_event_rsvp(p_event_id, p_state)`. The doc states it is idempotent: same state is a no-op, a different state overwrites in place. It constructs a throwaway `MemberRSVP` and does **not** touch any briefing row. `RoomService.upsertEventRSVP` compensates by invalidating the caches and calling `refreshSeatCaches` (re-fetch RSVPs + briefing) after every write. | `GamesRoom/Services/RoomStore.swift:823`; cache refresh `GamesRoom/Services/RoomService.swift:952-978` |
| Comment | "`InMemoryRoomStore` mirrors the briefing on upsert but `LiveRoomStore` does not — without these reloads the live path would stay stale." | `GamesRoom/Services/RoomService.swift:969-971` |

Note the in-memory store has a correct previous-state-aware helper,
`adjustBriefingSeats` (`InMemoryRoomStore.swift:2139`), but `upsertEventRSVP`
does not use it - `releaseSeat` does. That is the drift the comment is pointing
at.

### (b) auto_close mirror

| side | behaviour | file:line |
| --- | --- | --- |
| In-memory | Window = `rooms.autoCloseHours` or `NightPhaseResolver.defaultAutoCloseHours`. Stamps `settledAt = now` on every event in the room with `settledAt == nil && playedAt < now - windowMinutes`; returns the count. No auth/membership gate, no host gate, no idempotence guard beyond `settledAt == nil`. | `GamesRoom/Services/InMemoryRoomStore.swift:1091` (hours) and `:1101` (sweep) |
| Live | RPC `auto_close_stale_events(p_room_id)`. Raises 42501 when unauthenticated or when the caller is not a member. Updates `events` joined to `rooms` where `played_at < now() - make_interval(hours => r.auto_close_hours)`, `settled_at is null`; returns `row_count`. Running it twice closes 0 the second time (already settled). | `GamesRoom/Services/RoomStore.swift:429`; SQL `Supabase/migrations/081_auto_close_hours.sql:37-79` (originally `080_auto_close_stale_events.sql:37`) |

Divergences: the fake skips both server guards; the fake defaults to
`NightPhaseResolver.defaultAutoCloseHours` while the SQL column defaults to 8;
the fake has no membership check so a non-member can close a room's nights in
previews.

### (c) drowning-rows filter

| side | behaviour | file:line |
| --- | --- | --- |
| In-memory | `fetchSeasonAwards` returns `seasonAwards[seasonId] ?? []` verbatim. The seed contains a `.drowning` row whose recipient is **not** the current synthetic member (the Carwoola host), so previews can render it. No filtering at all. | `GamesRoom/Services/InMemoryRoomStore.swift:1344`; seed `:474-505` |
| Live | `fetchSeasonAwards` also returns the decoded rows verbatim. **There is no Swift-side drowning filter on this branch.** The server RPC is the only filter: it returns drowning rows only to the recipient, the room host, or an opted-in member. | `GamesRoom/Services/RoomStore.swift:536-546`; RPC `Supabase/migrations/048_season_close_and_read_rpcs.sql:56-98` (read set from `045_drowning_season_award_policy.sql`) |
| Comment | Both the protocol (`RoomStoreProtocol.swift:351-355`) and the live doc (`RoomStore.swift:532-535`) claim the Swift layer "defensively filters" / "additionally filters" drowning rows for other users. **The code does not.** This is a documentation/behaviour divergence, not a double filter. | `GamesRoom/Services/RoomStoreProtocol.swift:351`; `GamesRoom/Services/RoomStore.swift:532` |

### (d) ended-over-active season preference

| side | behaviour | file:line |
| --- | --- | --- |
| In-memory | `fetchCurrentSeason` returns the single stored `currentSeasons[roomId]`. The map holds exactly **one** season per room, so an "active + ended simultaneously" state cannot be represented; the fake returns whatever was last written. | `GamesRoom/Services/InMemoryRoomStore.swift:1340`; storage seed `:429-465` |
| Live | RPC `get_current_season(p_room_id)` orders `case when status = 'ended' then 0 else 1 end, ordinal desc limit 1`, i.e. prefers `ended` over `active` when both exist, and returns nothing for non-members. | `GamesRoom/Services/RoomStore.swift:521-531`; SQL `Supabase/migrations/048_season_close_and_read_rpcs.sql:28-48` |
| Comment | "preferring `status='ended'` over `status='active'` if both exist (a defensive fallback for the season-close transition window)" | `GamesRoom/Services/RoomStoreProtocol.swift:344-348` |

## 3. Other divergences found while inventorying

| # | function | in-memory | live | file:line both sides |
| --- | --- | --- | --- | --- |
| e | `fetchCurrentMemberRSVP` | Always `.unclaimed` ("no notion of current user") | RPC `get_my_event_rsvp`, real state | `InMemoryRoomStore.swift:1624`, `RoomStore.swift:806` |
| f | `settleEvent` | Stamps `settledAt` unconditionally; no host/night guard | Host-only, refuses not-started / already-settled (42501 / P0001) | `InMemoryRoomStore.swift:1120`, `RoomStore.swift:446` |
| g | `closeSeason` | Closes the active season and opens a fresh one; **does not compute awards** | Computes four awards, resets scores, opens next season, emits system event | `InMemoryRoomStore.swift:1353`, `RoomStore.swift:550`, SQL `048:108+` |
| h | `addEvent` hidden list | Hidden-from list is stored on the event but the in-memory read gates are explicitly skipped ("doesn't replicate the gate") | `get_active_event` / `get_briefing_summary` / `get_event_rsvps` honour `hidden_from_user_ids` | `InMemoryRoomStore.swift:1696-1719`, `RoomStore.swift:856` |
| i | `fetchSeasonHistory` / `fetchSeasonGrid` | Static seeded derivation | RPC `get_season_history` / `get_season_grid` | `InMemoryRoomStore.swift:1389`/`1395`, `RoomStore.swift:573`/`586` |

## 4. Contract suite (F2)

`TestsStoreContract.swift`, registered in `build-and-run-tests.sh` and
`main.swift`, pins the fake's CURRENT behaviour in 19 cases. It changes no
store code. The cases confirm, rather than infer, the inventory above:

- **(a)** A first `.claimed` moves the briefing 1 -> 2 claimed; a **second**
  `.claimed` for the same synthetic member takes it to 3, and a `.unclaimed`
  after a `.declined` decrements `seatsClaimed` while leaving `seatsDeclined`
  standing. The fake is not previous-state-aware, so it is not idempotent like
  `upsert_event_rsvp`.
- **(b)** `autoCloseStaleEvents` closes a stale night in Deal Sundays even
  though the synthetic caller is the Carwoola host (no membership gate); a
  second call closes 0; a night 7h old survives the 8h window.
- **(c)** `fetchSeasonAwards` returns the seeded `.drowning` row whose
  recipient is not the synthetic caller — no client-side filter exists.
- **(d)** `fetchCurrentSeason` returns whatever single season was last written;
  closing a season overwrites that slot, so the closed ended season is no
  longer readable. An ended-only room's `closeSeason` throws.
- **(e)** `fetchCurrentMemberRSVP` is `.unclaimed` even after an upsert.
- **(f)** `settleEvent` stamps a night two days in the future and serves it as
  the recap; no host or not-started guard.
- **(g)** `closeSeason` writes no awards for the season it closes.
- **(h)** `addEvent` stores `hiddenFromUserIds` but the read path returns the
  hidden night anyway.
- **(i)** `fetchSeasonHistory` stays the static `[2, 1]` seed after a close and
  never appends the just-closed season.

## 5. Final divergence table (F4)

One row per divergence. "Right" names the side whose behaviour matches the
contract as designed — the server twin is authoritative unless the server itself
is the drift. Fixes are suggestions; this lane changes no store code.

| Function | In-memory behaviour | Live behaviour | file:line (in-memory / live) | Which side looks right | Suggested fix |
| --- | --- | --- | --- | --- | --- |
| (a) `upsertEventRSVP` -> briefing | Applies a **state-only** delta to the briefing, ignoring the previous RSVP state: a repeated `.claimed` adds a seat again, `.unclaimed` after `.declined` decrements `seatsClaimed`. | Calls `upsert_event_rsvp`, which is idempotent and touches no briefing row; `RoomService` re-fetches RSVPs + briefing via `refreshSeatCaches`. | `InMemoryRoomStore.swift:1641` (delta 1649-1680) / `RoomStore.swift:823`; refresh `RoomService.swift:952-978` | **Live** — idempotence is the stated contract; the fake carries a second copy of a seat rule. | Route the fake through its existing `adjustBriefingSeats(previous:state:)` (`:2139`) so it is previous-state-aware, **or** delete the briefing mutation and let `refreshSeatCaches` be the only difference. |
| (b) `autoCloseStaleEvents` | Sweeps every `settledAt == nil` event in the room older than the window; no auth, membership or host gate; default window from `NightPhaseResolver`. | RPC `auto_close_stale_events` raises 42501 for non-members and closes only that room's stale nights; second run closes 0. | `InMemoryRoomStore.swift:1101` / `RoomStore.swift:429`; SQL `081_auto_close_hours.sql:37-79` | **Live** — the server guards are the contract; the fake is guard-free. | Add the membership gate to the fake, or document it as deliberately guard-free for previews. Align the default window with the column default (8h) either way. |
| (c) `fetchSeasonAwards` | Returns the seeded rows verbatim, including a `.drowning` row addressed to someone else. No filter. | Returns the RPC's rows verbatim. **There is no Swift-side filter**; the server returns drowning rows only to recipient / host / opted-in member. | `InMemoryRoomStore.swift:1344`; seed `:474-505` / `RoomStore.swift:536-546`; RPC `048:56-98`, read set `045` | **Live code** — but the protocol and live doc comments both claim a client filter that does not exist. | Fix the two comments (`RoomStoreProtocol.swift:350-354`, `RoomStore.swift:532-535`); do **not** add a client filter (see §6). |
| (d) `fetchCurrentSeason` | Returns the single stored season for the room; one slot per room, so "active + ended" cannot be represented. | RPC orders `ended` before `active` then `ordinal desc limit 1`; returns nothing for non-members. | `InMemoryRoomStore.swift:1340` / `RoomStore.swift:521-531`; SQL `048:28-48` | **Live** — the ended-over-active preference is the documented transition behaviour. | Give the fake a season set and apply the same ordering, or document that the fake cannot model the transition window. |
| (e) `fetchCurrentMemberRSVP` | Always `.unclaimed`; no notion of a current user. | RPC `get_my_event_rsvp` returns the real state. | `InMemoryRoomStore.swift:1624` / `RoomStore.swift:806` | **Live** | Track a synthetic current member in the fake, or document the gap. |
| (f) `settleEvent` | Stamps `settledAt` unconditionally; no host or not-started guard. | Host-only; refuses not-started and already-settled (42501 / P0001). | `InMemoryRoomStore.swift:1120` / `RoomStore.swift:446` | **Live** | Mirror the two guards in the fake or document the gap. |
| (g) `closeSeason` | Closes the active season and opens a fresh one; computes **no** awards. | Computes four awards, resets scores, opens the next season, emits a system event. | `InMemoryRoomStore.swift:1353` / `RoomStore.swift:550`; SQL `048:108+` | **Live** | Have the fake compute the seeded awards, or document that close is not modelled. |
| (h) `addEvent` hidden list | Stores `hiddenFromUserIds` on the event but the read paths explicitly skip the gate. | `get_active_event` / `get_briefing_summary` / `get_event_rsvps` honour `hidden_from_user_ids`. | `InMemoryRoomStore.swift:1696-1719` / `RoomStore.swift:856` | **Live** | Apply the hidden gate in the fake's read paths. |
| (i) `fetchSeasonHistory` / `fetchSeasonGrid` | Static seeded derivation; a close never appends the just-closed season. | RPCs `get_season_history` / `get_season_grid`. | `InMemoryRoomStore.swift:1389`/`:1395` / `RoomStore.swift:573`/`:586` | **Live** | Derive history from the fake's own season set so it moves when a season closes. |

## 6. Recommendation: the client drowning filter

**Delete the claim, do not implement the filter.** There is no client-side
drowning filter on this branch — `fetchSeasonAwards` returns the RPC's rows
verbatim on both stores — so the "keep vs delete" question is really "implement
or correct the docs". Correct the docs. The server owns the boundary: migration
`045` defines the read set (recipient, host, opted-in member) and `048`'s
`get_season_awards` applies it, and the F3 probes
(`PROBE FH.a.*` in `Supabase/probes/contract-rls-probes.sql`) pin exactly that
behaviour — recipient sees their own row, non-recipient sees none, host and
opted-in members see it, non-members see nothing. Once those probes pass, a
Swift-side filter would do no work in the happy path, would silently paper over
a server regression instead of surfacing it, and would be a second copy of a
privacy rule — which `AGENTS.md` calls a bug even when the copies agree. The F2
test that asserts the fake returns the seeded `.drowning` row is therefore
correct as written: it pins pass-through, which is what the contract should be.
If the boundary is ever found leaking, the fix belongs in the migration, with a
new probe, not in a client filter.
