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
// Invocation: public.queue_anchor_nudge (migrations 105 and 110) POSTs
// {"event_id": "<uuid>", "newcomer_user_id": "<uuid>"} with header
// X-Anchor-Push-Secret = vault secret 'anchor_push_secret'. The trigger
// writes the ledger row first and only posts when the room's local clock is
// inside 09:00-20:00; the anchor-push-tick cron posts the rows that were
// queued outside those hours. This function never decides who is allowed a
// push, only when it goes.
//
// The rules themselves live in SQL (queue_anchor_nudge): first three nights
// only, inviter active and not already seated, both switches on, event not
// started, once per newcomer per event. Nothing here widens them. The rules
// re-checked here are the ones that can change between the queue and the
// send: the event has not started, and the inviter is still not seated
// (audit 01-notifications #13).
//
// The copy and the clock: the weekday is read in the room's own zone
// (rooms.time_zone, migration 108), never in a hardcoded Australian zone.
// The interruption level is "active", not "time-sensitive": the nudge asks
// the inviter to claim a seat for a night that is days away, so it must not
// break through a Focus mode they chose.
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
  // The row is claimed before the send, so the trigger's post and the
  // cron's post cannot both deliver it. The UPDATE is conditional on the
  // row still being 'queued', so exactly one request wins.
  async claimNudge(eventId, newcomerUserId) {
    const { data, error } = await supabase
      .from("anchor_nudges")
      .update({ push_status: "sending" })
      .eq("event_id", eventId)
      .eq("newcomer_user_id", newcomerUserId)
      .eq("push_status", "queued")
      .select("event_id")
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data !== null;
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
  // The room's clock. rooms.time_zone (migration 108) is an IANA name and
  // is never null; the handler falls back to UTC if it cannot be read,
  // which is honest rather than wrong.
  async loadRoomTimeZone(roomId) {
    const { data, error } = await supabase
      .from("rooms")
      .select("time_zone")
      .eq("id", roomId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data?.time_zone ?? null;
  },
  // The inviter's seat, re-read at send time: they may have claimed one
  // while the nudge was queued outside the waking hours.
  async loadRsvpState(eventId, userId) {
    const { data, error } = await supabase
      .from("event_rsvps")
      .select("state")
      .eq("event_id", eventId)
      .eq("member_id", userId)
      .maybeSingle();
    if (error) throw new Error(error.message);
    return data?.state ?? null;
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
  //     after that). An anchor nudge is not a question, and now that it
  //     is delivered inside the room's waking hours the ten minutes is
  //     the wrong window: a device that is unreachable at 9am (commute,
  //     lift, no signal) loses the nudge for good. The briefing-push copy
  //     of apns.ts uses 24 hours for exactly this reason. Changing it
  //     here means editing shared APNs code, which this slice does not
  //     do, so it stays ten minutes and is flagged in the S2B report.
  send: (token, payload) => apns(token, { ...payload, turn_id: `anchor-${payload.event_id}` }),
};

Deno.serve((req) => handleRequest(req, deps));
