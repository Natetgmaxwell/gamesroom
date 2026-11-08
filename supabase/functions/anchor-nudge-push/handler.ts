// Pure request handling for anchor-nudge-push. No network, no env:
// everything external comes in through `Deps`, so handler_test.ts can
// exercise every branch with fakes. Shape mirrors
// ../question-turn-push/handler.ts — the APNs code is shared, not copied.
//
// V0.107 Brought By section 2b: one push to ONE person, the inviter who
// brought the newcomer. The body names an event and a newcomer and nothing
// else; who receives it is read from the ledger row, so no caller can
// address the newcomer or the table.
//
// S2B step 4 (audit 01-notifications #13): the nudge is queued by the
// server and delivered inside the room's waking hours, so it never lands
// at midnight and never breaks through Focus.

import { type SendResult, secretsMatch, type TokenRow } from "../question-turn-push/handler.ts";

export type { SendResult, TokenRow };

// secretsMatch is the shared constant-time compare, imported rather than
// duplicated so the gate can never drift between the two senders.
export { secretsMatch };

/**
 * The room's own clock. It is read from rooms.time_zone (migration 108),
 * so the weekday in the copy is the weekday where the room is, and the
 * server never has to guess. The old hardcoded Australia/Brisbane is
 * gone: it was wrong for every room outside Brisbane.
 */
export const FALLBACK_TIME_ZONE = "UTC";

/**
 * Beyond this many days the copy names the date instead of the weekday.
 */
export const WITHIN_WEEKDAY_DAYS = 6;

/**
 * A nudge in one of these states has already had its one turn. The
 * ledger's primary key stops a second queue; these stop a second send.
 */
export const TERMINAL_STATUSES = new Set([
  "sent",
  "failed",
  "no_device",
  "skipped_started",
  "skipped_seated",
  "expired",
]);

export interface NudgeRow {
  event_id: string;
  newcomer_user_id: string;
  inviter_user_id: string;
  room_id: string;
  created_at: string;
  push_status: string | null;
}

export interface EventRow {
  id: string;
  room_id: string;
  played_at: string;
}

export interface Deps {
  enabled: boolean;
  secret: string;
  /** Wall clock, a dep so the copy and the started-event guard are testable. */
  now(): Date;
  loadNudge(eventId: string, newcomerUserId: string): Promise<NudgeRow | null>;
  loadEvent(eventId: string): Promise<EventRow | null>;
  loadDisplayName(userId: string): Promise<string | null>;
  loadTokens(userId: string): Promise<TokenRow[]>;
  deactivateTokens(ids: string[]): Promise<void>;
  markNudge(eventId: string, newcomerUserId: string, status: string): Promise<void>;
  /**
   * Take the row for this send. The server posts a queued row from the
   * trigger (inside the waking hours) and from the cron (for the rows
   * queued outside them), and both can be in flight at once, so the row
   * is claimed with a conditional UPDATE. True when this request won it.
   */
  claimNudge(eventId: string, newcomerUserId: string): Promise<boolean>;
  /** The room's zone, rooms.time_zone. null when the room cannot be read. */
  loadRoomTimeZone(roomId: string): Promise<string | null>;
  /** The RSVP state of one member for one event, null when there is no row. */
  loadRsvpState(eventId: string, userId: string): Promise<string | null>;
  send(token: TokenRow, payload: Record<string, unknown>): Promise<SendResult>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Calendar date in the room's zone as [y, m, d]; no clock time, no offset. */
function zonedParts(date: Date, timeZone: string): [number, number, number] {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
  const [y, m, d] = parts.split("-").map(Number);
  return [y, m, d];
}

/**
 * The room's zone if it is one the runtime knows, UTC otherwise. A zone
 * that cannot be read must not become a wrong weekday, and it must not
 * become Australia/Brisbane either: UTC is the honest fallback.
 */
export function zoneOrFallback(zone: string | null | undefined): string {
  if (!zone) return FALLBACK_TIME_ZONE;
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: zone });
    return zone;
  } catch {
    return FALLBACK_TIME_ZONE;
  }
}

/**
 * Whole days between two instants as the room counts them: the two dates are
 * read in the room's zone and differenced as plain calendar days, so a
 * 23:30 Thursday event reads as six days out on Thursday evening and
 * something after 00:00 crosses over at local midnight, not at UTC midnight.
 */
export function calendarDaysBetween(from: Date, to: Date, timeZone: string): number {
  const [fy, fm, fd] = zonedParts(from, timeZone);
  const [ty, tm, td] = zonedParts(to, timeZone);
  return Math.round(
    (Date.UTC(ty, tm - 1, td) - Date.UTC(fy, fm - 1, fd)) / 86_400_000,
  );
}

/**
 * The spec line, in the room's zone:
 *   "<Name>'s coming <Weekday>. Are you?"  within six days
 *   "<Name>'s coming on <d MMM>. Are you?"  further out
 * A date before now (the event already started — the caller refuses to send
 * those, this is the second line of defence) takes the date form.
 */
export function composeAnchorCopy(
  newcomerName: string,
  playedAt: Date,
  now: Date,
  timeZone: string,
): string {
  const name = newcomerName.trim() || "Someone";
  const days = calendarDaysBetween(now, playedAt, timeZone);
  if (days >= 0 && days <= WITHIN_WEEKDAY_DAYS) {
    const weekday = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "long" })
      .format(playedAt);
    return `${name}'s coming ${weekday}. Are you?`;
  }
  const when = new Intl.DateTimeFormat("en-GB", { timeZone, day: "numeric", month: "short" })
    .format(playedAt);
  return `${name}'s coming on ${when}. Are you?`;
}

