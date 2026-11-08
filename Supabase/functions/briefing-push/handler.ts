// handler.ts — the request handling for briefing-push.
//
// Pure in the same sense as plan.ts: no env, no network, no database.
// Everything external arrives through `Deps`, so handler_test.ts can
// exercise every branch with fakes.
//
// The caller is the pg_net cron in migration 109. It posts
//   {"rows": [ {event_id, room_id, user_id, kind, rsvp_state,
//               event_name, played_at, host_note, time_zone,
//               mascot_name}, ... ]}
// with the shared secret in the X-Briefing-Push-Secret header.
//
// The rows are trusted because the caller holds the secret: every
// eligibility rule was applied by public.briefing_push_due before the
// payload was built. This function never widens the audience of a row
// and never sends to anyone but the user_id the row names.
//
// The once-per-slot rule lives in the database: the ledger row is
// written BEFORE the send, so a repeated tick finds the slot spent and
// does nothing.

import {
  composePayload,
  type BriefingRow,
  type Headcount,
  planPush,
} from "./plan.ts";

export interface TokenRow {
  id: string;
  user_id: string;
  device_token: string;
  environment: "production" | "sandbox";
}

export interface SendResult {
  status: "sent" | "bad_token" | "error";
  http_status?: number;
  reason?: string;
}

export interface Deps {
  enabled: boolean;
  secret: string;
  loadTokens(userId: string): Promise<TokenRow[]>;
  /**
   * Writes the ledger row for the slot. Returns false when the slot was
   * already spent (the primary key rejected the insert), which means
   * this row must not be sent again.
   */
  claimSlot(row: BriefingRow): Promise<boolean>;
  deactivateTokens(ids: string[]): Promise<void>;
  loadHeadcount(eventId: string, roomId: string): Promise<Headcount>;
  send(token: TokenRow, payload: Record<string, unknown>): Promise<SendResult>;
}

/** The cron batches 200 rows. This is the ceiling, generously above it. */
const MAX_ROWS = 1000;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Constant-time compare so the secret can't be probed by timing. */
export function secretsMatch(
  provided: string | null,
  expected: string,
): boolean {
  if (!provided || !expected) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

/**
 * Reads one row out of the payload. A row that is not shaped like a due
 * slot is dropped, not guessed at: a half-formed row would be a push
 * with the wrong date or the wrong recipient in it.
 */
export function parseRow(raw: unknown): BriefingRow | null {
  if (typeof raw !== "object" || raw === null) return null;
  const r = raw as Record<string, unknown>;
  const text = (key: string) => (typeof r[key] === "string" ? r[key] : "");
  const event_id = text("event_id");
  const room_id = text("room_id");
  const user_id = text("user_id");
  if (!UUID_RE.test(event_id)) return null;
  if (!UUID_RE.test(room_id)) return null;
  if (!UUID_RE.test(user_id)) return null;
  const kind = text("kind");
  if (!kind) return null;
  const played_at = text("played_at");
  if (!played_at || Number.isNaN(new Date(played_at).getTime())) return null;
  return {
    event_id,
    room_id,
    user_id,
    kind,
    rsvp_state: text("rsvp_state") || "unclaimed",
    event_name: text("event_name"),
    played_at,
    host_note: typeof r.host_note === "string" ? r.host_note : null,
    time_zone: text("time_zone"),
    mascot_name: text("mascot_name"),
  };
}

export async function handleRequest(
  req: Request,
  deps: Deps,
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: "method not allowed" });
  }

  // Auth gate first: an unset secret fails closed. The secret is the
  // only thing standing between the internet and a push, because the
  // function is deployed with --no-verify-jwt.
  if (
    !secretsMatch(
      req.headers.get("X-Briefing-Push-Secret"),
      deps.secret,
    )
  ) {
    return json(401, { error: "invalid X-Briefing-Push-Secret" });
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const rawRows = Array.isArray(body.rows) ? body.rows : null;
  if (!rawRows) return json(400, { error: "rows is required" });
  if (rawRows.length > MAX_ROWS) {
    return json(400, { error: `too many rows (max ${MAX_ROWS})` });
  }

  // The feature ships off. Nothing is read, nothing is written, nothing
  // is sent: the ledger stays untouched, so the slots stay due for the
  // day the flag is turned on.
  if (!deps.enabled) {
    return json(200, {
      status: "disabled",
      sent: 0,
      rows: rawRows.length,
    });
  }

  const headcounts = new Map<string, Headcount>();
  const badTokens: string[] = [];
  let sent = 0;
  let pushed = 0;
  let skipped = 0;
  let duplicates = 0;
  let errors = 0;

  for (const raw of rawRows) {
    const row = parseRow(raw);
    if (!row) {
      skipped++;
      continue;
    }

    let tokens: TokenRow[];
    try {
      tokens = (await deps.loadTokens(row.user_id)).filter(
        (t) => t.user_id === row.user_id,
      );
    } catch {
      errors++;
      continue;
    }
    // Nowhere to send it. The slot is NOT spent: a member who registers
    // a token in the next few minutes still gets the push.
    if (tokens.length === 0) {
      skipped++;
      continue;
    }

    let headcount: Headcount | null = null;
    if (row.kind === "host_headcount") {
      const cached = headcounts.get(row.event_id);
      headcount = cached ?? await deps.loadHeadcount(
        row.event_id,
        row.room_id,
      );
      headcounts.set(row.event_id, headcount);
    }

    const plan = planPush(row, headcount);
    if (!plan) {
      skipped++;
      continue;
    }

    // The ledger row goes in before the send. Once it is written the
    // slot is spent, so a repeated tick finds it and does nothing.
    let claimed: boolean;
    try {
      claimed = await deps.claimSlot(row);
    } catch {
      // No ledger row means no send: sending first and writing the row
      // after would let the next tick push the same slot again.
      errors++;
      continue;
    }
    if (!claimed) {
      duplicates++;
      continue;
    }

    pushed++;
    const payload = composePayload(plan);
    for (const token of tokens) {
      try {
        const result = await deps.send(token, payload);
        if (result.status === "sent") sent++;
        else if (result.status === "bad_token") badTokens.push(token.id);
        else errors++;
      } catch {
        errors++;
      }
    }
  }

  await deps.deactivateTokens(badTokens);

  const status = sent > 0 ? "sent" : errors > 0 ? "error" : "skipped";
  return json(200, {
    status,
    sent,
    rows: rawRows.length,
    pushed,
    skipped,
    duplicates,
    bad_tokens: badTokens.length,
    errors,
  });
}
