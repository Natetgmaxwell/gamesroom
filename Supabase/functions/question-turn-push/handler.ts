// Pure request handling for question-turn-push. No network, no env:
// everything external comes in through `Deps`, so handler_test.ts can
// exercise every branch with fakes.

export interface TurnRow {
  id: string;
  event_id: string;
  room_id: string;
  reader_id: string;
  question_text: string;
  kind: string;
  read_at: string | null;
  passed_at: string | null;
  superseded_at: string | null;
}

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
  loadTurn(turnId: string): Promise<TurnRow | null>;
  loadTokens(userId: string): Promise<TokenRow[]>;
  deactivateTokens(ids: string[]): Promise<void>;
  markTurn(turnId: string, status: string): Promise<void>;
  send(token: TokenRow, payload: Record<string, unknown>): Promise<SendResult>;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** Constant-time compare so the secret can't be probed by timing. */
export function secretsMatch(provided: string | null, expected: string): boolean {
  if (!provided || !expected) return false;
  const a = new TextEncoder().encode(provided);
  const b = new TextEncoder().encode(expected);
  let diff = a.length ^ b.length;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    diff |= (a[i] ?? 0) ^ (b[i] ?? 0);
  }
  return diff === 0;
}

export function composePayload(turn: TurnRow): Record<string, unknown> {
  return {
    aps: {
      alert: { title: "You're asking", body: turn.question_text },
      sound: "default",
      "interruption-level": "time-sensitive",
      "thread-id": `question-${turn.event_id}`,
    },
    type: "question_turn",
    turn_id: turn.id,
    event_id: turn.event_id,
  };
}

export async function handleRequest(req: Request, deps: Deps): Promise<Response> {
  if (req.method !== "POST") return json(405, { error: "method not allowed" });

  // Auth gate first: an unset secret fails closed (unlike send-broadcast,
  // which skipped the check when unset).
  if (!secretsMatch(req.headers.get("X-Question-Push-Secret"), deps.secret)) {
    return json(401, { error: "invalid X-Question-Push-Secret" });
  }

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const turnId = typeof body.turn_id === "string" ? body.turn_id : "";
  if (!UUID_RE.test(turnId)) return json(400, { error: "turn_id is required" });

  if (!deps.enabled) {
    return json(200, { status: "disabled", sent: 0 });
  }

  const turn = await deps.loadTurn(turnId);
  if (!turn) return json(404, { error: "turn not found" });
  if (turn.read_at || turn.passed_at || turn.superseded_at) {
    await deps.markTurn(turn.id, "skipped_closed");
    return json(200, { status: "skipped_closed", sent: 0 });
  }

  // The ONLY recipient: the turn's reader.
  const tokens = (await deps.loadTokens(turn.reader_id))
    .filter((t) => t.user_id === turn.reader_id);
  if (tokens.length === 0) {
    await deps.markTurn(turn.id, "no_device");
    return json(200, { status: "no_device", sent: 0 });
  }

  const payload = composePayload(turn);
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
  const status = sent > 0 ? "sent" : errors.length > 0 ? "error" : "no_device";
  await deps.markTurn(turn.id, status);
  return json(200, { status, sent, bad_tokens: bad.length, errors: errors.length });
}
