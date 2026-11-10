// deno test Supabase/functions/glad-push/
// Fakes for the DB and APNs; no network, no real .p8, no Supabase.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  composeGladCopy,
  type Deps,
  handleRequest,
  isQuietHour,
  type QueueRow,
  type TokenRow,
} from "./handler.ts";

const SECRET = "test-secret-glad";
const RECIPIENT = "00000000-0000-0000-0000-0000000000b1"; // the recipient
const CONNOR = "00000000-0000-0000-0000-0000000000a1";
const SAM_SENDER = "00000000-0000-0000-0000-0000000000a2";
const MAX = "00000000-0000-0000-0000-0000000000a3";
const ALI = "00000000-0000-0000-0000-0000000000a4";
const OTHER = "00000000-0000-0000-0000-0000000000c9";
const EVENT = "00000000-0000-0000-0000-000000000012";
const ROOM = "00000000-0000-0000-0000-000000000013";
const BRISBANE = "Australia/Brisbane";
const NAMES: Record<string, string> = { [CONNOR]: "Connor", [SAM_SENDER]: "Sam", [MAX]: "Jo", [ALI]: "Max" };

// Saturday 2026-11-14 09:05 Brisbane (UTC+10).
const MORNING = new Date("2026-11-13T23:05:00Z");
// Friday 2026-11-13 23:30 Brisbane.
const LATE = new Date("2026-11-13T13:30:00Z");

function row(over: Partial<QueueRow> = {}): QueueRow {
  return {
    event_id: EVENT,
    to_user: RECIPIENT,
    room_id: ROOM,
    deliver_at: "2026-11-13T23:00:00Z", // 09:00 Brisbane
    push_status: "queued",
    ...over,
  };
}

function fakeDeps(over: Partial<Deps> = {}, senders: string[] = [CONNOR, SAM_SENDER]) {
  const log = {
    sentTo: [] as string[],
    payloads: [] as Record<string, unknown>[],
    marked: [] as string[],
    claims: 0,
    tokenQueries: [] as string[],
    senderQueries: [] as string[],
    deactivated: [] as string[],
  };
  const tokens: TokenRow[] = [
    { id: "t1", user_id: RECIPIENT, device_token: "aa".repeat(32), environment: "production" },
    { id: "t2", user_id: RECIPIENT, device_token: "bb".repeat(32), environment: "production" },
    { id: "t3", user_id: OTHER, device_token: "cc".repeat(32), environment: "production" },
  ];
  const deps: Deps = {
    enabled: true,
    secret: SECRET,
    now: () => MORNING,
    loadQueueRow: (e, u) => Promise.resolve(e === EVENT && u === RECIPIENT ? row() : null),
    claimQueueRow: () => {
      log.claims++;
      return Promise.resolve(true);
    },
    markQueueRow: (_e, _u, s) => {
      log.marked.push(s);
      return Promise.resolve();
    },
    loadSenderIds: (e, u) => {
      log.senderQueries.push(`${e}/${u}`);
      return Promise.resolve(senders);
    },
    loadDisplayName: (id) => Promise.resolve(NAMES[id] ?? null),
    loadRoomTimeZone: () => Promise.resolve(BRISBANE),
    loadTokens: (u) => {
      log.tokenQueries.push(u);
      return Promise.resolve(tokens);
    },
    deactivateTokens: (ids) => {
      log.deactivated.push(...ids);
      return Promise.resolve();
    },
    send: (token, payload) => {
      log.sentTo.push(token.user_id);
      log.payloads.push(payload);
      return Promise.resolve(token.id === "t2" ? { status: "bad_token", http_status: 410 } : { status: "sent" });
    },
    ...over,
  };
  return { deps, log };
}

function post(body: unknown, secret: string | null = SECRET): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers["X-Glad-Push-Secret"] = secret;
  return new Request("http://localhost/", { method: "POST", headers, body: JSON.stringify(body) });
}
const body = () => ({ event_id: EVENT, to_user: RECIPIENT });
const alertBody = (p: Record<string, unknown>) => (p.aps as { alert: { body: string } }).alert.body;

// The same table as TestsGladYouCame.swift, so the push and the recap say
// the same sentence.
Deno.test("batching copy for 1, 2, 3 and 4 senders", () => {
  const table: [string[], string | null][] = [
    [[], null],
    [["Connor"], "Connor was glad you came."],
    [["Connor", "Sam"], "Connor and Sam were glad you came."],
    [["Connor", "Sam", "Jo"], "Connor, Sam and Jo were glad you came."],
    [["Connor", "Sam", "Jo", "Max"], "Connor, Sam and 2 others were glad you came."],
    [["Connor", "Sam", "Jo", "Max", "Ali"], "Connor, Sam and 3 others were glad you came."],
    [["  ", "Sam"], "Sam was glad you came."],
  ];
  for (const [input, expected] of table) assertEquals(composeGladCopy(input), expected, input.join(","));
});

