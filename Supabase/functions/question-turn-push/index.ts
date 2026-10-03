// =============================================================================
// Supabase Edge Function: question-turn-push   (Games Room V0.106)
// =============================================================================
//
// Sends ONE APNs alert to ONE person: the reader of a question turn.
// Mirrors Felt Faction's send-broadcast (pg_net trigger → function →
// device_tokens → APNs HTTP/2), narrowed to a single recipient.
//
// Invocation: the AFTER INSERT trigger on public.question_turns
// (migration 097) POSTs {"turn_id": "<uuid>"} with header
// X-Question-Push-Secret = vault secret 'question_turn_push_secret'.
// The trigger no-ops when that vault secret is missing, so the whole
// pipeline ships disabled.
//
// Recipient rule (non-negotiable): the only user ever addressed is
// question_turns.reader_id for the given turn_id. The request body
// cannot name a recipient; anything other than turn_id is ignored.
//
// Secrets (set by Nathan; never committed, never read by an agent):
//   QUESTION_TURN_PUSH_ENABLED  "true" to send. Anything else → 200
//                               {status:"disabled"} and nothing sent.
//   QUESTION_TURN_PUSH_SECRET   must equal the vault secret above.
//   APNS_KEY_ID, APNS_TEAM_ID (37S7KT7W83), APNS_KEY_P8,
//   APNS_BUNDLE_ID (com.gamesroom.app)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (provided by the platform)
//
// Deploy (Nathan, after approval; project bnrgkdcluopicqdpmrtu):
//   supabase functions deploy question-turn-push --no-verify-jwt \
//     --project-ref bnrgkdcluopicqdpmrtu
// --no-verify-jwt is required: the caller is pg_net with no user JWT;
// the shared-secret header is the auth gate instead.
//
// Local tests: deno test Supabase/functions/question-turn-push/
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleRequest, type Deps } from "./handler.ts";
import { makeApnsSender } from "./apns.ts";

const env = (k: string) => Deno.env.get(k) ?? "";

const supabase = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

const deps: Deps = {
  enabled: env("QUESTION_TURN_PUSH_ENABLED") === "true",
  secret: env("QUESTION_TURN_PUSH_SECRET"),
  async loadTurn(turnId) {
    const { data, error } = await supabase
      .from("question_turns")
      .select("id, event_id, room_id, reader_id, question_text, kind, read_at, passed_at, superseded_at")
      .eq("id", turnId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  },
  async loadTokens(userId) {
    const { data, error } = await supabase
      .from("device_tokens")
      .select("id, user_id, device_token, environment")
      .eq("user_id", userId)
      .eq("is_active", true)
      .eq("platform", "ios");
    if (error) throw new Error(error.message);
    return data ?? [];
  },
  async deactivateTokens(ids) {
    if (ids.length === 0) return;
    await supabase.from("device_tokens")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .in("id", ids);
  },
  async markTurn(turnId, status) {
    await supabase.from("question_turns").update({ push_status: status }).eq("id", turnId);
  },
  send: makeApnsSender({
    keyId: env("APNS_KEY_ID"),
    teamId: env("APNS_TEAM_ID"),
    keyP8: env("APNS_KEY_P8"),
    bundleId: env("APNS_BUNDLE_ID") || "com.gamesroom.app",
  }),
};

Deno.serve((req) => handleRequest(req, deps));