/**
 * The alert. `room_id` and `event_id` ride along so the app can route the
 * tap to this event in this room (spec 2b: tap opens the event with Claim
 * seat as the one action). The newcomer's name travels only inside the copy
 * the inviter is meant to read.
 *
 * The interruption level is "active", not "time-sensitive" (audit
 * 01-notifications #13): the nudge asks the inviter to claim a seat for a
 * night that is days away. It is not urgent, so it must not break through
 * a Focus mode the inviter chose.
 */
export function composePayload(nudge: NudgeRow, body: string): Record<string, unknown> {
  return {
    aps: {
      alert: { title: "Someone you brought is coming", body },
      sound: "default",
      "interruption-level": "active",
      "thread-id": `anchor-${nudge.event_id}`,
    },
    type: "anchor_nudge",
    event_id: nudge.event_id,
    room_id: nudge.room_id,
  };
}

/**
 * The rules re-checked here are the ones that can change between the
 * queue and the send: the event has not started (A12), and the inviter
 * is still not seated (audit #13). Membership, the two notification
 * switches, "the inviter is not already seated" at queue time and
 * "first three nights" are all decided by queue_anchor_nudge (migrations
 * 105 and 110) and are true of the ledger row by construction — this
 * function never re-implements them, only ever narrows what SQL allowed.
 */
export async function handleRequest(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  // Auth gate first: an unset secret fails closed.
  if (!secretsMatch(req.headers.get("X-Anchor-Push-Secret"), deps.secret)) {
    return json(401, { error: "invalid X-Anchor-Push-Secret" });
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const eventId = typeof body.event_id === "string" ? body.event_id : "";
  const newcomerId = typeof body.newcomer_user_id === "string" ? body.newcomer_user_id : "";
  if (!UUID_RE.test(eventId) || !UUID_RE.test(newcomerId)) {
    return json(400, { error: "event_id and newcomer_user_id are required" });
  }

  // The disabled check comes before the claim: a function that is off
  // must not take the row, or the nudge is lost for good.
  if (!deps.enabled) {
    return json(200, { status: "disabled", sent: 0 });
  }

  const nudge = await deps.loadNudge(eventId, newcomerId);
  if (!nudge) return json(404, { error: "anchor nudge not found" });
  // Once is once (A11). The ledger's primary key already stops a second
  // queue; this stops a duplicate delivery of the same post.
  if (nudge.push_status && TERMINAL_STATUSES.has(nudge.push_status)) {
    const status = nudge.push_status === "sent" ? "already_sent" : nudge.push_status;
    return json(200, { status, sent: 0 });
  }

  // Claim the row before anything else happens to it. The trigger posts
  // inside the waking hours and the cron posts the rows that were queued
  // outside them, so the same row can be in flight twice; only the
  // request that wins the claim may send it.
  const claimed = await deps.claimNudge(eventId, newcomerId);
  if (!claimed) {
    return json(200, { status: "already_claimed", sent: 0 });
  }

  const event = await deps.loadEvent(eventId);
  if (!event) {
    await deps.markNudge(eventId, newcomerId, "failed");
    return json(404, { error: "event not found" });
  }

  const now = deps.now();
  const playedAt = new Date(event.played_at);
  if (Number.isNaN(playedAt.getTime())) {
    await deps.markNudge(eventId, newcomerId, "failed");
    return json(400, { error: "event played_at is unreadable" });
  }

  // Never once the event has started (A12). queue_anchor_nudge checks this
  // too, but pg_net delivers asynchronously, so the event can start in
  // between the queue and the send.
  if (playedAt.getTime() <= now.getTime()) {
    await deps.markNudge(eventId, newcomerId, "skipped_started");
    return json(200, { status: "skipped_started", sent: 0 });
  }

  // The inviter may have claimed a seat since the nudge was queued, in
  // which case they are coming anyway and the nudge is noise (audit
  // 01-notifications #13). Re-read the seat at send time.
  const seat = await deps.loadRsvpState(eventId, nudge.inviter_user_id);
  if (seat === "claimed") {
    await deps.markNudge(eventId, newcomerId, "skipped_seated");
    return json(200, { status: "skipped_seated", sent: 0 });
  }

  // The ONLY recipient: the inviter. Body-supplied ids are ignored, and the
  // token query is filtered anyway.
  const tokens = (await deps.loadTokens(nudge.inviter_user_id))
    .filter((t) => t.user_id === nudge.inviter_user_id);
  if (tokens.length === 0) {
    await deps.markNudge(eventId, newcomerId, "no_device");
    return json(200, { status: "no_device", sent: 0 });
  }

  const name = (await deps.loadDisplayName(nudge.newcomer_user_id)) ?? "Someone";
  const timeZone = zoneOrFallback(await deps.loadRoomTimeZone(nudge.room_id));
  const payload = composePayload(nudge, composeAnchorCopy(name, playedAt, now, timeZone));
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
  await deps.markNudge(eventId, newcomerId, status);
  return json(200, { status, sent, bad_tokens: bad.length, errors: errors.length });
}
