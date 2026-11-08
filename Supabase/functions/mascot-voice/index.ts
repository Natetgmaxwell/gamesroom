// mascot-voice — V0.81.
//
// Server-side mascot caption generation. The member app POSTs the
// room + event ids; this function reads the room's mascot settings
// (name, personality, ideology) and the room's live state
// (active event, leaderboard, members, working hand) from the DB —
// the authoritative source — assembles the voice prompt, calls
// MiniMax-M3 with thinking disabled, and returns the caption.
//
// The MiniMax key lives ONLY in edge secrets (Deno.env). The iOS
// app never sees it; the client sends a Supabase JWT, not a key.
//
// Auth: Supabase member JWT. POST { room_id, event_id? }.
// Response: { caption: string } | { error, reason? }.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  activeMemberships,
  isHiddenFrom,
  leaderFacts,
  messageTypeForEvent,
  pickVisibleEvent,
  seasonCloseContext,
  standingsNoteFor,
} from "./state.ts";

const MINIMAX_URL = "https://api.minimax.io/v1/chat/completions";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

const SYSTEM_PROMPT = [
  "You are a games-night mascot character. Write ONE short message",
  "(1-3 short sentences, under 200 characters) in the mascot's voice.",
  "No emojis. No markdown. Just the message text. Match the personality",
  "and ideology tone precisely. Be concise, engaging, and in-character.",
  "Never break the fourth wall about being an AI. Tone is informational",
  "and light — a quiet footer caption, never dramatic. No ALL-CAPS.",
  "At most one exclamation mark.",
  "When asked for praise, name the specific behaviour and praise it — never a bare stat or a blanket compliment.",
].join(" ");

function stripThinkingBlocks(s: string): string {
  const openTag = "<thinking>";
  const closeTag = "</thinking>";
  let out = s;
  while (true) {
    const open = out.toLowerCase().indexOf(openTag);
    if (open === -1) return out;
    const close = out.toLowerCase().indexOf(closeTag, open + openTag.length);
    if (close === -1) return out.slice(0, open);
    out = out.slice(0, open) + out.slice(close + closeTag.length);
  }
}

async function callMiniMax(
  apiKey: string,
  model: string,
  system: string,
  user: string,
): Promise<{ ok: true; content: string } | { ok: false; reason: string }> {
  const payload = {
    model,
    messages: [
      { role: "system", content: system },
      { role: "user", content: user },
    ],
    max_tokens: 120,
    temperature: 0.8,
    thinking: { type: "disabled" },
  };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
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
    if (!res.ok) return { ok: false, reason: `minimax_http_${res.status}` };
    const data = await res.json();
    const content = data?.choices?.[0]?.message?.content;
    if (typeof content !== "string" || content.length === 0) {
      return { ok: false, reason: "empty_model_response" };
    }
    return { ok: true, content: stripThinkingBlocks(content).trim() };
  } catch (e) {
    if (e instanceof DOMException && e.name === "AbortError") {
      return { ok: false, reason: "minimax_timeout" };
    }
    return { ok: false, reason: "minimax_unreachable" };
  } finally {
    clearTimeout(timer);
  }
}

// V0.82 — one-line register glosses per ideology, so the LLM
// keeps the same light-comedy voice as the offline template
// matrix (never real-world advocacy).
const IDEOLOGY_GLOSS: Record<string, string> = {
  order: "trusts the host; the schedule is sacred",
  centrist: "reads the room; middle of the table",
  trickster: "shuffles the standings; provisionally",
  anarchist: "refuses authority; nobody is in charge",
  apocalypse: "light doom; existential irony, never doom-shouting",
  communist: "the table owns everything; comrade, shared standings, collective framing",
  conservative: "tradition holds; the ledger is sacred, suspicious of change",
  liberal: "progress and process; fairness, open counts, everyone gets a say",
  apolitical: "no politics, only poker; pivots to the game",
  // Keys are the DB wire values (the Swift enum rawValues) —
  // farRight / altRight, camelCase, not the display labels.
  farRight: "the pure table; gatekeeping comedy about true regulars and heritage nights — satire, never advocacy",
  altRight: "alternative standings; shadow ledgers, official counts in doubt — satire, never advocacy",
};

