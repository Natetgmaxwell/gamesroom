// Pure request handling for glad-push. No network, no env: everything
// external comes in through `Deps`, so handler_test.ts can exercise every
// branch with fakes. Shape mirrors ../anchor-nudge-push/handler.ts.
//
// 1.2.5 Task 4, "Glad you came": ONE push to ONE person, the recipient,
// once per night, batched over everyone who told them:
//   "Connor was glad you came."
//   "Connor and Sam were glad you came."
//   "Connor, Sam and 2 others were glad you came."
//
// Privacy: the body names a night and a recipient and nothing else. The
// senders are read here, on the service role, and only ever reach the one
// person they were addressed to. Nothing is counted, stored or returned
// beyond the send status.

import { type SendResult, secretsMatch, type TokenRow } from "../question-turn-push/handler.ts";

export type { SendResult, TokenRow };
export { secretsMatch };

export const FALLBACK_TIME_ZONE = "UTC";

/** No push may land between 22:00 and 08:00 in the room's zone. */
export const QUIET_FROM_HOUR = 22;
export const QUIET_UNTIL_HOUR = 8;

export const TERMINAL_STATUSES = new Set([
  "sent",
  "failed",
  "no_device",
  "skipped_muted",
  "expired",
]);

export interface QueueRow {
  event_id: string;
  to_user: string;
  room_id: string;
  deliver_at: string;
  push_status: string | null;
}

export interface Deps {
  enabled: boolean;
  secret: string;
  now(): Date;
  loadQueueRow(eventId: string, toUser: string): Promise<QueueRow | null>;
  /** queued -> sending, conditionally. True when this request won the row. */
  claimQueueRow(eventId: string, toUser: string): Promise<boolean>;
  markQueueRow(eventId: string, toUser: string, status: string): Promise<void>;
  /** The senders' user ids for (night, recipient), earliest note first. */
  loadSenderIds(eventId: string, toUser: string): Promise<string[]>;
  loadDisplayName(userId: string): Promise<string | null>;
  loadRoomTimeZone(roomId: string): Promise<string | null>;
  loadTokens(userId: string): Promise<TokenRow[]>;
  deactivateTokens(ids: string[]): Promise<void>;
  send(token: TokenRow, payload: Record<string, unknown>): Promise<SendResult>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

export function zoneOrFallback(zone: string | null | undefined): string {
  if (!zone) return FALLBACK_TIME_ZONE;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return zone;
  } catch {
    return FALLBACK_TIME_ZONE;
  }
}

/** The hour (0-23) on the room's clock. */
export function localHour(date: Date, timeZone: string): number {
  const h = new Intl.DateTimeFormat("en-GB", { timeZone, hour: "2-digit", hourCycle: "h23" })
    .format(date);
  return Number(h) % 24;
}

export function isQuietHour(date: Date, timeZone: string): boolean {
  const h = localHour(date, timeZone);
  return h >= QUIET_FROM_HOUR || h < QUIET_UNTIL_HOUR;
}

/**
 * The batched sentence. Twin of GladYouCame.line(senderNames:) in
 * GamesRoom/Models/GladYouCame.swift; both are pinned by the same table
 * (TestsGladYouCame.swift and handler_test.ts).
 */
export function composeGladCopy(senderNames: string[]): string | null {
  const names = senderNames.map((n) => n.trim()).filter((n) => n.length > 0);
  if (names.length === 0) return null;
  if (names.length === 1) return `${names[0]} was glad you came.`;
  if (names.length <= 3) {
    return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]} were glad you came.`;
  }
  const rest = names.length - 2;
  return `${names[0]}, ${names[1]} and ${rest} ${rest === 1 ? "other" : "others"} were glad you came.`;
}

/**
 * The alert. "active", not "time-sensitive": it is good news, not urgent,
 * and must not break through a Focus mode. No sound: quiet by default.
 */
export function composePayload(row: QueueRow, body: string): Record<string, unknown> {
  return {
    aps: {
      alert: { body },
      "interruption-level": "active",
      "thread-id": `glad-${row.event_id}`,
    },
    type: "glad_you_came",
    event_id: row.event_id,
    room_id: row.room_id,
  };
}

export async function handleRequest(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  if (!secretsMatch(req.headers.get("X-Glad-Push-Secret"), deps.secret)) {
    return json(401, { error: "invalid X-Glad-Push-Secret" });
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const eventId = typeof body.event_id === "string" ? body.event_id : "";
  const toUser = typeof body.to_user === "string" ? body.to_user : "";
  if (!UUID_RE.test(eventId) || !UUID_RE.test(toUser)) {
    return json(400, { error: "event_id and to_user are required" });
  }

  // Off means off, and it must not take the row.
  if (!deps.enabled) return json(200, { status: "disabled", sent: 0 });

  const row = await deps.loadQueueRow(eventId, toUser);
  if (!row) return json(404, { error: "glad push not found" });
  if (row.push_status && TERMINAL_STATUSES.has(row.push_status)) {
    const status = row.push_status === "sent" ? "already_sent" : row.push_status;
    return json(200, { status, sent: 0 });
  }

  const now = deps.now();
  // Not before its hour, whatever posted it.
  const deliverAt = new Date(row.deliver_at);
  if (Number.isNaN(deliverAt.getTime()) || deliverAt.getTime() > now.getTime()) {
    return json(200, { status: "not_due", sent: 0 });
  }

  // Never 22:00-08:00 on the room's clock. The tick checks this too; this
  // is the line that holds if the post sat in pg_net past 22:00. The row is
  // left queued so the morning tick delivers it.
  const timeZone = zoneOrFallback(await deps.loadRoomTimeZone(row.room_id));
  if (isQuietHour(now, timeZone)) {
    return json(200, { status: "quiet_hours", sent: 0 });
  }

  if (!(await deps.claimQueueRow(eventId, toUser))) {
    return json(200, { status: "already_claimed", sent: 0 });
  }

  // Everyone who told this one person about this one night. The recipient
  // is the row's, never the body's.
  const senderIds = (await deps.loadSenderIds(eventId, row.to_user))
    .filter((id) => id !== row.to_user);
  const names: string[] = [];
  for (const id of senderIds) {
    const name = await deps.loadDisplayName(id);
    if (name && name.trim()) names.push(name);
  }
  const copy = composeGladCopy(names);
  if (!copy) {
    await deps.markQueueRow(eventId, toUser, "failed");
    return json(200, { status: "no_senders", sent: 0 });
  }

  const tokens = (await deps.loadTokens(row.to_user)).filter((t) => t.user_id === row.to_user);
  if (tokens.length === 0) {
    await deps.markQueueRow(eventId, toUser, "no_device");
    return json(200, { status: "no_device", sent: 0 });
  }

  const payload = composePayload(row, copy);
  let sent = 0;
  const bad: string[] = [];
  const errors: string[] = [];
  for (const token of tokens) {
    try {
      const r = await deps.send(token, payload);
      if (r.status === "sent") sent++;
      else if (r.status === "bad_token") bad.push(token.id);
      else errors.push(r.reason ?? `APNs ${r.http_status}`);
    } catch (e) {
      errors.push((e as Error).message);
    }
  }
  await deps.deactivateTokens(bad);
  const status = sent > 0 ? "sent" : "failed";
  await deps.markQueueRow(eventId, toUser, status);
  return json(200, { status, sent, bad_tokens: bad.length, errors: errors.length });
}
