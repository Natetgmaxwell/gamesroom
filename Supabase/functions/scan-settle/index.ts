// scan-settle — V0.72 slice 2.
//
// Contract: docs/loop-artifacts/V0.72_HOSTED_VISION_SETTLE_SPEC.md (Slices §2).
//
// Authoritative chip / black-card counting. The member app POSTs the
// captured JPEG here; the hosted vision model's count is final and is
// recorded server-side via service role (record_member_scan /
// record_cah_tally with p_member_id, migration 069). Photo bytes are
// hashed (SHA-256) and discarded — never logged, never stored.
//
// Auth: Supabase member JWT. POST { kind: "chips"|"cards", event_id,
// image_base64 (raw base64 JPEG, or a data:image/jpeg;base64,... URL) }.

import { createClient } from "jsr:@supabase/supabase-js@2";

const MAX_BODY_BYTES = 8 * 1024 * 1024;
const MAX_ATTEMPTS_PER_EVENT = 5;
const MINIMAX_URL = "https://api.minimax.io/v1/chat/completions";

const CHIP_FALLBACK_VALUES: Record<string, number> = {
  red: 5,
  blue: 10,
  green: 25,
  black: 100,
  white: 1,
};

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

interface ChipStack {
  color: string;
  count: number;
}

interface ParsedChips {
  stacks: ChipStack[];
  total_points: number;
  declined?: string;
}

interface ParsedCards {
  count: number;
  declined?: string;
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

const DECLINE_PATTERNS = [
  "cannot",
  "can't",
  "unable",
  "not able",
  "no chips",
  "no cards",
  "don't see",
  "do not see",
  "couldn't",
  "could not",
  "unclear",
  "blurry",
  "apolog",
  "sorry",
];

function looksLikeDecline(text: string): boolean {
  const lower = text.toLowerCase();
  return DECLINE_PATTERNS.some((p) => lower.includes(p));
}

function extractJsonObject(text: string): unknown | null {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/);
  const candidate = fenced ? fenced[1] : text;
  const start = candidate.indexOf("{");
  const end = candidate.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;
  try {
    return JSON.parse(candidate.slice(start, end + 1));
  } catch {
    return null;
  }
}

function parseChips(raw: unknown): ParsedChips {
  const obj = extractJsonObject(
    typeof raw === "string" ? raw : JSON.stringify(raw),
  );
  if (!obj || typeof obj !== "object") {
    return { stacks: [], total_points: 0, declined: "unparseable_response" };
  }
  const o = obj as Record<string, unknown>;
  const stacksRaw = o.stacks;
  if (!Array.isArray(stacksRaw)) {
    return { stacks: [], total_points: 0, declined: "unparseable_response" };
  }
  const stacks: ChipStack[] = [];
  for (const s of stacksRaw) {
    if (!s || typeof s !== "object") continue;
    const color = String((s as Record<string, unknown>).color ?? "").trim()
      .toLowerCase();
    const count = Number((s as Record<string, unknown>).count);
    if (!color || !Number.isInteger(count) || count < 0 || count > 500) {
      continue;
    }
    stacks.push({ color, count });
  }
  if (stacks.length === 0) {
    return { stacks: [], total_points: 0, declined: "unparseable_response" };
  }
  const total = Number(o.total_points);
  if (!Number.isInteger(total) || total < 0) {
    return { stacks: [], total_points: 0, declined: "unparseable_response" };
  }
  return { stacks, total_points: total };
}

function parseCards(raw: unknown): ParsedCards {
  const obj = extractJsonObject(
    typeof raw === "string" ? raw : JSON.stringify(raw),
  );
  if (!obj || typeof obj !== "object") {
    return { count: 0, declined: "unparseable_response" };
  }
  const count = Number((obj as Record<string, unknown>).count);
  if (!Number.isInteger(count) || count < 0 || count > 200) {
    return { count: 0, declined: "unparseable_response" };
  }
  return { count };
}

async function callMiniMax(
  apiKey: string,
  model: string,
  prompt: string,
  imageDataUrl: string,
): Promise<{ ok: true; content: string } | { ok: false; reason: string }> {
  const payload = {
    model,
    messages: [
      {
        role: "user",
        content: [
          { type: "text", text: prompt },
          { type: "image_url", image_url: { url: imageDataUrl } },
        ],
      },
    ],
    temperature: 0,
    max_completion_tokens: 2048,
    thinking: { type: "disabled" },
  };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 55_000);
  try {
    const res = await fetch(MINIMAX_URL, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    });
    if (!res.ok) {
      return { ok: false, reason: `minimax_http_${res.status}` };
    }
    const data = await res.json();
    const content =
      data?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.length === 0) {
      return { ok: false, reason: "empty_model_response" };
    }
    return { ok: true, content };
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") {
      return { ok: false, reason: "minimax_timeout" };
    }
    return { ok: false, reason: "minimax_unreachable" };
  } finally {
    clearTimeout(timer);
  }
}

