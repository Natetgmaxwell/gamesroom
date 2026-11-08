// deno test Supabase/functions/briefing-push/
// The copy composer, on its own. No network, no database, no env: every
// string under test comes out of the row.

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  BRIEFING_KINDS,
  computeHeadcount,
  composePayload,
  dateIn,
  planPush,
  type BriefingRow,
  timeIn,
  weekdayIn,
} from "./plan.ts";

const EVENT = "00000000-0000-0000-0000-000000000011";
const ROOM = "00000000-0000-0000-0000-000000000012";
const USER = "00000000-0000-0000-0000-000000000013";

// 2026-11-20T09:30:00Z is 19:30 on Friday 20 November in Brisbane.
const NIGHT = "2026-11-20T09:30:00Z";
const BRISBANE = "Australia/Brisbane";

function row(over: Partial<BriefingRow> = {}): BriefingRow {
  return {
    event_id: EVENT,
    room_id: ROOM,
    user_id: USER,
    kind: "t48h",
    rsvp_state: "unclaimed",
    event_name: "Trivia Night",
    played_at: NIGHT,
    host_note: null,
    time_zone: BRISBANE,
    mascot_name: "Tally",
    ...over,
  };
}

Deno.test("the weekday and the time are read in the room's zone", () => {
  const at = new Date(NIGHT);
  assertEquals(weekdayIn(at, BRISBANE), "Friday");
  assertEquals(timeIn(at, BRISBANE), "7:30pm");
  assertEquals(dateIn(at, BRISBANE), "20 Nov");
  // The same instant is 09:30 Friday in UTC. The copy must not drift
  // onto the server's clock.
  assertEquals(weekdayIn(at, "UTC"), "Friday");
  assertEquals(timeIn(at, "UTC"), "9:30am");
});

Deno.test("a night that crosses midnight UTC keeps the room's weekday", () => {
  // 20:00 UTC Friday is 06:00 Saturday in Brisbane.
  const at = new Date("2026-11-20T20:00:00Z");
  assertEquals(weekdayIn(at, "UTC"), "Friday");
  assertEquals(weekdayIn(at, BRISBANE), "Saturday");
  assertEquals(timeIn(at, BRISBANE), "6:00am");
  // Sydney is an hour further on, but still Saturday.
  assertEquals(weekdayIn(at, "Australia/Sydney"), "Saturday");
});

Deno.test("an unreadable time zone falls back to UTC instead of throwing", () => {
  const at = new Date(NIGHT);
  assertEquals(weekdayIn(at, "Not/AZone"), weekdayIn(at, "UTC"));
  assertEquals(timeIn(at, "Not/AZone"), timeIn(at, "UTC"));
});

Deno.test("a claimed member reads logistics, and never the word claim", () => {
  for (const kind of ["t168h", "t48h", "morning_of"]) {
    const plan = planPush(row({ kind, rsvp_state: "claimed" }));
    assert(plan, `${kind} plans`);
    assertEquals(plan.body, "See you Friday at 7:30pm.");
    assertEquals(plan.title, "Tally: Trivia Night");
    assert(
      !/claim/i.test(plan.body),
      `claimed ${kind} body says claim: ${plan.body}`,
    );
  }
});

Deno.test("a claimed member reads the host's note when there is one", () => {
  const plan = planPush(
    row({ kind: "t48h", rsvp_state: "claimed", host_note: "Bring the good red." }),
  );
  assertEquals(
    plan?.body,
    "See you Friday at 7:30pm. Host's note: Bring the good red.",
  );
  assert(!/claim/i.test(plan?.body ?? ""));
});

Deno.test("a host note that tells people to claim is left out of a claimed push", () => {
  const plan = planPush(
    row({
      kind: "t48h",
      rsvp_state: "claimed",
      host_note: "Claim the corner table.",
    }),
  );
  assertEquals(plan?.body, "See you Friday at 7:30pm.");
  assert(!/claim/i.test(plan?.body ?? ""));
});

