// deno test Supabase/functions/mascot-voice/
// The voice's decisions, on their own. No network, no database, no env.
//
// Every case here is one of the three defects audit 04-interconnect F5
// found: the voice reading a different event than the face, the season
// eulogy that never ended, and the kicked member who was still the
// leader.

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  activeMemberships,
  isHiddenFrom,
  leaderFacts,
  messageTypeForEvent,
  pickVisibleEvent,
  seasonCloseContext,
  SEASON_CLOSE_WINDOW_MS,
  standingsNoteFor,
  type EventRow,
  type MembershipRow,
  type SeasonRow,
} from "./state.ts";

const MEMBER = "00000000-0000-0000-0000-0000000000a1";
const OTHER = "00000000-0000-0000-0000-0000000000b2";

const NOW = new Date("2026-11-08T09:00:00Z");

function event(over: Partial<EventRow> = {}): EventRow {
  return {
    id: "00000000-0000-0000-0000-0000000000e1",
    room_id: "00000000-0000-0000-0000-0000000000c1",
    name: "Trivia Night",
    played_at: "2026-11-15T09:30:00Z",
    settled_at: null,
    hidden_from_user_ids: [],
    ...over,
  };
}

// ---------------------------------------------------------------------
// (a) The event the voice talks about.
// ---------------------------------------------------------------------

Deno.test("the hidden-from list is read off the event row", () => {
  assert(isHiddenFrom(event({ hidden_from_user_ids: [MEMBER] }), MEMBER));
  assert(isHiddenFrom(event({ hidden_from_user_ids: [OTHER, MEMBER] }), MEMBER));
  assert(!isHiddenFrom(event({ hidden_from_user_ids: [OTHER] }), MEMBER));
  assert(!isHiddenFrom(event({ hidden_from_user_ids: [] }), MEMBER));
  assert(!isHiddenFrom(event({ hidden_from_user_ids: null }), MEMBER));
});

Deno.test("no event id: the next night still to be played, earliest first", () => {
  const later = event({ id: "e2", played_at: "2026-11-22T09:30:00Z" });
  const sooner = event({ id: "e1", played_at: "2026-11-15T09:30:00Z" });
  const picked = pickVisibleEvent([later, sooner], MEMBER, NOW);
  assertEquals(picked?.id, "e1");
});

Deno.test("no event id: a night that has already been played is not the next one", () => {
  const past = event({ id: "e0", played_at: "2026-11-01T09:30:00Z" });
  const next = event({ id: "e1", played_at: "2026-11-15T09:30:00Z" });
  const picked = pickVisibleEvent([past, next], MEMBER, NOW);
  assertEquals(picked?.id, "e1");
});

Deno.test("no event id: a night the caller is hidden from is skipped", () => {
  const hidden = event({
    id: "e1",
    played_at: "2026-11-15T09:30:00Z",
    hidden_from_user_ids: [MEMBER],
  });
  const visible = event({ id: "e2", played_at: "2026-11-22T09:30:00Z" });
  const picked = pickVisibleEvent([hidden, visible], MEMBER, NOW);
  assertEquals(picked?.id, "e2");
});

Deno.test("no event id: every night hidden means no event at all", () => {
  const hidden = event({
    id: "e1",
    played_at: "2026-11-15T09:30:00Z",
    hidden_from_user_ids: [MEMBER],
  });
  assertEquals(pickVisibleEvent([hidden], MEMBER, NOW), null);
});

Deno.test("no event id: an unreadable date is not a night", () => {
  const broken = event({ id: "e1", played_at: "not-a-date" });
  assertEquals(pickVisibleEvent([broken], MEMBER, NOW), null);
});

// ---------------------------------------------------------------------
// (b) The season eulogy.
// ---------------------------------------------------------------------

Deno.test("a closed season still inside the window gets the eulogy", () => {
  const seasons: SeasonRow[] = [
    { ordinal: 4, status: "active", ended_at: null },
    {
      ordinal: 3,
      status: "ended",
      ended_at: new Date(NOW.getTime() - 86_400_000).toISOString(),
    },
  ];
  const close = seasonCloseContext(seasons, NOW);
  assertEquals(close?.ordinal, 3);
});

Deno.test("the eulogy stops three days after the close", () => {
  const seasons: SeasonRow[] = [
    { ordinal: 4, status: "active", ended_at: null },
    {
      ordinal: 3,
      status: "ended",
      ended_at: new Date(NOW.getTime() - SEASON_CLOSE_WINDOW_MS - 1000)
        .toISOString(),
    },
  ];
  assertEquals(seasonCloseContext(seasons, NOW), null);
});

Deno.test("a close that happened four days ago is not news", () => {
  const seasons: SeasonRow[] = [
    { ordinal: 4, status: "active", ended_at: null },
    {
      ordinal: 3,
      status: "ended",
      ended_at: new Date(NOW.getTime() - 4 * 86_400_000).toISOString(),
    },
  ];
  assertEquals(seasonCloseContext(seasons, NOW), null);
});

