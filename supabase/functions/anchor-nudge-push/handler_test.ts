// deno test supabase/functions/anchor-nudge-push/
// Fakes for the DB and APNs; no network, no real .p8, no Supabase.
// Mirrors ../question-turn-push/handler_test.ts, minus the APNs/JWT tests
// (that code is shared and already covered there).

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  calendarDaysBetween,
  composeAnchorCopy,
  composePayload,
  type Deps,
  FALLBACK_TIME_ZONE,
  handleRequest,
  type TokenRow,
  type NudgeRow,
  zoneOrFallback,
} from "./handler.ts";

const SECRET = "test-secret-123";
const INVITER = "00000000-0000-0000-0000-0000000000a3";
const NEWCOMER = "00000000-0000-0000-0000-0000000000b1";
const OTHER = "00000000-0000-0000-0000-0000000000a1";
const EVENT = "00000000-0000-0000-0000-000000000012";
const ROOM = "00000000-0000-0000-0000-000000000013";

// The room's zone. Every room has one now (rooms.time_zone, migration
// 108), so the copy follows the room and never a constant in this file.
const BRISBANE = "Australia/Brisbane";
const NEW_YORK = "America/New_York";

// Thursday 2026-10-22, 19:00 in Australia/Brisbane.
const NOW = new Date("2026-10-22T09:00:00Z");
// Friday 2026-10-23, 09:00 Brisbane — one day out.
const PLAYED_FRI = "2026-10-22T23:00:00Z";
// Saturday 2026-10-24, 00:30 Brisbane — still Friday in UTC.
const PLAYED_SAT_BRISBANE = "2026-10-23T14:30:00Z";

function nudge(over: Partial<NudgeRow> = {}): NudgeRow {
  return {
    event_id: EVENT,
    newcomer_user_id: NEWCOMER,
    inviter_user_id: INVITER,
    room_id: ROOM,
    created_at: "2026-10-22T09:00:01Z",
    push_status: "queued",
    ...over,
  };
}

function fakeDeps(over: Partial<Deps> = {}, roomZone: string | null = BRISBANE) {
  const log = {
    sentTo: [] as string[],
    payloads: [] as Record<string, unknown>[],
    deactivated: [] as string[],
    marked: [] as string[],
    tokenQueries: [] as string[],
    nameQueries: [] as string[],
    claims: [] as string[],
    zoneQueries: [] as string[],
    seatQueries: [] as string[],
  };
  const tokens: TokenRow[] = [
    { id: "t1", user_id: INVITER, device_token: "aa".repeat(32), environment: "sandbox" },
    { id: "t2", user_id: INVITER, device_token: "bb".repeat(32), environment: "production" },
    // A row for someone else that a buggy query might leak through.
    { id: "t3", user_id: OTHER, device_token: "cc".repeat(32), environment: "production" },
  ];
  const deps: Deps = {
    enabled: true,
    secret: SECRET,
    now: () => NOW,
    loadNudge: (eventId, newcomerUserId) =>
      Promise.resolve(eventId === EVENT && newcomerUserId === NEWCOMER ? nudge() : null),
    claimNudge: (eventId, newcomerUserId) => {
      log.claims.push(`${eventId}/${newcomerUserId}`);
      return Promise.resolve(true);
    },
    loadEvent: (eventId) =>
      Promise.resolve({ id: eventId, room_id: ROOM, played_at: PLAYED_FRI }),
    loadDisplayName: (userId) => {
      log.nameQueries.push(userId);
      return Promise.resolve(userId === NEWCOMER ? "Sam" : "Someone else");
    },
    loadRoomTimeZone: (roomId) => {
      log.zoneQueries.push(roomId);
      return Promise.resolve(roomZone);
    },
    loadRsvpState: (eventId, userId) => {
      log.seatQueries.push(`${eventId}/${userId}`);
      return Promise.resolve("unclaimed");
    },
    loadTokens: (userId) => {
      log.tokenQueries.push(userId);
      return Promise.resolve(tokens);
    },
    deactivateTokens: (ids) => {
      log.deactivated.push(...ids);
      return Promise.resolve();
    },
    markNudge: (_e, _n, status) => {
      log.marked.push(status);
      return Promise.resolve();
    },
    send: (token, payload) => {
      log.sentTo.push(token.user_id);
      log.payloads.push(payload);
      return Promise.resolve(
        token.id === "t2" ? { status: "bad_token", http_status: 410 } : { status: "sent" },
      );
    },
    ...over,
  };
  return { deps, log };
}