Deno.test("an unclaimed member reads the slot's own line", () => {
  assertEquals(
    planPush(row({ kind: "t168h", rsvp_state: "unclaimed" }))?.body,
    "Trivia Night is next Friday. Your seat's waiting.",
  );
  assertEquals(
    planPush(row({ kind: "t48h", rsvp_state: "unclaimed" }))?.body,
    "Friday at 7:30pm. Still a seat with your name on it.",
  );
  assertEquals(
    planPush(row({ kind: "morning_of", rsvp_state: "unclaimed" }))?.body,
    "Tonight at 7:30pm. There's still a seat.",
  );
});

Deno.test("the on-create line names the day", () => {
  const plan = planPush(
    row({ kind: "on_create", rsvp_state: "unclaimed" }),
  );
  assertEquals(
    plan?.body,
    "Trivia Night, Friday 20 Nov at 7:30pm. Open the room to grab a seat.",
  );
  assertEquals(plan?.title, "Tally: Trivia Night");
});

Deno.test("the headcount line counts what the room knows", () => {
  const plan = planPush(row({ kind: "host_headcount" }), {
    claimed: 5,
    unanswered: 3,
  });
  assertEquals(plan?.body, "5 in, 3 haven't said. Friday 7:30pm.");
  // A headcount with no count is not a push.
  assertEquals(planPush(row({ kind: "host_headcount" })), null);
});

Deno.test("the headcount counts claimed, unanswered, and leaves out hidden and declined", () => {
  const roster = ["a", "b", "c", "d", "e", "f"];
  const headcount = computeHeadcount(
    roster,
    ["f"], // hidden from this event
    [
      { member_id: "a", state: "claimed" },
      { member_id: "b", state: "claimed" },
      { member_id: "c", state: "declined" },
      { member_id: "g", state: "claimed" }, // not on the roster
    ],
  );
  assertEquals(headcount.claimed, 2);
  // The roster is a, b, c, d, e (f is hidden). a and b answered, c
  // declined, so d and e have not said.
  assertEquals(headcount.unanswered, 2);
});

Deno.test("the headcount never goes negative", () => {
  const headcount = computeHeadcount(
    ["a"],
    [],
    [{ member_id: "a", state: "claimed" }],
  );
  assertEquals(headcount.claimed, 1);
  assertEquals(headcount.unanswered, 0);
});

Deno.test("an unknown kind or an unreadable time plans nothing", () => {
  assertEquals(planPush(row({ kind: "sometime" })), null);
  assertEquals(planPush(row({ played_at: "not a time" })), null);
  assertEquals(planPush(row({ kind: "" })), null);
});

Deno.test("every kind the SQL can produce has a line", () => {
  for (const kind of BRIEFING_KINDS) {
    const plan = planPush(
      row({ kind, rsvp_state: kind === "host_headcount" ? "claimed" : "unclaimed" }),
      { claimed: 1, unanswered: 1 },
    );
    assert(plan, `${kind} plans`);
    assert(plan.body.length > 0, `${kind} has a body`);
    assertEquals(plan.title, "Tally: Trivia Night");
  }
});

Deno.test("the payload is an active, threaded alert", () => {
  const plan = planPush(row({ kind: "t48h", rsvp_state: "unclaimed" }))!;
  const payload = composePayload(plan) as {
    aps: Record<string, unknown>;
    type: string;
    kind: string;
    event_id: string;
  };
  assertEquals(payload.aps["interruption-level"], "active");
  assertEquals(payload.aps["thread-id"], `briefing-${EVENT}`);
  assertEquals(payload.type, "briefing_push");
  assertEquals(payload.kind, "t48h");
  assertEquals(payload.event_id, EVENT);
  assertEquals(
    (payload.aps.alert as { title: string }).title,
    "Tally: Trivia Night",
  );
});
