// =============================================================================
// Supabase Edge Function: briefing-push   (Games Room S2B, migration 109)
// =============================================================================
//
// The server half of the pre-play briefing.
//
// Today every briefing push is a LOCAL notification scheduled on one
// device's behalf, and the device only schedules it when a member opens
// that room. The member who most needs the week-before nudge is the one
// who never opens the app. The server knows the room, the night, the
// roster and the RSVP states, so the server does the asking.
//
// Invocation: the pg_net cron in public.briefing_push_cron_tick()
// (migration 109) POSTs
//   {"rows": [ {event_id, room_id, user_id, kind, rsvp_state,
//               event_name, played_at, host_note, time_zone,
//               mascot_name}, ... ]}
// with header X-Briefing-Push-Secret = vault secret
// 'briefing_push_secret'. The tick no-ops when that vault secret is
// missing, so the whole pipeline ships closed.
//
// Recipient rule (non-negotiable): the only user ever addressed is the
// user_id in the row. Every eligibility rule was applied by
// public.briefing_push_due before the payload was built, so this
// function never widens the audience of a row.
//
// Once-per-slot: the ledger row (event_id, user_id, kind) is written
// BEFORE the send, so a repeated tick finds the slot spent and sends
// nothing.
//
// Secrets (set by Nathan; never committed, never read by an agent):
//   BRIEFING_PUSH_ENABLED  "true" to send. Anything else -> 200
//                          {status:"disabled"} and nothing sent.
//   BRIEFING_PUSH_SECRET   must equal the vault secret above.
//   APNS_KEY_ID, APNS_TEAM_ID (37S7KT7W83), APNS_KEY_P8,
//   APNS_BUNDLE_ID (com.gamesroom.app)
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (provided by the platform)
//
// Deploy (Nathan, after approval; project bnrgkdcluopicqdpmrtu):
//   supabase functions deploy briefing-push --no-verify-jwt \
//     --project-ref bnrgkdcluopicqdpmrtu
// --no-verify-jwt is required: the caller is pg_net with no user JWT;
// the shared-secret header is the auth gate instead.
//
// Local tests: deno test Supabase/functions/briefing-push/
// =============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { handleRequest, type Deps } from "./handler.ts";
import { computeHeadcount, type Headcount } from "./plan.ts";
import { makeApnsSender } from "./apns.ts";

const env = (k: string) => Deno.env.get(k) ?? "";

const supabase = createClient(
  env("SUPABASE_URL"),
  env("SUPABASE_SERVICE_ROLE_KEY"),
  { auth: { persistSession: false } },
);

const deps: Deps = {
  enabled: env("BRIEFING_PUSH_ENABLED") === "true",
  secret: env("BRIEFING_PUSH_SECRET"),

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

  async claimSlot(row) {
    const { error } = await supabase
      .from("briefing_push_ledger")
      .insert({
        event_id: row.event_id,
        user_id: row.user_id,
        kind: row.kind,
      });
    if (!error) return true;
    // 23505 = unique violation. The primary key IS the once-per-slot
    // rule: an earlier tick already spent this slot.
    if (error.code === "23505") return false;
    throw new Error(error.message);
  },

  async deactivateTokens(ids) {
    if (ids.length === 0) return;
    await supabase.from("device_tokens")
      .update({ is_active: false, updated_at: new Date().toISOString() })
      .in("id", ids);
  },

  async loadHeadcount(eventId, roomId): Promise<Headcount> {
    const [members, rsvps, event] = await Promise.all([
      supabase
        .from("room_memberships")
        .select("user_id")
        .eq("room_id", roomId)
        .eq("membership_status", "active"),
      supabase
        .from("event_rsvps")
        .select("member_id, state")
        .eq("event_id", eventId),
      supabase
        .from("events")
        .select("hidden_from_user_ids")
        .eq("id", eventId)
        .maybeSingle(),
    ]);
    if (members.error) throw new Error(members.error.message);
    if (rsvps.error) throw new Error(rsvps.error.message);
    if (event.error) throw new Error(event.error.message);
    return computeHeadcount(
      (members.data ?? []).map((m) => m.user_id as string),
      (event.data?.hidden_from_user_ids ?? []) as string[],
      (rsvps.data ?? []) as { member_id: string; state: string }[],
    );
  },

  send: makeApnsSender({
    keyId: env("APNS_KEY_ID"),
    teamId: env("APNS_TEAM_ID"),
    keyP8: env("APNS_KEY_P8"),
    bundleId: env("APNS_BUNDLE_ID") || "com.gamesroom.app",
  }),
};

Deno.serve((req) => handleRequest(req, deps));
