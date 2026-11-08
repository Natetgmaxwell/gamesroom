// deno test Supabase/functions/briefing-push/
// The request handling and the APNs sender, on fakes. No network, no
// database, no real .p8.

import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";
import {
  handleRequest,
  parseRow,
  type Deps,
  secretsMatch,
  type TokenRow,
} from "./handler.ts";
import { makeApnsSender, makeJwtProvider, p1363ToDer } from "./apns.ts";
import type { BriefingRow } from "./plan.ts";

const SECRET = "test-secret-123";
const EVENT = "00000000-0000-0000-0000-000000000011";
const ROOM = "00000000-0000-0000-0000-000000000012";
const USER = "00000000-0000-0000-0000-000000000013";
const OTHER = "00000000-0000-0000-0000-000000000014";

function row(over: Partial<BriefingRow> = {}): BriefingRow {
  return {
    event_id: EVENT,
    room_id: ROOM,
    user_id: USER,
    kind: "t48h",
    rsvp_state: "unclaimed",
    event_name: "Trivia Night",
    played_at: "2026-11-20T09:30:00Z",
    host_note: null,
    time_zone: "Australia/Brisbane",
    mascot_name: "Tally",
    ...over,
  };
}

function fakeDeps(over: Partial<Deps> = {}) {
  const log = {
    calls: [] as string[],
    sentTo: [] as string[],
    deactivated: [] as string[],
    tokenQueries: [] as string[],
    claimed: [] as string[],
    headcounts: [] as string[],
  };
  const tokens: TokenRow[] = [
    { id: "t1", user_id: USER, device_token: "aa".repeat(32), environment: "sandbox" },
    { id: "t2", user_id: USER, device_token: "bb".repeat(32), environment: "production" },
    // A row for someone else that a buggy query might leak through.
    { id: "t3", user_id: OTHER, device_token: "cc".repeat(32), environment: "production" },
  ];
  const deps: Deps = {
    enabled: true,
    secret: SECRET,
    loadTokens: (userId) => {
      log.calls.push("tokens");
      log.tokenQueries.push(userId);
      return Promise.resolve(tokens);
    },
    claimSlot: (r) => {
      log.calls.push("claim");
      log.claimed.push(`${r.event_id}:${r.user_id}:${r.kind}`);
      return Promise.resolve(true);
    },
    deactivateTokens: (ids) => {
      log.calls.push("deactivate");
      log.deactivated.push(...ids);
      return Promise.resolve();
    },
    loadHeadcount: (eventId) => {
      log.calls.push("headcount");
      log.headcounts.push(eventId);
      return Promise.resolve({ claimed: 5, unanswered: 3 });
    },
    send: (token) => {
      log.calls.push("send");
      log.sentTo.push(token.user_id);
      return Promise.resolve(
        token.id === "t2"
          ? { status: "bad_token", http_status: 410 }
          : { status: "sent" },
      );
    },
    ...over,
  };
  return { deps, log };
}

function post(
  body: unknown,
  secret: string | null = SECRET,
): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers["X-Briefing-Push-Secret"] = secret;
  return new Request("http://localhost/", {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}

Deno.test("rejects missing or wrong secret (fails closed when unset)", async () => {
  const { deps, log } = fakeDeps();
  assertEquals((await handleRequest(post({ rows: [row()] }, null), deps)).status, 401);
  assertEquals((await handleRequest(post({ rows: [row()] }, "nope"), deps)).status, 401);
  const unset = fakeDeps({ secret: "" });
  assertEquals((await handleRequest(post({ rows: [row()] }, ""), unset.deps)).status, 401);
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.claimed.length, 0);
});

Deno.test("only POST is allowed", async () => {
  const { deps } = fakeDeps();
  assertEquals(
    (await handleRequest(new Request("http://localhost/"), deps)).status,
    405,
  );
});

Deno.test("a payload without rows is a 400", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleRequest(post({}), deps)).status, 400);
  assertEquals((await handleRequest(post({ rows: "nope" }), deps)).status, 400);
});

