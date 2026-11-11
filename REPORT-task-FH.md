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

Status: steps 1-2 complete. The F2 contract suite pins the fake's behaviour;
the F3 RLS probes and the F4 recommendation land in later commits.

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

## 5. Suggested fixes (input to F4)

- (a) Make `upsertEventRSVP` call `adjustBriefingSeats(previous:state:)` so the
  fake is idempotent like the RPC, or delete the briefing mutation and let
  `RoomService.refreshSeatCaches` be the only live/fake difference.
- (b) Either add the member gate to the fake, or document the fake as
  guard-free by design.
- (c) Correct the two comments: there is no client-side drowning filter. Then
  decide (F4) whether one should exist.
- (d) Either give the fake a set of seasons and apply the same ordering, or
  document that the fake cannot represent the transition window.
