// state.ts — the pure half of the mascot voice.
//
// No env, no network, no database: every decision about WHAT the mascot
// is talking about is made here, so it can be pinned down in
// state_test.ts. The edge function does the reading; this file does the
// reading's rules.
//
// The bug class this file exists to kill (audit 04-interconnect F5):
// the voice resolved its own state from the database while the face
// resolved it from the client's rendered state, so the two could say
// different things about the same room.
//
//   (a) Event. The server used to pick "the latest event in the room"
//       with no rule about future or hidden. The face sat on the
//       standings while the voice said "the night has started", and a
//       member the host had hidden from one event could be told the
//       name of that event.
//
//   (b) Season. close_season opens the next season, so the top two
//       seasons by ordinal are always [the live one, the closed one].
//       Looking for "any ended season in the top two" therefore found
//       the closed one forever, and every caption became a season
//       eulogy. The eulogy is for a season that has just closed, not
//       for every night after it.
//
//   (c) Roster. The leader and the member count came from the raw
//       membership table, so a kicked top scorer was still "the leader"
//       while the room page ranked somebody else.
//
// The rules, in one place:
//   1. An event the client named is used as it is - except when the
//      caller is hidden from it, which is never voiced.
//   2. Without a named event, the room's next event that is still to be
//      played is used (the get_active_event__inner rule), and the
//      hidden-from filter applies to it too.
//   3. The season eulogy fires for the newest season by ordinal when it
//      has ended, or for the season that closed within the last three
//      days.
//   4. Only ACTIVE members count, as leaders, as a caller rank, and as
//      the room's headcount.

/** Three days. The window a closed season stays news. */
export const SEASON_CLOSE_WINDOW_MS = 3 * 24 * 60 * 60 * 1000;

/** One event row, as the edge function reads it. */
export interface EventRow {
  id: string;
  room_id?: string | null;
  name?: string | null;
  played_at: string;
  settled_at?: string | null;
  hidden_from_user_ids?: string[] | null;
}

/** One season row, as the edge function reads it. */
export interface SeasonRow {
  ordinal: number;
  status: string;
  ended_at?: string | null;
}

/** One membership row, as the edge function reads it. */
export interface MembershipRow {
  user_id: string;
  role?: string | null;
  points_balance?: number | null;
  season_score?: number | null;
  membership_status?: string | null;
}

/**
 * Is this member on the event's hidden-from list?
 *
 * The host can hide one event from a member (migration 090). A hidden
 * member does not see that event in the app, so the voice does not name
 * it either.
 */
export function isHiddenFrom(
  event: { hidden_from_user_ids?: string[] | null },
  memberId: string,
): boolean {
  const hidden = event.hidden_from_user_ids ?? [];
  return hidden.includes(memberId);
}

/**
 * The room's next event that is still to be played, skipping the ones
 * the caller is hidden from.
 *
 * This is the get_active_event__inner rule (live function body):
 * played_at > now, earliest first, one row. The hidden-from filter is
 * the part the live body does not have and the brief asks for: a
 * member who is hidden from the next night must not have it read back
 * to them.
 *
 * The candidates arrive already filtered by room and sorted by the
 * query; the sort here is what makes the function safe to test and
 * independent of the caller's ordering.
 */
export function pickVisibleEvent(
  events: EventRow[],
  memberId: string,
  now: Date,
): EventRow | null {
  const upcoming = events
    .filter((e) => {
      const playedAt = Date.parse(e.played_at);
      return !Number.isNaN(playedAt) && playedAt > now.getTime();
    })
    .sort((a, b) => Date.parse(a.played_at) - Date.parse(b.played_at));
  for (const event of upcoming) {
    if (!isHiddenFrom(event, memberId)) return event;
  }
  return null;
}

/**
 * The season the eulogy is about, or null when no season has just
 * closed.
 *
 * Two ways to qualify, in the order they are checked:
 *
 *   1. The newest season by ordinal has ended. That is a room whose
 *      latest season is the closed one.
 *   2. The newest season that ended closed within the last three days.
 *      This is the normal case: close_season opens the next season, so
 *      the newest by ordinal is the live one and the season being
 *      praised is the one that just closed. Three days is the window
 *      in which "the season has closed" is still news - after that the
 *      room is back to its ordinary voice.
 */