Deno.test("the disabled flag sends nothing and spends no slot", async () => {
  const { deps, log } = fakeDeps({ enabled: false });
  const res = await handleRequest(post({ rows: [row()] }), deps);
  const out = await res.json();
  assertEquals(res.status, 200);
  assertEquals(out.status, "disabled");
  assertEquals(out.sent, 0);
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.claimed.length, 0);
  assertEquals(log.tokenQueries.length, 0);
});

Deno.test("the ledger row is written before the send", async () => {
  const { deps, log } = fakeDeps();
  const res = await handleRequest(post({ rows: [row()] }), deps);
  const out = await res.json();
  assertEquals(res.status, 200);
  assertEquals(out.status, "sent");
  assertEquals(out.sent, 1);
  assertEquals(out.pushed, 1);
  assertEquals(log.claimed, [`${EVENT}:${USER}:t48h`]);
  // The claim comes before the first send and the deactivate comes last.
  assertEquals(log.calls[0], "tokens");
  assertEquals(log.calls[1], "claim");
  assertEquals(log.calls[2], "send");
  assertEquals(log.calls[log.calls.length - 1], "deactivate");
});

Deno.test("the push goes to the row's user only", async () => {
  const { deps, log } = fakeDeps();
  await handleRequest(post({ rows: [row()] }), deps);
  assertEquals(log.tokenQueries, [USER]);
  assert(log.sentTo.every((u) => u === USER), `sent to ${log.sentTo}`);
  assertEquals(log.sentTo.length, 2);
});

Deno.test("a dead token is marked inactive", async () => {
  const { deps, log } = fakeDeps();
  const out = await (await handleRequest(post({ rows: [row()] }), deps)).json();
  assertEquals(log.deactivated, ["t2"]);
  assertEquals(out.bad_tokens, 1);
});

