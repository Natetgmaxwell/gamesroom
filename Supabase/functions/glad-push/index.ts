// =============================================================================
// Supabase Edge Function: glad-push   (Games Room 1.2.5 Task 4)
// =============================================================================
//
// Sends ONE APNs alert to ONE person, the morning after a night: the people
// who sat with them and were glad they came, batched into one line.
//   "Connor and Sam were glad you came."
//
// Never the table, never the sender, never a count. The request body names a
// night and a recipient; the senders are read from public.glad_you_came on
// the service role and only ever reach that one recipient.
//
// Invocation: public.glad_push_cron_tick (migration 119) POSTs
// {"event_id": "<uuid>", "to_user": "<uuid>"} with header
// X-Glad-Push-Secret = vault secret 'glad_push_secret', once the row's
// deliver_at has passed and the room's clock is 08:00-22:00. This function
// re-checks both and claims the ledger row before it sends, so a row posted
// twice still goes out once.
//
// Secrets (set by Nathan / TARS; never committed):
//   GLAD_PUSH_ENABLED   "true" to send. Anything else -> 200 {status:"disabled"}.
//   GLAD_PUSH_SECRET    must equal the vault secret above.
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_KEY_P8, APNS_BUNDLE_ID (shared with the
//   other senders)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (provided by the platform)
//
// Deploy (TARS, after approval; project bnrgkdcluopicqdpmrtu):
//   supabase functions deploy glad-push --no-verify-jwt --project-ref bnrgkdcluopicqdpmrtu
// --no-verify-jwt: the caller is pg_net with no user JWT; the shared-secret
// header is the gate.
//
// Local tests: deno test Supabase/functions/glad-push/
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
  enabled: env("GLAD_PUSH_ENABLED") === "true",
  secret: env("GLAD_PUSH_SECRET"),
  now: () => new Date(),
  async loadQueueRow(eventId, toUser) {
    const { data, error } = await supabase
      .from("glad_push_queue")
      .select("event_id, to_user, room_id, deliver_at, push_status")
      .eq("event_id", eventId)
      .eq("to_user", toUser)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data;
  },
  async claimQueueRow(eventId, toUser) {
    const { data, error } = await supabase
      .from("glad_push_queue")
      .update({ push_status: "sending" })
      .eq("event_id", eventId)
      .eq("to_user", toUser)
      .eq("push_status", "queued")
      .select("event_id")
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data !== null;
  },
  async markQueueRow(eventId, toUser, status) {
    await supabase.from("glad_push_queue")
      .update({ push_status: status })
      .eq("event_id", eventId)
      .eq("to_user", toUser);
  },
  async loadSenderIds(eventId, toUser) {
    const { data, error } = await supabase
      .from("glad_you_came")
      .select("from_user")
      .eq("event_id", eventId)
      .eq("to_user", toUser)
      .order("created_at", { ascending: true });
    if (error) throw new Error(error.message);
    return (data ?? []).map((r: { from_user: string }) => r.from_user);
  },
  async loadDisplayName(userId) {
    const { data, error } = await supabase
      .from("users")
      .select("display_name")
      .eq("id", userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data?.display_name ?? null;
  },
  async loadRoomTimeZone(roomId) {
    const { data, error } = await supabase
      .from("rooms")
      .select("time_zone")
      .eq("id", roomId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data?.time_zone ?? null;
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
  // apns.ts builds the collapse id from payload.turn_id; a glad push has no
  // turn, so it supplies one per night. Header only. The shared sender's
  // 10-minute apns-expiration is inherited (see the anchor-nudge-push note).
  send: (token, payload) => apns(token, { ...payload, turn_id: `glad-${payload.event_id}` }),
};

Deno.serve((req) => handleRequest(req, deps));