function post(body: unknown, secret: string | null = SECRET): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers["X-Anchor-Push-Secret"] = secret;
  return new Request("http://localhost/", { method: "POST", headers, body: JSON.stringify(body) });
}

function d(iso: string): Date {
  return new Date(iso);
}

function body(): Record<string, unknown> {
  return { event_id: EVENT, newcomer_user_id: NEWCOMER };
}

function alertBody(payload: Record<string, unknown>): string {
  return (payload.aps as { alert: { body: string } }).alert.body;
}

Deno.test("rejects missing or wrong secret (fails closed when unset)", async () => {
  const { deps, log } = fakeDeps();
  assertEquals((await handleRequest(post(body(), null), deps)).status, 401);
  assertEquals((await handleRequest(post(body(), "nope"), deps)).status, 401);
  const unset = fakeDeps({ secret: "" });
  assertEquals((await handleRequest(post(body(), ""), unset.deps)).status, 401);
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.tokenQueries.length, 0);
});

Deno.test("disabled flag sends nothing and does not take the row", async () => {
  const { deps, log } = fakeDeps({ enabled: false });
  const res = await handleRequest(post(body()), deps);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "disabled");
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.tokenQueries.length, 0);
  assertEquals(log.marked.length, 0);
  // The row stays queued, so the next tick can still deliver it once the
  // feature is switched on.
  assertEquals(log.claims.length, 0);
});

Deno.test("sends the spec copy when the event is within six days", async () => {
  const { deps, log } = fakeDeps();
  const res = await handleRequest(post(body()), deps);
  const out = await res.json();
  assertEquals(res.status, 200);
  assertEquals(alertBody(log.payloads[0]), "Sam's coming Friday. Are you?");
  assertEquals(out.status, "sent");
  assertEquals(out.sent, 1);
  assertEquals(log.marked, ["sent"]);
});

Deno.test("sends the date copy when the event is further out", async () => {
  const far = { id: EVENT, room_id: ROOM, played_at: "2026-11-13T23:00:00Z" };
  const { deps, log } = fakeDeps({ loadEvent: () => Promise.resolve(far) });
  const res = await handleRequest(post(body()), deps);
  assertEquals((await res.json()).status, "sent");
  assertEquals(alertBody(log.payloads[0]), "Sam's coming on 14 Nov. Are you?");
});

Deno.test("deactivates a 410 token and marks the ledger row", async () => {
  const { deps, log } = fakeDeps();
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(log.deactivated, ["t2"]);
  assertEquals(out.sent, 1);
  assertEquals(out.bad_tokens, 1);
  assertEquals(log.marked, ["sent"]);
});

Deno.test("the inviter is the only recipient; a body-supplied recipient is ignored", async () => {
  const { deps, log } = fakeDeps();
  const res = await handleRequest(
    post({ ...body(), inviter_user_id: OTHER, user_ids: [OTHER], newcomer_user_id: NEWCOMER }),
    deps,
  );
  assertEquals(res.status, 200);
  assertEquals(log.tokenQueries, [INVITER]);
  assert(log.sentTo.every((u) => u === INVITER), `sent to ${log.sentTo}`);
  assertEquals(log.sentTo.length, 2);
  assertEquals(log.nameQueries, [NEWCOMER], "the name read is the newcomer's");
});