function buildPrompt(room: Record<string, unknown>, ctx: Record<string, unknown>): string {
  const lines: string[] = [];
  lines.push(`Mascot name: ${room.mascot_name ?? "Mascot"}`);
  lines.push(`Room: ${room.name ?? ""}`);
  lines.push(`Personality: ${room.mascot_personality ?? "friendly"}`);
  const ideology = (room.mascot_political_ideology ?? "centrist") as string;
  lines.push(`Political lean: ${ideology}`);
  const gloss = IDEOLOGY_GLOSS[ideology];
  if (gloss) lines.push(`Ideology tone: ${gloss}`);
  if (ctx.event_title) lines.push(`Event: ${ctx.event_title}`);
  if (ctx.member_count !== undefined) lines.push(`Members: ${ctx.member_count}`);
  if (ctx.leader) {
    lines.push(`Leader: ${ctx.leader}${ctx.leader_score !== undefined ? ` (${ctx.leader_score} season points)` : ""}`);
  }
  if (ctx.standings_note) lines.push(`Standings note: ${ctx.standings_note}`);
  if (ctx.recent_winner) lines.push(`Recent winner: ${ctx.recent_winner}`);
  if (ctx.caller_rank) lines.push(`Caller rank: ${ctx.caller_rank}`);
  if (ctx.working_hand) lines.push(`Working hand: ${ctx.working_hand}`);
  if (ctx.days_quiet !== undefined) lines.push(`Days quiet: ${ctx.days_quiet}`);
  if (ctx.season_ordinal !== undefined) lines.push(`Season ordinal: ${ctx.season_ordinal}`);
  lines.push(`Message type: ${ctx.message_type}`);
  if (ctx.message_type === "The season has closed. Praise the season's standouts.") {
    lines.push(
      "Register: praise-first. Name the specific behaviour (kept showing up,",
      "clawed it back, held the table together), praise it sincerely, and keep",
      "it about the behaviour — never a blanket compliment, never a stat readout.",
    );
  }
  lines.push("Write the mascot's message now:");
  return lines.join("\n");
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

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  let memberId: string;
  try {
    const authRes = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: Deno.env.get("SUPABASE_ANON_KEY")!,
      },
    });
    if (!authRes.ok) return json({ error: "unauthorized" }, 401);
    const user = await authRes.json();
    if (!user?.id) return json({ error: "unauthorized" }, 401);
    memberId = user.id;
  } catch {
    return json({ error: "unauthorized" }, 401);
  }

  const apiKey = Deno.env.get("MINIMAX_API_KEY");
  const model = Deno.env.get("MINIMAX_VISION_MODEL") ?? "MiniMax-M3";
  if (!apiKey) return json({ error: "voice_service_not_configured" }, 503);

  let body: { room_id?: string; event_id?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const serviceClient = createClient(
    supabaseUrl,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false } },
  );

  // Resolve the room + event (audit 04 F5a: the voice reads the room's
  // state the way the face does, from get_active_event's rule).
  // The push path passes only `event_id` (the dispatcher has no room
  // id); the footer path passes `room_id` and the function picks the
  // room's next unplayed night. When both are present, `event_id` wins.
  const eventId = (body.event_id ?? "").trim();
  const bodyRoomId = (body.room_id ?? "").trim();
  type EvRow = {
    id: string;
    room_id: string | null;
    name: string | null;
    played_at: string;
    settled_at: string | null;
    hidden_from_user_ids: string[] | null;
  };
  let roomId = bodyRoomId;
  let event: EvRow | null = null;
  const now = new Date();

  if (eventId && /^[0-9a-f-]{36}$/i.test(eventId)) {
    const { data: ev } = await serviceClient
      .from("events")
      .select("id, room_id, name, played_at, settled_at, hidden_from_user_ids")
      .eq("id", eventId)
      .maybeSingle();
    if (ev) {
      // An event the caller is hidden from is never voiced.
      const named = ev as EvRow;
      if (!isHiddenFrom(named, memberId)) {
        event = named;
        roomId = named.room_id as string;
      }
    }
  } else if (roomId && /^[0-9a-f-]{36}$/i.test(roomId)) {
    // get_active_event__inner semantics: the next night still to be
    // played, earliest first, with the hidden-from filter the live
    // function does not have (the brief supplies it).
    const { data: candidates } = await serviceClient
      .from("events")
      .select("id, room_id, name, played_at, settled_at, hidden_from_user_ids")
      .eq("room_id", roomId)
      .gt("played_at", now.toISOString())
      .order("played_at", { ascending: true })
      .limit(20);
    event = (pickVisibleEvent((candidates ?? []) as EvRow[], memberId, now) as EvRow | null);
  } else {
    return json({ error: "invalid_room_id" }, 400);
  }
  if (!roomId || !/^[0-9a-f-]{36}$/i.test(roomId)) {
    return json({ error: "invalid_room_id" }, 400);
  }

  // Membership gate — the caller must be an ACTIVE member of the room
  // (audit 04 F5: a kicked member gets no voice either).
  const { data: membership } = await serviceClient
    .from("room_memberships")
    .select("user_id")
    .eq("room_id", roomId)
    .eq("user_id", memberId)
    .eq("membership_status", "active")
    .maybeSingle();
  if (!membership) return json({ error: "not_a_member" }, 403);

  // Room mascot settings — authoritative server-side read.
  const { data: room } = await serviceClient
    .from("rooms")
    .select("name, mascot_name, mascot_personality, mascot_political_ideology")
    .eq("id", roomId)
    .single();
  if (!room) return json({ error: "room_not_found" }, 404);

  // Season-close branch (audit 04 F5b: the eulogy used to fire forever,
  // because "any ended season in the top two" stayed true after the
  // first close). The rule now lives in state.ts's seasonCloseContext:
  // the newest season by ordinal being ended, or a season that ended
  // within the last three days.
  const { data: latestSeasons } = await serviceClient
    .from("seasons")
    .select("id, ordinal, status, ended_at")
    .eq("room_id", roomId)
    .order("ordinal", { ascending: false })
    .limit(2);
  const seasonClose = seasonCloseContext((latestSeasons ?? []) as {
    ordinal: number;
    status: string;
    ended_at: string | null;
  }[], now);

  // Live room state for the prompt.
  const ctx: Record<string, unknown> = {};

  if (event) {
    ctx.event_title = event.name;
    // 2026-09-02 fix — give the model the real date so it never invents
    // "before Wednesday" for an event that already happened.
    ctx.event_played_at = event.played_at;
    if (event.settled_at) ctx.event_settled_at = event.settled_at;
  }

  // The message_type decision lives in state.ts (messageTypeForEvent),
  // unit-tested there; it is the inline block that used to live here.
  const eventMessageType = event
    ? messageTypeForEvent(event, now)
    : "Room has no events yet. Welcome the members.";

  // Season-closed wins over the event-derived message_type: when the
  // footer is showing the season-close card, the LLM should praise the
  // season's standouts.
  if (seasonClose) {
    ctx.message_type = "The season has closed. Praise the season's standouts.";
    ctx.season_ordinal = seasonClose.ordinal;
  } else {
    ctx.message_type = eventMessageType;
  }

  // Standings (audit 04 F8: the leaderboard, the caller rank and the
  // member count used to include kicked members). ACTIVE members only,
  // ranked by season score like the room page; the facts (leader,
  // margin, caller rank) come from state.ts.
  const { data: leaderboard } = await serviceClient
    .from("room_memberships")
    .select("user_id, role, points_balance, season_score, membership_status")
    .eq("room_id", roomId)
    .order("season_score", { ascending: false })
    .limit(10);
  const standings = activeMemberships((leaderboard ?? []) as {
    user_id: string;
    role?: string | null;
    points_balance?: number | null;
    season_score?: number | null;
    membership_status?: string | null;
  }[]);
  if (standings.length > 0) {
    // 2026-09-02 fix — leader is the top of the ACTUAL standings
    // (season_score DESC, host included: the room page ranks the host
    // too, so a host-led table previously crowned the #2 member as
    // "leader"). Also pass the top score so the model can't call a
    // 0-point member "sits comfortably at the front".
    const facts = leaderFacts(standings, memberId);
    const top = standings[0];
    const { data: leaderUser } = await serviceClient
      .from("users")
      .select("display_name")
      .eq("id", top.user_id)
      .maybeSingle();
    if (leaderUser?.display_name && facts) {
      ctx.leader = leaderUser.display_name;
      ctx.leader_score = facts.leaderScore;
      ctx.standings_note = standingsNoteFor(facts.leaderScore, facts.margin);
    }
    // Caller rank mirrors the standings order (host included),
    // matching what the room page shows.
    if (facts?.callerRank) ctx.caller_rank = facts.callerRank;
  }

  const { count: memberCount } = await serviceClient
    .from("room_memberships")
    .select("id", { count: "exact", head: true })
    .eq("room_id", roomId)
    .eq("membership_status", "active");
  ctx.member_count = memberCount ?? 0;

  if (event) {
    const { data: withdrawals } = await serviceClient
      .from("casino_withdrawals")
      .select("points_withdrawn")
      .eq("session_id", event.id)
      .eq("member_id", memberId);
    if (withdrawals && withdrawals.length > 0) {
      ctx.working_hand = withdrawals.reduce(
        (a: number, w: { points_withdrawn: number }) => a + w.points_withdrawn,
        0,
      );
    }
  }

  const prompt = buildPrompt(room, ctx);
  const mm = await callMiniMax(apiKey, model, SYSTEM_PROMPT, prompt);
  if (!mm.ok) return json({ error: "voice_failed", reason: mm.reason }, 502);
  if (mm.content.length === 0) return json({ error: "voice_failed", reason: "empty_model_response" }, 502);

  return json({ caption: mm.content }, 200);
});