export function seasonCloseContext(
  seasons: SeasonRow[],
  now: Date,
): { ordinal: number; ended_at: string | null } | null {
  const byOrdinal = [...seasons].sort((a, b) => (b.ordinal ?? 0) - (a.ordinal ?? 0));
  const newest = byOrdinal[0];

  if (newest && newest.status === "ended") {
    return { ordinal: newest.ordinal, ended_at: newest.ended_at ?? null };
  }

  const newestEnded = byOrdinal.find((s) => s.status === "ended");
  if (!newestEnded || !newestEnded.ended_at) return null;
  const endedAt = Date.parse(newestEnded.ended_at);
  if (Number.isNaN(endedAt)) return null;
  if (now.getTime() - endedAt > SEASON_CLOSE_WINDOW_MS) return null;
  return { ordinal: newestEnded.ordinal, ended_at: newestEnded.ended_at };
}

/**
 * What the mascot is told about the night.
 *
 * The strings are the instruction lines the model reads, so they are
 * written out in full here: the model is told which of these it is
 * looking at, and the point of the branch is that it never guesses.
 */
export function messageTypeForEvent(
  event: { played_at: string; settled_at?: string | null },
  now: Date,
): string {
  const nowMs = now.getTime();
  const playedAt = Date.parse(event.played_at);
  if (Number.isNaN(playedAt)) {
    return "Room has no events yet. Welcome the members.";
  }
  const settledAt = event.settled_at ? Date.parse(event.settled_at) : NaN;

  // Settled inside the last day: the night is over, and the recap is
  // the story.
  if (!Number.isNaN(settledAt) && nowMs - settledAt < 86_400_000) {
    return "Post-play recap. The event has concluded.";
  }
  // Settled longer ago: the room is between nights. No seat nudge.
  if (!Number.isNaN(settledAt)) {
    return "The room is between nights. Speak to the standings and the leaderboard. Do not prompt anyone to claim a seat.";
  }
  // Played, not settled: the night is running.
  if (playedAt <= nowMs) {
    return "The night has started. The event is live.";
  }
  // Genuinely upcoming: a seat nudge is honest.
  if (playedAt - nowMs < 7 * 86_400_000) {
    const days = Math.max(0, Math.ceil((playedAt - nowMs) / 86_400_000));
    return `New upcoming event in about ${days} day${days === 1 ? "" : "s"}. Prompt members to claim their seat.`;
  }
  return "The next scheduled event is more than a week away. Speak to the standings. Do not pressure immediate claims.";
}

/**
 * The active roster. A kicked member is not in the room any more
 * (migration 093), so they are not a leader, not a rank, and not a
 * headcount.
 */
export function activeMemberships<T extends MembershipRow>(rows: T[]): T[] {
  return rows.filter((r) => (r.membership_status ?? "active") === "active");
}

export interface LeaderFacts {
  leaderScore: number;
  /** The leader's margin over second place. */
  margin: number;
  /** The caller's place in the standings, host included. Null if the caller is not on the roster. */
  callerRank: number | null;
}

/**
 * The standings facts the prompt needs: the top score, the margin, and
 * the caller's rank. The rows arrive sorted by season score, which is
 * how the room page ranks them.
 */
export function leaderFacts(
  rows: MembershipRow[],
  memberId: string,
): LeaderFacts | null {
  if (rows.length === 0) return null;
  const top = rows[0];
  const second = rows[1];
  const leaderScore = top.season_score ?? 0;
  const margin = second ? leaderScore - (second.season_score ?? 0) : leaderScore;
  const index = rows.findIndex((r) => r.user_id === memberId);
  return {
    leaderScore,
    margin,
    callerRank: index === -1 ? null : index + 1,
  };
}

/**
 * The note that keeps the model honest about the margin. A table on
 * zero is not a leader, and a two-point lead is not a blowout.
 */
export function standingsNoteFor(leaderScore: number, margin: number): string {
  if (leaderScore <= 0) {
    return "Every member is still on zero for the season or the leader has no points yet — describe the table as level/unplayed, not as anyone leading comfortably.";
  }
  return margin >= 30
    ? "The leader is far ahead — a blowout margin is fair to describe."
    : "The table is close — do not overstate the leader's dominance.";
}