function chipPrompt(valueMap: Record<string, number>): string {
  const mapLines = Object.entries(valueMap)
    .map(([c, v]) => `  "${c}": ${v}`)
    .join("\n");
  return [
    "You are a precise table-top counting assistant.",
    "The photo shows poker chips on a table, possibly in stacks.",
    "Count the chips by color. Use the room's chip value map:",
    "{",
    mapLines,
    "}",
    "Rules:",
    '- Reply with ONLY a JSON object: {"stacks":[{"color":"<color>","count":<int>}], "total_points":<int>}.',
    "- color must be lowercase and match a key from the value map (e.g. \"red\").",
    "- total_points = sum(count x value) across all stacks.",
    "- Include every chip you can see. If a stack's color is ambiguous, use your best single judgment.",
    "If you genuinely cannot see any chips in the photo, reply with {\"declined\":\"reason\"}.",
  ].join("\n");
}

const CARD_PROMPT = [
  "You are a precise table-top counting assistant.",
  "The photo shows playing cards on a table.",
  "Count ONLY the black-suited cards (spades and clubs). Ignore red-suited cards (hearts, diamonds) and jokers.",
  'Reply with ONLY a JSON object: {"count":<int>}.',
  "If you genuinely cannot see any cards in the photo, reply with {\"declined\":\"reason\"}.",
].join("\n");

