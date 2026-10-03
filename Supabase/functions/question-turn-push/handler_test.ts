// deno test Supabase/functions/question-turn-push/
// Uses fakes for the DB and APNs, and a throwaway P-256 key generated
// in-process. No network, no real .p8.

import { assert, assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";
import { composePayload, type Deps, handleRequest, secretsMatch, type TokenRow, type TurnRow } from "./handler.ts";
import { makeApnsSender, makeJwtProvider, p1363ToDer } from "./apns.ts";

const SECRET = "test-secret-123";
const READER = "00000000-0000-0000-0000-0000000000a3";
const OTHER = "00000000-0000-0000-0000-0000000000a1";
const TURN = "00000000-0000-0000-0000-000000000011";

function turn(over: Partial<TurnRow> = {}): TurnRow {
  return {
    id: TURN, event_id: "00000000-0000-0000-0000-000000000012",
    room_id: "00000000-0000-0000-0000-000000000013", reader_id: READER,
    question_text: "Would you rather know the date or the way?", kind: "interval",
    read_at: null, passed_at: null, superseded_at: null, ...over,
  };
}

function fakeDeps(over: Partial<Deps> = {}) {
  const log = { sentTo: [] as string[], deactivated: [] as string[], marked: [] as string[], tokenQueries: [] as string[] };
  const tokens: TokenRow[] = [
    { id: "t1", user_id: READER, device_token: "aa".repeat(32), environment: "sandbox" },
    { id: "t2", user_id: READER, device_token: "bb".repeat(32), environment: "production" },
    // A row for someone else that a buggy query might leak through.
    { id: "t3", user_id: OTHER, device_token: "cc".repeat(32), environment: "production" },
  ];
  const deps: Deps = {
    enabled: true,
    secret: SECRET,
    loadTurn: (id) => Promise.resolve(id === TURN ? turn() : null),
    loadTokens: (userId) => { log.tokenQueries.push(userId); return Promise.resolve(tokens); },
    deactivateTokens: (ids) => { log.deactivated.push(...ids); return Promise.resolve(); },
    markTurn: (_id, status) => { log.marked.push(status); return Promise.resolve(); },
    send: (token) => {
      log.sentTo.push(token.user_id);
      return Promise.resolve(token.id === "t2" ? { status: "bad_token", http_status: 410 } : { status: "sent" });
    },
    ...over,
  };
  return { deps, log };
}

function post(body: unknown, secret: string | null = SECRET): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (secret !== null) headers["X-Question-Push-Secret"] = secret;
  return new Request("http://localhost/", { method: "POST", headers, body: JSON.stringify(body) });
}

Deno.test("rejects missing or wrong secret (fails closed when unset)", async () => {
  const { deps, log } = fakeDeps();
  assertEquals((await handleRequest(post({ turn_id: TURN }, null), deps)).status, 401);
  assertEquals((await handleRequest(post({ turn_id: TURN }, "nope"), deps)).status, 401);
  const unset = fakeDeps({ secret: "" });
  assertEquals((await handleRequest(post({ turn_id: TURN }, ""), unset.deps)).status, 401);
  assertEquals(log.sentTo.length, 0);
});

Deno.test("disabled flag sends nothing", async () => {
  const { deps, log } = fakeDeps({ enabled: false });
  const res = await handleRequest(post({ turn_id: TURN }), deps);
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "disabled");
  assertEquals(log.sentTo.length, 0);
  assertEquals(log.tokenQueries.length, 0);
});

Deno.test("sends to the reader only, ignores body-supplied recipients, deactivates 410 tokens", async () => {
  const { deps, log } = fakeDeps();
  const res = await handleRequest(post({ turn_id: TURN, user_ids: [OTHER], reader_id: OTHER }), deps);
  const out = await res.json();
  assertEquals(res.status, 200);
  assertEquals(log.tokenQueries, [READER]);
  assert(log.sentTo.every((u) => u === READER), `sent to ${log.sentTo}`);
  assertEquals(log.sentTo.length, 2);
  assertEquals(log.deactivated, ["t2"]);
  assertEquals(out.status, "sent");
  assertEquals(out.sent, 1);
  assertEquals(log.marked, ["sent"]);
});

