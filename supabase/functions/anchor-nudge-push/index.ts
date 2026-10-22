// =============================================================================
// Supabase Edge Function: anchor-nudge-push   (Games Room V0.107 §2b)
// =============================================================================
//
// Sends ONE APNs alert to ONE person: the member who brought the newcomer
// (room_memberships.invited_by). It exists for one failure — the newcomer
// claims a seat, their inviter does not, and they arrive with nobody
// (docs/V0.107_BROUGHT_BY_SPEC.md §2b, checks A11 and A12).
//
// Never the newcomer. Never the table. The request body names an event and a
// newcomer; the recipient is read from public.anchor_nudges.inviter_user_id.
//
// Invocation: the trigger public.event_rsvps_anchor_push (migration 105)
// POSTs {"event_id": "<uuid>", "newcomer_user_id": "<uuid>"} with header
// X-Anchor-Push-Secret = vault secret 'anchor_push_secret'. That trigger only
// posts after every rule in §2b has passed and only when the ledger row was
// newly inserted, so this function never decides who is allowed a push.
//
// The rules themselves live in SQL (queue_anchor_nudge): first three nights
// only, inviter active and not already seated, both switches on, event not
// started, once per newcomer per event. Nothing here widens them. The one
// rule re-checked here is the started event, because pg_net delivers
// asynchronously and the event can start between the claim and the send.
//
// Secrets (set by Nathan; never committed, never read by an agent):
//   ANCHOR_PUSH_ENABLED   "true" to send. Anything else → 200
//                         {status:"disabled"} and nothing sent.
//   ANCHOR_PUSH_SECRET    must equal the vault secret above.
//   APNS_KEY_ID, APNS_TEAM_ID (37S7KT7W83), APNS_KEY_P8,
//   APNS_BUNDLE_ID (com.gamesroom.app)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (provided by the platform)
//
// Deploy (Nathan, after approval; project bnrgkdcluopicqdpmrtu):
//   supabase functions deploy anchor-nudge-push --no-verify-jwt \
//     --project-ref bnrgkdcluopicqdpmrtu
// --no-verify-jwt is required: the caller is pg_net with no user JWT;
// the shared-secret header is the auth gate instead.
//
// Local tests: deno test supabase/functions/anchor-nudge-push/
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleRequest, type Deps } from "./handler.ts";
import { makeApnsSender } from "../question-turn-push/apns.ts";

const env = (k: string) => Deno.env.get(k) ?? "";

const supabase = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

const apns = makeApnsSender({
  keyId: env("APNS_KEY_ID"),
  teamId: env("APNS_TEAM_ID"),
  keyP8: env("APNS_KEY_P8"),
  bundleId: env("APNS_BUNDLE_ID") || "com.gamesroom.app",
});

const deps: Deps = {
  enabled: env("ANCHOR_PUSH_ENABLED") === "true",
  secret: env("ANCHOR_PUSH_SECRET"),
  now: () => new Date(),
  async loadNudge(eventId, newcomerUserId) {
    const { data, error } = await supabase
      .from("anchor_nudges")
      .select("event_id, newcomer_user_id, inviter_user_id, room_id, created_at, push_status")
      .eq("event_id", eventId)
      .eq("newcomer_user_id", newcomerUserId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  },
  async loadEvent(eventId) {
    const { data, error } = await supabase
      .from("events")
      .select("id, room_id, played_at")
      .eq("id", eventId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  },
  // The name is whatever the room already shows: public.users.display_name,
  // the same column get_room_members returns (migration 059).
  async loadDisplayName(userId) {
    const { data, error } = await supabase
      .from("users")
      .select("display_name")
      .eq("id", userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data?.display_name ?? null;
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
  async markNudge(eventId, newcomerUserId, status) {
    await supabase.from("anchor_nudges")
      .update({ push_status: status })
      .eq("event_id", eventId)
      .eq("newcomer_user_id", newcomerUserId);
  },
  // apns.ts is shared with question-turn-push and is not edited by this
  // slice. Two of its choices are inherited rather than chosen here, and
  // both are worth knowing before this ships:
  //   * it builds the APNs collapse id from payload.turn_id, and APNs
  //     rejects an empty one, so an anchor push — which has no turn —
  //     supplies its own key (one collapse group per event, the newcomer
  //     still named in the copy) under that name. It is a header only.
  //   * it hard-codes apns-expiration to ten minutes (a question is stale
  //     after that). An anchor nudge for an event next week inherits the
  //     same window, so a device that is unreachable for ten minutes
  //     loses the nudge rather than receiving it hours later. Deliberate
  //     for now: the alternative is editing shared APNs code, which this
  //     slice does not do. Flagged for review in the S5b report.
  send: (token, payload) => apns(token, { ...payload, turn_id: `anchor-${payload.event_id}` }),
};

Deno.serve((req) => handleRequest(req, deps));