function normalizeBase64(input: string): { b64: string } | { error: string } {
  let b64 = input.trim();
  const marker = "base64,";
  const idx = b64.indexOf(marker);
  if (b64.startsWith("data:") && idx !== -1) {
    b64 = b64.slice(idx + marker.length);
  }
  if (b64.length < 100) return { error: "image_too_small" };
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64.slice(0, 1024))) {
    return { error: "image_not_base64" };
  }
  return { b64 };
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes as BufferSource);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.startsWith("Bearer ")
    ? authHeader.slice(7)
    : "";

  // Validate the JWT against the project's auth server. A forged or
  // anon-token is rejected before any body parsing. (Direct fetch, not
  // supabase-js: auth.getUser() with no stored session ignores the
  // global Authorization header.)
  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  let memberId: string;
  try {
    const authRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: Deno.env.get("SUPABASE_ANON_KEY")!,
      },
    });
    if (!authRes.ok) {
      return json({ error: "unauthorized" }, 401);
    }
    const user = await authRes.json();
    if (!user?.id) {
      return json({ error: "unauthorized" }, 401);
    }
    memberId = user.id;
  } catch {
    return json({ error: "unauthorized" }, 401);
  }

  const apiKey = Deno.env.get("MINIMAX_API_KEY");
  const model = Deno.env.get("MINIMAX_VISION_MODEL") ?? "MiniMax-M3";
  if (!apiKey) {
    return json({ error: "vision_service_not_configured" }, 503);
  }

  const contentType = req.headers.get("Content-Type") ?? "";
  if (!contentType.includes("application/json")) {
    return json({ error: "unsupported_media_type" }, 415);
  }

  let body: {
    kind?: string;
    event_id?: string;
    image_base64?: string;
  };
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) {
      return json({ error: "payload_too_large" }, 413);
    }
    body = JSON.parse(raw);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const kind = body.kind;
  if (kind !== "chips" && kind !== "cards") {
    return json(
      { error: "invalid_kind", detail: 'kind must be "chips" or "cards"' },
      400,
    );
  }
  const eventId = (body.event_id ?? "").trim();
  if (!/^[0-9a-f-]{36}$/i.test(eventId)) {
    return json({ error: "invalid_event_id" }, 400);
  }
  if (typeof body.image_base64 !== "string") {
    return json({ error: "missing_image" }, 400);
  }
  const normalized = normalizeBase64(body.image_base64);
  if ("error" in normalized) {
    return json({ error: normalized.error }, 400);
  }

  // Decode once for hashing; the base64 string and bytes are dropped at
  // the end of this scope — nothing downstream sees the image.
  const imageBytes = Uint8Array.from(atob(normalized.b64), (c) =>
    c.charCodeAt(0)
  );
  const photoHash = await sha256Hex(imageBytes);
  const dataUrl = `data:image/jpeg;base64,${normalized.b64}`;

  const serviceClient = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Room + member checks, chip value map.
  const { data: eventRow, error: eventError } = await serviceClient
    .from("events")
    .select("id, room_id, pack_slug")
    .eq("id", eventId)
    .single();
  if (eventError || !eventRow) {
    return json({ error: "event_not_found" }, 404);
  }
  const roomId = eventRow.room_id as string;

  const { data: membership } = await serviceClient
    .from("room_memberships")
    .select("user_id")
    .eq("room_id", roomId)
    .eq("user_id", memberId)
    .maybeSingle();
  if (!membership) {
    return json({ error: "not_a_member" }, 403);
  }

  // Rate limit: >5 attempts per member per event.
  const { count: attemptCount } = await serviceClient
    .from("scan_attempts")
    .select("id", { count: "exact", head: true })
    .eq("event_id", eventId)
    .eq("member_id", memberId);
  const used = attemptCount ?? 0;
  if (used >= MAX_ATTEMPTS_PER_EVENT) {
    return json(
      {
        error: "rate_limited",
        attempts_used: used,
        attempts_remaining: 0,
      },
      429,
    );
  }

  // Chips: fetch the room's value map server-side.
  let chipValueMap: Record<string, number> = { ...CHIP_FALLBACK_VALUES };
  if (kind === "chips") {
    const { data: cfg } = await serviceClient
      .from("casino_room_config")
      .select("chip_color_map, standard_presets")
      .eq("room_id", roomId)
      .maybeSingle();
    const stored = cfg?.chip_color_map;
    if (cfg && cfg.standard_presets !== true && stored &&
      typeof stored === "object" && Object.keys(stored).length > 0
    ) {
      const merged: Record<string, number> = { ...CHIP_FALLBACK_VALUES };
      for (const [k, v] of Object.entries(stored)) {
        const n = Number(v);
        if (Number.isInteger(n) && n >= 0) merged[k.toLowerCase()] = n;
      }
      chipValueMap = merged;
    }
  }

  const prompt = kind === "chips" ? chipPrompt(chipValueMap) : CARD_PROMPT;
  const mm = await callMiniMax(apiKey, model, prompt, dataUrl);
  // Bytes are gone from here on — only the hash and model output travel.
  const imageRefForLog = photoHash.slice(0, 12);

  if (!mm.ok) {
    return json({ error: "vision_failed", reason: mm.reason }, 502);
  }

  let declined: string | undefined;
  if (looksLikeDecline(mm.content)) {
    const obj = extractJsonObject(mm.content);
    const d = obj && typeof obj === "object"
      ? (obj as Record<string, unknown>).declined
      : undefined;
    declined = typeof d === "string" ? d : "model_declined";
  }

  if (kind === "chips") {
    if (declined) {
      return json(
        { error: "model_declined", reason: declined },
        422,
      );
    }
    const parsed = parseChips(mm.content);
    if (parsed.declined) {
      return json({ error: parsed.declined, reason: "unparseable_response" }, 422);
    }

    const snapshot = {
      source: "hosted",
      model,
      stacks: parsed.stacks,
      photo_hash: photoHash,
      prompt_kind: "chips",
    };

    const { error: rpcError } = await serviceClient.rpc("record_member_scan", {
      p_session_id: eventId,
      p_vision_amount_points: parsed.total_points,
      p_vision_snapshot: snapshot,
      p_member_id: memberId,
    });
    if (rpcError) {
      return json(
        { error: "record_failed", detail: rpcError.message },
        422,
      );
    }
    const { error: logError } = await serviceClient.from("scan_attempts")
      .insert({
        event_id: eventId,
        member_id: memberId,
        kind: "chips",
        model_count: parsed.total_points,
        breakdown: { stacks: parsed.stacks },
        photo_hash: photoHash,
      });
    if (logError) {
      console.warn(`scan-settle: attempt log failed (${imageRefForLog})`);
    }

    return json(
      {
        kind: "chips",
        count: parsed.stacks.reduce((a, s) => a + s.count, 0),
        total_points: parsed.total_points,
        stacks: parsed.stacks,
        photo_hash: photoHash,
        attempt: used + 1,
        attempts_remaining: MAX_ATTEMPTS_PER_EVENT - (used + 1),
      },
      200,
    );
  }

  // cards
  if (declined) {
    return json({ error: "model_declined", reason: declined }, 422);
  }
  const parsed = parseCards(mm.content);
  if (parsed.declined) {
    return json({ error: parsed.declined, reason: "unparseable_response" }, 422);
  }

  const snapshot = {
    source: "hosted",
    model,
    count: parsed.count,
    photo_hash: photoHash,
    prompt_kind: "cards",
  };
  const { error: rpcError } = await serviceClient.rpc("record_cah_tally", {
    p_event_id: eventId,
    p_card_count: parsed.count,
    p_vision_snapshot: snapshot,
    p_member_id: memberId,
  });
  if (rpcError) {
    return json({ error: "record_failed", detail: rpcError.message }, 422);
  }
  const { error: logError } = await serviceClient.from("scan_attempts").insert({
    event_id: eventId,
    member_id: memberId,
    kind: "cards",
    model_count: parsed.count,
    breakdown: { count: parsed.count },
    photo_hash: photoHash,
  });
  if (logError) {
    console.warn(`scan-settle: attempt log failed (${imageRefForLog})`);
  }

  return json(
    {
      kind: "cards",
      count: parsed.count,
      photo_hash: photoHash,
      attempt: used + 1,
      attempts_remaining: MAX_ATTEMPTS_PER_EVENT - (used + 1),
    },
    200,
  );
});