Deno.test("the newest season by ordinal being ended still gets the eulogy", () => {
  const seasons: SeasonRow[] = [
    { ordinal: 2, status: "ended", ended_at: null },
    { ordinal: 1, status: "ended", ended_at: null },
  ];
  const close = seasonCloseContext(seasons, NOW);
  assertEquals(close?.ordinal, 2);
});

Deno.test("a room that has never closed a season gets no eulogy", () => {
  const seasons: SeasonRow[] = [
    { ordinal: 1, status: "active", ended_at: null },
  ];
  assertEquals(seasonCloseContext(seasons, NOW), null);
});

Deno.test("no seasons at all means no eulogy", () => {
  assertEquals(seasonCloseContext([], NOW), null);
});

// ---------------------------------------------------------------------
// The night the mascot describes.
// ---------------------------------------------------------------------

Deno.test("a night that has started is live", () => {
  const type = messageTypeForEvent(
    { played_at: "2026-11-08T08:30:00Z", settled_at: null },
    NOW,
  );
  assertEquals(type, "The night has started. The event is live.");
});

Deno.test("a night settled in the last day is a recap", () => {
  const type = messageTypeForEvent(
    {
      played_at: "2026-11-08T08:30:00Z",
      settled_at: "2026-11-08T08:45:00Z",
    },
    NOW,
  );
  assertEquals(type, "Post-play recap. The event has concluded.");
});

Deno.test("a night settled yesterday is the room between nights", () => {
  const type = messageTypeForEvent(
    {
      played_at: "2026-11-07T08:30:00Z",
      settled_at: "2026-11-07T09:00:00Z",
    },
    NOW,
  );
  assertEquals(
    type,
    "The room is between nights. Speak to the standings and the leaderboard. Do not prompt anyone to claim a seat.",
  );
});

Deno.test("a night in two days gets the seat nudge", () => {
  const type = messageTypeForEvent(
    { played_at: "2026-11-10T09:00:00Z", settled_at: null },
    NOW,
  );
  assertEquals(
    type,
    "New upcoming event in about 2 days. Prompt members to claim their seat.",
  );
});

Deno.test("a night next month gets no seat nudge", () => {
  const type = messageTypeForEvent(
    { played_at: "2026-12-15T09:30:00Z", settled_at: null },
    NOW,
  );
  assertEquals(
    type,
    "The next scheduled event is more than a week away. Speak to the standings. Do not pressure immediate claims.",
  );
});

// ---------------------------------------------------------------------
// (c) The roster.
// ---------------------------------------------------------------------

function member(over: Partial<MembershipRow> = {}): MembershipRow {
  return {
    user_id: MEMBER,
    role: "member",
    points_balance: 0,
    season_score: 0,
    membership_status: "active",
    ...over,
  };
}

Deno.test("a kicked member is not on the roster", () => {
  const rows = [
    member({ user_id: OTHER, membership_status: "kicked", season_score: 900 }),
    member({ user_id: MEMBER, season_score: 10 }),
  ];
  const active = activeMemberships(rows);
  assertEquals(active.length, 1);
  assertEquals(active[0].user_id, MEMBER);
});

Deno.test("the leader is the top of the ACTIVE standings", () => {
  const rows = activeMemberships([
    member({ user_id: OTHER, season_score: 900, membership_status: "kicked" }),
    member({ user_id: MEMBER, season_score: 40 }),
    member({ user_id: "c3", season_score: 10 }),
  ]);
  const facts = leaderFacts(rows, MEMBER);
  assertEquals(facts?.leaderScore, 40);
  assertEquals(facts?.margin, 30);
  assertEquals(facts?.callerRank, 1);
});

Deno.test("the caller's rank counts the host in", () => {
  const rows = [
    member({ user_id: "host1", role: "host", season_score: 50 }),
    member({ user_id: MEMBER, season_score: 30 }),
  ];
  assertEquals(leaderFacts(rows, MEMBER)?.callerRank, 2);
});

Deno.test("a caller who is not on the roster has no rank", () => {
  const rows = [member({ user_id: "host1", season_score: 50 })];
  assertEquals(leaderFacts(rows, MEMBER)?.callerRank, null);
});

Deno.test("an empty roster has no leader facts", () => {
  assertEquals(leaderFacts([], MEMBER), null);
});

Deno.test("a table on zero is not a leader", () => {
  const note = standingsNoteFor(0, 0);
  assert(note.includes("level/unplayed"));
});

Deno.test("a thirty point lead is a blowout", () => {
  assert(standingsNoteFor(100, 30).includes("blowout"));
});

Deno.test("a five point lead is a close table", () => {
  assert(standingsNoteFor(100, 5).includes("close"));
});
