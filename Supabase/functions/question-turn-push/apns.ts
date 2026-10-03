// APNs provider-token auth + HTTP/2 send. Ported from Felt Faction's
// send-broadcast (same team, same key style): ES256 JWT cached ~50 min,
// P1363 → DER signature conversion, 410 → bad_token.

import { encodeBase64 } from "https://deno.land/std@0.224.0/encoding/base64.ts";
import type { SendResult, TokenRow } from "./handler.ts";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  keyP8: string;
  bundleId: string;
}

const JWT_TTL_MS = 50 * 60 * 1000;

function b64url(bytes: Uint8Array): string {
  return encodeBase64(bytes).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

/** ECDSA P1363 (r||s, 64 bytes) → ASN.1 DER, as in send-broadcast. */
export function p1363ToDer(p1363: Uint8Array): Uint8Array {
  if (p1363.length !== 64) throw new Error(`p1363ToDer: expected 64 bytes, got ${p1363.length}`);
  const encodeInt = (n: Uint8Array): Uint8Array => {
    let i = 0;
    while (i < n.length - 1 && n[i] === 0) i++;
    let trimmed = n.slice(i);
    if (trimmed[0] & 0x80) {
      const padded = new Uint8Array(trimmed.length + 1);
      padded.set(trimmed, 1);
      trimmed = padded;
    }
    return new Uint8Array([0x02, trimmed.length, ...trimmed]);
  };
  const r = encodeInt(p1363.slice(0, 32));
  const s = encodeInt(p1363.slice(32));
  return new Uint8Array([0x30, r.length + s.length, ...r, ...s]);
}

export function makeJwtProvider(cfg: ApnsConfig, now: () => number = Date.now) {
  let cache: { token: string; expiresAt: number } | null = null;
  return async function getJwt(): Promise<string> {
    if (cache && cache.expiresAt > now()) return cache.token;
    const pem = cfg.keyP8.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
    const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
    const key = await crypto.subtle.importKey(
      "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
    );
    const enc = (o: object) => b64url(new TextEncoder().encode(JSON.stringify(o)));
    const input = `${enc({ alg: "ES256", kid: cfg.keyId })}.${enc({ iss: cfg.teamId, iat: Math.floor(now() / 1000) })}`;
    const sig = new Uint8Array(
      await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input)),
    );
    const token = `${input}.${b64url(p1363ToDer(sig))}`;
    cache = { token, expiresAt: now() + JWT_TTL_MS };
    return token;
  };
}

export function makeApnsSender(
  cfg: ApnsConfig,
  fetchImpl: typeof fetch = fetch,
  getJwt = makeJwtProvider(cfg),
) {
  return async function send(token: TokenRow, payload: Record<string, unknown>): Promise<SendResult> {
    if (!cfg.keyId || !cfg.teamId || !cfg.keyP8) {
      return { status: "error", reason: "APNS_* secrets not set" };
    }
    const host = token.environment === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";
    const res = await fetchImpl(`https://${host}/3/device/${token.device_token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await getJwt()}`,
        "apns-topic": cfg.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        // A question is stale after ~10 min; don't deliver it late.
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 600),
        "apns-collapse-id": String(payload.turn_id ?? "").slice(0, 64),
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (res.status === 200) return { status: "sent", http_status: 200 };
    const text = await res.text().catch(() => "");
    // 410 Unregistered and 400 BadDeviceToken both mean "this token is dead".
    if (res.status === 410 || (res.status === 400 && text.includes("BadDeviceToken"))) {
      return { status: "bad_token", http_status: res.status, reason: text };
    }
    return { status: "error", http_status: res.status, reason: `APNs ${res.status}: ${text}` };
  };
}