Deno.test("a slot that was already spent is not sent again", async () => {
  const { deps, log } = fakeDeps({ claimSlot: () => Promise.resolve(false) });
  const out = await (await handleRequest(post({ rows: [row()] }), deps)).json();
  assertEquals(out.duplicates, 1);
  assertEquals(out.pushed, 0);
  assertEquals(out.sent, 0);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("a member with no device does not spend the slot", async () => {
  const { deps, log } = fakeDeps({ loadTokens: () => Promise.resolve([]) });
  const out = await (await handleRequest(post({ rows: [row()] }), deps)).json();
  assertEquals(out.skipped, 1);
  assertEquals(out.pushed, 0);
  assertEquals(log.claimed.length, 0);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("a slot that cannot be claimed is never sent", async () => {
  const { deps, log } = fakeDeps({
    claimSlot: () => Promise.reject(new Error("ledger is down")),
  });
  const out = await (await handleRequest(post({ rows: [row()] }), deps)).json();
  assertEquals(out.errors, 1);
  assertEquals(out.pushed, 0);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("the headcount comes from the room, once per event", async () => {
  const { deps, log } = fakeDeps();
  const out = await (await handleRequest(
    post({
      rows: [
        row({ kind: "host_headcount", user_id: USER }),
        row({ kind: "host_headcount", user_id: OTHER }),
      ],
    }),
    deps,
  )).json();
  assertEquals(out.pushed, 2);
  assertEquals(log.headcounts, [EVENT]);
});

Deno.test("a malformed row is skipped, a good row still goes", async () => {
  const { deps, log } = fakeDeps();
  const out = await (await handleRequest(
    post({
      rows: [
        { event_id: "not-a-uuid" },
        { ...row(), played_at: "not a time" },
        row(),
      ],
    }),
    deps,
  )).json();
  assertEquals(out.skipped, 2);
  assertEquals(out.pushed, 1);
  assertEquals(log.sentTo.length, 2);
});

Deno.test("parseRow reads the payload shape and nothing else", () => {
  const parsed = parseRow({ ...row(), host_note: null, extra: "ignored" });
  assert(parsed);
  assertEquals(parsed.event_id, EVENT);
  assertEquals(parsed.kind, "t48h");
  assertEquals(parsed.host_note, null);
  assertEquals(parseRow(null), null);
  assertEquals(parseRow("nope"), null);
  assertEquals(parseRow({ event_id: "nope" }), null);
});

Deno.test("secretsMatch is exact", () => {
  assert(secretsMatch("abc", "abc"));
  assert(!secretsMatch("abc", "abcd"));
  assert(!secretsMatch(null, "abc"));
  assert(!secretsMatch("", ""));
});

async function throwawayP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = encodeBase64(pkcs8).match(/.{1,64}/g)!.join("\n");
  return {
    pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`,
    publicKey: pair.publicKey,
  };
}

function derToP1363(der: Uint8Array): Uint8Array<ArrayBuffer> {
  let i = 2;
  const read = () => {
    const len = der[i + 1];
    let v = der.slice(i + 2, i + 2 + len);
    i += 2 + len;
    while (v.length > 32 && v[0] === 0) v = v.slice(1);
    const out = new Uint8Array(32);
    out.set(v, 32 - v.length);
    return out;
  };
  const r = read(), s = read();
  return new Uint8Array([...r, ...s]);
}

Deno.test("JWT: ES256, kid/iss claims, verifiable signature, cached ~50 min", async () => {
  const { pem, publicKey } = await throwawayP8();
  let clock = 1_800_000_000_000;
  const get = makeJwtProvider(
    { keyId: "KEYID12345", teamId: "37S7KT7W83", keyP8: pem, bundleId: "com.gamesroom.app" },
    () => clock,
  );
  const t1 = await get();
  const [h, p, s] = t1.split(".");
  const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(dec(h), { alg: "ES256", kid: "KEYID12345" });
  assertEquals(dec(p).iss, "37S7KT7W83");
  const sigDer = Uint8Array.from(
    atob(s.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - s.length % 4) % 4)),
    (c) => c.charCodeAt(0),
  );
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    derToP1363(sigDer),
    new TextEncoder().encode(`${h}.${p}`),
  );
  assert(ok, "signature verifies against the throwaway public key");
  clock += 49 * 60 * 1000;
  assertEquals(await get(), t1, "cached within 50 min");
  clock += 2 * 60 * 1000;
  assert((await get()) !== t1, "refreshed after 50 min");
});

Deno.test("p1363ToDer pads high-bit integers", () => {
  const raw = new Uint8Array(64).fill(0x80);
  const der = p1363ToDer(raw);
  assertEquals(der[0], 0x30);
  assertEquals(der[2], 0x02);
  assertEquals(der[3], 33);
});

Deno.test("APNs sender: topic, host per environment, 410 to bad_token, 400 BadDeviceToken to bad_token", async () => {
  const { pem } = await throwawayP8();
  const calls: { url: string; headers: Record<string, string> }[] = [];
  let next = new Response("", { status: 200 });
  const fake = ((url: string, init: RequestInit) => {
    calls.push({ url, headers: init.headers as Record<string, string> });
    return Promise.resolve(next);
  }) as unknown as typeof fetch;
  const send = makeApnsSender(
    { keyId: "K", teamId: "37S7KT7W83", keyP8: pem, bundleId: "com.gamesroom.app" },
    fake,
  );
  const tok = (environment: "sandbox" | "production"): TokenRow => ({
    id: "t",
    user_id: USER,
    device_token: "ab".repeat(32),
    environment,
  });

  assertEquals((await send(tok("sandbox"), { collapse_id: "briefing-x" })).status, "sent");
  assert(calls[0].url.startsWith("https://api.sandbox.push.apple.com/3/device/"));
  assertEquals(calls[0].headers["apns-topic"], "com.gamesroom.app");
  assertEquals(calls[0].headers["apns-push-type"], "alert");
  assertEquals(calls[0].headers["apns-collapse-id"], "briefing-x");

  next = new Response('{"reason":"Unregistered"}', { status: 410 });
  assertEquals((await send(tok("production"), {})).status, "bad_token");
  assert(calls[1].url.startsWith("https://api.push.apple.com/3/device/"));

  next = new Response('{"reason":"BadDeviceToken"}', { status: 400 });
  assertEquals((await send(tok("production"), {})).status, "bad_token");

  next = new Response('{"reason":"InvalidProviderToken"}', { status: 403 });
  assertEquals((await send(tok("production"), {})).status, "error");

  const unset = makeApnsSender(
    { keyId: "", teamId: "", keyP8: "", bundleId: "com.gamesroom.app" },
    fake,
  );
  assertEquals((await unset(tok("production"), {})).status, "error");
});
