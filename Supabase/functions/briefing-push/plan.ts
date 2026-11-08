// plan.ts — the pure half of the briefing push.
//
// No env, no network, no database: every string this file produces comes
// out of the row that the cron payload carries. That is deliberate. The
// copy is the product, so it has to be checkable without a database, and
// plan_test.ts is where the wording is pinned down.
//
// The row comes from public.briefing_push_due(p_now) (migration 109),
// which has already applied every eligibility rule: active membership,
// notifications on, the night not muted, the member not hidden, the
// event unsettled and in the future, the member not declined, the slot
// not already spent, and the member holding an active device token.
// This file decides only what the push SAYS, never who gets it.
//
// Two rules the copy must hold:
//   1. A member who has already claimed never reads the word "claim".
//      They have a seat; a nudge to claim is nonsense to them.
//   2. The weekday and the time are read in the ROOM's time zone
//      (rooms.time_zone, migration 108), not the server's and not the
//      phone's. A 7:30pm game in Sydney is a Friday night even when
//      the cron runs on a Friday morning UTC.

export const BRIEFING_KINDS = [
  "on_create",
  "t168h",
  "t48h",
  "morning_of",
  "host_headcount",
] as const;

export type BriefingKind = (typeof BRIEFING_KINDS)[number];

/** One due slot, as the cron payload carries it. */
export interface BriefingRow {
  event_id: string;
  room_id: string;
  user_id: string;
  kind: string;
  rsvp_state: string;
  event_name: string;
  played_at: string;
  host_note: string | null;
  time_zone: string;
  mascot_name: string;
}

export interface Headcount {
  claimed: number;
  unanswered: number;
}

export interface PlannedPush {
  kind: BriefingKind;
  event_id: string;
  room_id: string;
  user_id: string;
  title: string;
  body: string;
  /** APNs collapse id: one banner per (event, slot), not per send. */
  collapse_id: string;
}

/** The word a claimed member must never read, in any casing. */
const CLAIM_WORD = /claim/i;

/**
 * An unreadable time zone falls back to UTC rather than to a hardcoded
 * Australian zone. rooms.time_zone is NOT NULL with a default, so this
 * only fires on corrupt data, and a deterministic UTC is easier to reason
 * about than a guess.
 */
const FALLBACK_TIME_ZONE = "UTC";

function formatter(
  timeZone: string,
  options: Intl.DateTimeFormatOptions,
): Intl.DateTimeFormat {
  try {
    return new Intl.DateTimeFormat("en-AU", { ...options, timeZone });
  } catch {
    return new Intl.DateTimeFormat("en-AU", {
      ...options,
      timeZone: FALLBACK_TIME_ZONE,
    });
  }
}

/** "Friday", in the room's zone. */
export function weekdayIn(date: Date, timeZone: string): string {
  return formatter(timeZone, { weekday: "long" }).format(date);
}

/**
 * "7:30pm", in the room's zone. Built from the parts rather than from
 * the formatted string so the space before "pm" (which some ICU builds
 * render as a narrow no-break space) never reaches the copy.
 */
