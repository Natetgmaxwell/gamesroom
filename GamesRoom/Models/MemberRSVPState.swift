//
//  MemberRSVPState.swift
//  GamesRoom
//
//  Tracks B model layer. Pure data type. Foundation only.
//

import Foundation

/// Per-member response state to one event.
///
/// Drives the V0.8 notification cadence (per §"Pre-play Briefing" in
/// the brief): the on-create push is the **only** "claim your seat"
/// prompt in the entire pre-event window; T-48h and morning-of pushes
/// branch on this state. A `declined` member is terminal — no
/// secondary nudge, no surface on the room page to re-open.
enum MemberRSVPState: String, Codable, CaseIterable, Hashable {
    /// Member tapped `Claim seat`. Receives logistics nudges only.
    case claimed

    /// Member tapped `Can't make it`. Terminal for this event.
    case declined

    /// Member received the on-create push and did not tap either
    /// button. Receives reminders of the same ask.
    case unclaimed

    /// Whether the member has actively responded (rather than
    /// sitting on the silent default).
    var hasResponded: Bool {
        self != .unclaimed
    }
}