Deno.test("closed or superseded turns are not pushed", async () => {
  for (const over of [{ read_at: "x" }, { passed_at: "x" }, { superseded_at: "x" }]) {
    const { deps, log } = fakeDeps({ loadTurn: () => Promise.resolve(turn(over)) });
    const out = await (await handleRequest(post({ turn_id: TURN }), deps)).json();
    assertEquals(out.status, "skipped_closed");
    assertEquals(log.sentTo.length, 0);
  }
});

Deno.test("bad input and unknown turn", async () => {
  const { deps } = fakeDeps();
  assertEquals((await handleRequest(post({}), deps)).status, 400);
  assertEquals((await handleRequest(post({ turn_id: "not-a-uuid" }), deps)).status, 400);
  assertEquals((await handleRequest(post({ turn_id: "00000000-0000-0000-0000-000000000099" }), deps)).status, 404);
  assertEquals((await handleRequest(new Request("http://localhost/"), deps)).status, 405);
});

Deno.test("payload is the question, addressed to the reader card", () => {
  const p = composePayload(turn()) as { aps: { alert: { title: string; body: string } }; type: string };
  assertEquals(p.aps.alert.title, "You're asking");
  assertEquals(p.aps.alert.body, "Would you rather know the date or the way?");
  assertEquals(p.type, "question_turn");
  assert(!JSON.stringify(p).includes("author"));
});

Deno.test("secretsMatch is exact", () => {
  assert(secretsMatch("abc", "abc"));
  assert(!secretsMatch("abc", "abcd"));
  assert(!secretsMatch(null, "abc"));
  assert(!secretsMatch("", ""));
});

async function throwawayP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const pkcs8 = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const body = encodeBase64(pkcs8).match(/.{1,64}/g)!.join("\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
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
  const get = makeJwtProvider({ keyId: "KEYID12345", teamId: "37S7KT7W83", keyP8: pem, bundleId: "com.gamesroom.app" }, () => clock);
  const t1 = await get();
  const [h, p, s] = t1.split(".");
  const dec = (x: string) => JSON.parse(atob(x.replace(/-/g, "+").replace(/_/g, "/")));
  assertEquals(dec(h), { alg: "ES256", kid: "KEYID12345" });
  assertEquals(dec(p).iss, "37S7KT7W83");
  const sigDer = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/") + "==".slice(0, (4 - s.length % 4) % 4)), (c) => c.charCodeAt(0));
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" }, publicKey, derToP1363(sigDer), new TextEncoder().encode(`${h}.${p}`),
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

Deno.test("APNs sender: topic, host per environment, 410 → bad_token, 400 BadDeviceToken → bad_token", async () => {
  const { pem } = await throwawayP8();
  const calls: { url: string; headers: Record<string, string> }[] = [];
  let next = new Response("", { status: 200 });
  const fake = ((url: string, init: RequestInit) => {
    calls.push({ url, headers: init.headers as Record<string, string> });
    return Promise.resolve(next);
  }) as unknown as typeof fetch;
  const send = makeApnsSender({ keyId: "K", teamId: "37S7KT7W83", keyP8: pem, bundleId: "com.gamesroom.app" }, fake);
  const tok = (env: "sandbox" | "production"): TokenRow => ({ id: "t", user_id: READER, device_token: "ab".repeat(32), environment: env });

  assertEquals((await send(tok("sandbox"), { turn_id: TURN })).status, "sent");
  assert(calls[0].url.startsWith("https://api.sandbox.push.apple.com/3/device/"));
  assertEquals(calls[0].headers["apns-topic"], "com.gamesroom.app");
  assertEquals(calls[0].headers["apns-push-type"], "alert");

  next = new Response('{"reason":"Unregistered"}', { status: 410 });
  assertEquals((await send(tok("production"), {})).status, "bad_token");
  assert(calls[1].url.startsWith("https://api.push.apple.com/3/device/"));

  next = new Response('{"reason":"BadDeviceToken"}', { status: 400 });
  assertEquals((await send(tok("production"), {})).status, "bad_token");

  next = new Response('{"reason":"InvalidProviderToken"}', { status: 403 });
  assertEquals((await send(tok("production"), {})).status, "error");

  const unset = makeApnsSender({ keyId: "", teamId: "", keyP8: "", bundleId: "com.gamesroom.app" }, fake);
  assertEquals((await unset(tok("production"), {})).status, "error");
});