export function timeIn(date: Date, timeZone: string): string {
  const parts = formatter(timeZone, {
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).formatToParts(date);
  const part = (type: string) =>
    parts.find((p) => p.type === type)?.value ?? "";
  const hour = part("hour");
  const minute = part("minute");
  const period = part("dayPeriod").toLowerCase();
  if (!hour || !minute) return "";
  return `${hour}:${minute}${period}`;
}

/** "14 Nov", in the room's zone. */
export function dateIn(date: Date, timeZone: string): string {
  return formatter(timeZone, { day: "numeric", month: "short" }).format(date);
}

/**
 * The host headcount, counted from the roster.
 *
 * claimed     active members with a claimed seat.
 * unanswered  active members who have not said anything at all. A
 *             declined member HAS said (they said no), so they are not
 *             in this number, and hidden members are not in the room
 *             for this event so they are not counted either.
 */
export function computeHeadcount(
  activeMembers: string[],
  hiddenMembers: string[],
  rsvps: { member_id: string; state: string }[],
): Headcount {
  const hidden = new Set(hiddenMembers);
  const roster = activeMembers.filter((id) => !hidden.has(id));
  const onRoster = new Set(roster);
  let claimed = 0;
  let answered = 0;
  for (const rsvp of rsvps) {
    if (!onRoster.has(rsvp.member_id)) continue;
    if (rsvp.state === "claimed") {
      claimed++;
      answered++;
    } else if (rsvp.state === "declined") {
      answered++;
    }
  }
  return { claimed, unanswered: Math.max(0, roster.length - answered) };
}

/**
 * The logistics line for a member who already has a seat. It never says
 * "claim" and it carries the host's note when there is one.
 */
function claimedBody(weekday: string, time: string, hostNote: string | null): string {
  let body = `See you ${weekday} at ${time}.`;
  const note = hostNote?.trim() ?? "";
  // The rule is absolute: a claimed member never reads the word. A host
  // note that tells people to claim is not the note for someone who has
  // already claimed, so it is left out rather than sent.
  if (note && !CLAIM_WORD.test(note)) {
    body += ` Host's note: ${note}`;
  }
  return body;
}

/**
 * The copy for one due slot.
 *
 * Returns null when the row cannot be turned into a push: an unknown
 * kind, an unreadable played_at, or a headcount row with no headcount.
 */
export function planPush(
  row: BriefingRow,
  headcount?: Headcount | null,
): PlannedPush | null {
  const playedAt = new Date(row.played_at);
  if (Number.isNaN(playedAt.getTime())) return null;

  const kind = row.kind as BriefingKind;
  if (!BRIEFING_KINDS.includes(kind)) return null;

  const timeZone = row.time_zone?.trim() || FALLBACK_TIME_ZONE;
  const weekday = weekdayIn(playedAt, timeZone);
  const time = timeIn(playedAt, timeZone);
  const eventName = row.event_name?.trim() ?? "";
  const mascotName = row.mascot_name?.trim() || "Games Room";
  const claimed = row.rsvp_state === "claimed";

  let body: string;
  switch (kind) {
    case "on_create":
      body =
        `${eventName}, ${weekday} ${dateIn(playedAt, timeZone)} at ${time}. ` +
        `Open the room to grab a seat.`;
      break;
    case "t168h":
      body = claimed
        ? claimedBody(weekday, time, row.host_note)
        : `${eventName} is next ${weekday}. Your seat's waiting.`;
      break;
    case "t48h":
      body = claimed
        ? claimedBody(weekday, time, row.host_note)
        : `${weekday} at ${time}. Still a seat with your name on it.`;
      break;
    case "morning_of":
      body = claimed
        ? claimedBody(weekday, time, row.host_note)
        : `Tonight at ${time}. There's still a seat.`;
      break;
    case "host_headcount": {
      if (!headcount) return null;
      body =
        `${headcount.claimed} in, ${headcount.unanswered} haven't said. ` +
        `${weekday} ${time}.`;
      break;
    }
  }

  return {
    kind,
    event_id: row.event_id,
    room_id: row.room_id,
    user_id: row.user_id,
    title: `${mascotName}: ${eventName}`,
    body,
    collapse_id: `briefing-${row.event_id}-${kind}`.slice(0, 64),
  };
}

/**
 * The APNs payload.
 *
 * "active" is the interruption level: a briefing is worth waking the
 * phone for, but it is not time-sensitive the way a question turn is.
 * The thread id groups every slot of one night on one screen.
 */
export function composePayload(plan: PlannedPush): Record<string, unknown> {
  return {
    aps: {
      alert: { title: plan.title, body: plan.body },
      sound: "default",
      "interruption-level": "active",
      "thread-id": `briefing-${plan.event_id}`,
    },
    type: "briefing_push",
    kind: plan.kind,
    event_id: plan.event_id,
    room_id: plan.room_id,
    collapse_id: plan.collapse_id,
  };
}