Deno.test("a started event is never pushed, even though SQL let it through", async () => {
  const started = { id: EVENT, room_id: ROOM, played_at: "2026-10-22T08:00:00Z" };
  const { deps, log } = fakeDeps({ loadEvent: () => Promise.resolve(started) });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "skipped_started");
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.marked, ["skipped_started"]);
});

Deno.test("a ledger row already sent is not sent again", async () => {
  const { deps, log } = fakeDeps({ loadNudge: () => Promise.resolve(nudge({ push_status: "sent" })) });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "already_sent");
  assertEquals(log.sentTo.length, 0);
  // A row that already had its turn is not even claimed.
  assertEquals(log.claims.length, 0);
});

Deno.test("an inviter with no device is recorded, not retried into a fan-out", async () => {
  const { deps, log } = fakeDeps({ loadTokens: () => Promise.resolve([]) });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "no_device");
  assertEquals(log.marked, ["no_device"]);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("every APNs failure marks the ledger row failed", async () => {
  const { deps, log } = fakeDeps({
    send: () => Promise.resolve({ status: "error", http_status: 503, reason: "APNs 503" }),
  });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "failed");
  assertEquals(out.sent, 0);
  assertEquals(out.errors, 2);
  assertEquals(log.marked, ["failed"]);
  assertEquals(log.deactivated, []);
});

Deno.test("bad input, unknown ledger row and unknown event", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleRequest(post({}), deps)).status, 400);
  assertEquals((await handleRequest(post({ event_id: EVENT }), deps)).status, 400);
  assertEquals((await handleRequest(post({ event_id: "nope", newcomer_user_id: NEWCOMER }), deps)).status, 400);
  assertEquals(
    (await handleRequest(post({ event_id: "00000000-0000-0000-0000-000000000099", newcomer_user_id: NEWCOMER }), deps)).status,
    404,
  );
  assertEquals((await handleRequest(post(body()), fakeDeps({ loadEvent: () => Promise.resolve(null) }).deps)).status, 404);
  assertEquals((await handleRequest(new Request("http://localhost/"), deps)).status, 405);
});

Deno.test("payload carries room and event, and no other member's id", () => {
  const p = composePayload(nudge(), "Sam's coming Friday. Are you?") as Record<string, unknown>;
  assertEquals(p.type, "anchor_nudge");
  assertEquals(p.room_id, ROOM);
  assertEquals(p.event_id, EVENT);
  assert((p.aps as { alert: { title: string } }).alert.title.length > 0);
  assert(!JSON.stringify(p).includes(OTHER));
});

Deno.test("the interruption level is active, not time-sensitive", async () => {
  const { deps, log } = fakeDeps();
  await handleRequest(post(body()), deps);
  const aps = log.payloads[0].aps as Record<string, unknown>;
  // Audit 01-notifications #13: the nudge is for a night days away, so
  // it must not break through Focus or Sleep.
  assertEquals(aps["interruption-level"], "active");
  assert(aps["interruption-level"] !== "time-sensitive");
  assertEquals(aps["thread-id"], `anchor-${EVENT}`);
});

Deno.test("the row is claimed before the send, so a double post sends once", async () => {
  const { deps, log } = fakeDeps({ claimNudge: () => Promise.resolve(false) });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "already_claimed");
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.tokenQueries.length, 0);
});

Deno.test("the row is claimed on the way through", async () => {
  const { deps, log } = fakeDeps();
  await handleRequest(post(body()), deps);
  assertEquals(log.claims, [`${EVENT}/${NEWCOMER}`]);
});

Deno.test("an inviter who claimed a seat after the queue is skipped", async () => {
  const { deps, log } = fakeDeps({ loadRsvpState: () => Promise.resolve("claimed") });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "skipped_seated");
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.marked, ["skipped_seated"]);
});

Deno.test("the seat re-check asks about the inviter, not the newcomer", async () => {
  const { deps, log } = fakeDeps();
  await handleRequest(post(body()), deps);
  assertEquals(log.seatQueries, [`${EVENT}/${INVITER}`]);
});