Deno.test("quiet hours are 22:00 to 08:00 on the room's clock", () => {
  assert(isQuietHour(LATE, BRISBANE), "23:30 is quiet");
  assert(!isQuietHour(MORNING, BRISBANE), "09:05 is not");
  assert(isQuietHour(new Date("2026-11-13T21:59:00Z"), BRISBANE), "07:59 is quiet");
  assert(!isQuietHour(new Date("2026-11-13T22:00:00Z"), BRISBANE), "08:00 is not");
  assert(isQuietHour(new Date("2026-11-13T12:00:00Z"), BRISBANE), "22:00 is quiet");
});

Deno.test("rejects a missing or wrong secret, fails closed when unset", async () => {
  const { deps, log } = fakeDeps();
  assertEquals((await handleRequest(post(body(), null), deps)).status, 401);
  assertEquals((await handleRequest(post(body(), "nope"), deps)).status, 401);
  const unset = fakeDeps({ secret: "" });
  assertEquals((await handleRequest(post(body(), ""), unset.deps)).status, 401);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("disabled sends nothing and does not take the row", async () => {
  const { deps, log } = fakeDeps({ enabled: false });
  assertEquals((await (await handleRequest(post(body()), deps)).json()).status, "disabled");
  assertEquals(log.claims, 0);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("one batched push to the recipient only, in the senders' order", async () => {
  const { deps, log } = fakeDeps();
  const out = await (await handleRequest(post({ ...body(), from_user: OTHER, user_ids: [OTHER] }), deps)).json();
  assertEquals(out.status, "sent");
  assertEquals(log.tokenQueries, [RECIPIENT]);
  assert(log.sentTo.every((u) => u === RECIPIENT), `sent to ${log.sentTo}`);
  assertEquals(alertBody(log.payloads[0]), "Connor and Sam were glad you came.");
  assertEquals(log.marked, ["sent"]);
  assertEquals(log.deactivated, ["t2"]);
  assertEquals(out.sent, 1);
  // The response carries no names and no count of senders.
  assertEquals(Object.keys(out).sort(), ["bad_tokens", "errors", "sent", "status"]);
});

Deno.test("four senders fold into 'and 2 others'", async () => {
  const { deps, log } = fakeDeps({}, [CONNOR, SAM_SENDER, MAX, ALI]);
  await handleRequest(post(body()), deps);
  assertEquals(alertBody(log.payloads[0]), "Connor, Sam and 2 others were glad you came.");
});

Deno.test("never inside 22:00-08:00: the row stays queued for the morning", async () => {
  const { deps, log } = fakeDeps({
    now: () => LATE,
    loadQueueRow: () => Promise.resolve(row({ deliver_at: "2026-11-13T11:00:00Z" })),
  });
  const out = await (await handleRequest(post(body()), deps)).json();
  assertEquals(out.status, "quiet_hours");
  assertEquals(log.claims, 0);
  assertEquals(log.marked.length, 0);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("not before its hour", async () => {
  const { deps, log } = fakeDeps({
    loadQueueRow: () => Promise.resolve(row({ deliver_at: "2026-11-14T00:00:00Z" })),
  });
  assertEquals((await (await handleRequest(post(body()), deps)).json()).status, "not_due");
  assertEquals(log.sentTo.length, 0);
});

Deno.test("once per night: a sent or claimed row is not sent again", async () => {
  const sent = fakeDeps({ loadQueueRow: () => Promise.resolve(row({ push_status: "sent" })) });
  assertEquals((await (await handleRequest(post(body()), sent.deps)).json()).status, "already_sent");
  assertEquals(sent.log.sentTo.length, 0);
  const lost = fakeDeps({ claimQueueRow: () => Promise.resolve(false) });
  assertEquals((await (await handleRequest(post(body()), lost.deps)).json()).status, "already_claimed");
  assertEquals(lost.log.sentTo.length, 0);
});

Deno.test("a sender is never told about themself, and nameless senders are dropped", async () => {
  const { deps, log } = fakeDeps({}, [RECIPIENT, CONNOR, OTHER]);
  await handleRequest(post(body()), deps);
  assertEquals(alertBody(log.payloads[0]), "Connor was glad you came.");
});

Deno.test("no device marks the row and sends nothing", async () => {
  const { deps, log } = fakeDeps({ loadTokens: () => Promise.resolve([]) });
  assertEquals((await (await handleRequest(post(body()), deps)).json()).status, "no_device");
  assertEquals(log.marked, ["no_device"]);
});

Deno.test("bad body is a 400", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleRequest(post({ event_id: "x" }), deps)).status, 400);
});