Deno.test("the weekday follows the room's zone, not a hardcoded one", async () => {
  // The same event, two rooms: Brisbane reads it as Friday, New York
  // (five hours behind) still reads it as Thursday.
  const { deps, log } = fakeDeps({}, NEW_YORK);
  await handleRequest(post(body()), deps);
  assertEquals(alertBody(log.payloads[0]), "Sam's coming Thursday. Are you?");
  assertEquals(log.zoneQueries, [ROOM]);

  const brisbane = fakeDeps();
  await handleRequest(post(body()), brisbane.deps);
  assertEquals(alertBody(brisbane.log.payloads[0]), "Sam's coming Friday. Are you?");
});

Deno.test("an unreadable room zone falls back to UTC, not to Brisbane", async () => {
  const { deps, log } = fakeDeps({ loadRoomTimeZone: () => Promise.resolve(null) });
  await handleRequest(post(body()), deps);
  assertEquals(alertBody(log.payloads[0]), "Sam's coming Thursday. Are you?", "UTC day for 23:00Z");
  assertEquals(FALLBACK_TIME_ZONE, "UTC");
  assertEquals(zoneOrFallback(null), "UTC");
  assertEquals(zoneOrFallback(""), "UTC");
  assertEquals(zoneOrFallback("Not/AZone"), "UTC");
  assertEquals(zoneOrFallback(BRISBANE), BRISBANE);
});

Deno.test("copy: weekday form inside six days, date form past them", () => {
  assertEquals(
    composeAnchorCopy("Sam", d(PLAYED_FRI), NOW, BRISBANE),
    "Sam's coming Friday. Are you?",
  );
  // Six days out, still the weekday.
  assertEquals(
    composeAnchorCopy("Sam", d("2026-10-27T23:00:00Z"), NOW, BRISBANE),
    "Sam's coming Wednesday. Are you?",
  );
  // Seven days out, the date.
  assertEquals(
    composeAnchorCopy("Sam", d("2026-10-28T23:00:00Z"), NOW, BRISBANE),
    "Sam's coming on 29 Oct. Are you?",
  );
  assertEquals(
    composeAnchorCopy("Sam", d("2026-11-13T23:00:00Z"), NOW, BRISBANE),
    "Sam's coming on 14 Nov. Are you?",
  );
  // Tonight reads as today, not as tomorrow's weekday.
  assertEquals(
    composeAnchorCopy("Sam", d("2026-10-22T12:00:00Z"), NOW, BRISBANE),
    "Sam's coming Thursday. Are you?",
  );
  // A blank name never reads as a stray apostrophe.
  assertEquals(
    composeAnchorCopy("  ", d(PLAYED_FRI), NOW, BRISBANE),
    "Someone's coming Friday. Are you?",
  );
});

Deno.test("copy weekdays follow the room's zone, not UTC", () => {
  // 00:30 Saturday in Brisbane, still Friday 14:30 UTC.
  assertEquals(
    composeAnchorCopy("Sam", d(PLAYED_SAT_BRISBANE), NOW, BRISBANE),
    "Sam's coming Saturday. Are you?",
  );
  assertEquals(
    composeAnchorCopy("Sam", d(PLAYED_SAT_BRISBANE), NOW, "UTC"),
    "Sam's coming Friday. Are you?",
  );
  assertEquals(calendarDaysBetween(NOW, d(PLAYED_SAT_BRISBANE), BRISBANE), 2);
  assertEquals(calendarDaysBetween(NOW, d(PLAYED_SAT_BRISBANE), "UTC"), 1);
});

Deno.test("the room's clock is the room's own zone", () => {
  // Brisbane is UTC+10 year round (no DST since 1991), which is what makes a
  // week of copy safe in one zone.
  assertEquals(
    calendarDaysBetween(new Date("2026-01-15T00:00:00Z"), new Date("2026-06-15T00:00:00Z"), BRISBANE),
    151,
  );
  // The zone is read from the room, never from a constant in this file.
  assertEquals(FALLBACK_TIME_ZONE, "UTC");
});
