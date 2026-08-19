//
//  SeatDeposit.swift
//  GamesRoom
//
//  F-MVP-04 — seat deposit model. Pure data type. Foundation only.
//
//  One row per (event, user) when the room has a non-zero
//  seat_deposit_amount. Status transitions: held → refunded |
//  forfeited. Mirrors migration 043's public.seat_deposits.
//
//  V0.84 C3 — the no-show tax prompt layer lives here (not in
//  MascotEngine.swift, which C4 owns this slice). The trigger
//  enum, destination enum, candidate row, and the mascot-voiced
//  prompt copy all live on this Foundation-only file so the test
//  runner can exercise every line. The SwiftUI surface
//  (NoShowTaxPromptCard) reads the candidate list from
//  RoomService.loadNoShowCandidates and renders the prompt with
//  NoShowTaxPromptVoice.promptLine.
//

import Foundation

struct SeatDeposit: Identifiable, Codable, Hashable {
    let id: UUID
    let amount: Int
    let status: Status
    let heldAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case amount
        case status
        case heldAt = "held_at"
    }

    init(id: UUID, amount: Int, status: Status, heldAt: Date) {
        self.id = id
        self.amount = amount
        self.status = status
        self.heldAt = heldAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        amount = try c.decodeIfPresent(Int.self, forKey: .amount) ?? 0
        let raw = try c.decodeIfPresent(String.self, forKey: .status) ?? "held"
        status = Status(rawValue: raw) ?? .held
        heldAt = try c.decodeIfPresent(Date.self, forKey: .heldAt) ?? Date()
    }

    enum Status: String, Codable, CaseIterable, Hashable {
        case held
        case refunded
        case forfeited

        var displayName: String {
            switch self {
            case .held:     return "Held"
            case .refunded: return "Refunded"
            case .forfeited: return "Forfeited"
            }
        }
    }

    var isResolved: Bool { status != .held }
}

// MARK: - No-show tax enums (V0.84 C3 — migration 082)

///
/// How the room surfaces the no-show tax at session start. The
/// locked V0.84 C3 contract:
///
/// - `.auto` — legacy settle-time auto-forfeit; the 043 path
///   stays dormant and no Swift surface prompts. The Settings
///   picker exposes this so a host who wants the old behaviour
///   can opt back in.
/// - `.prompt` — the canonical V0.84 C3 mode: at session start
///   the host sees a mascot-voiced card per claimed-but-absent
///   member and decides Apply / Skip (texted) / Skip (away).
/// - `.manual` — host never gets prompted; the Operations sub-
///   sheet's manual apply surface (a future slice) is the only
///   way to apply.
///
enum NoShowTaxTrigger: String, Codable, CaseIterable, Hashable {
    case auto
    case prompt
    case manual

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = NoShowTaxTrigger(rawValue: raw) ?? .prompt
    }

    var displayName: String {
        switch self {
        case .auto:   return "Auto"
        case .prompt: return "Prompt"
        case .manual: return "Manual"
        }
    }
}

///
/// Where the forfeited no-show chip lands. Locked V0.84 C3:
///
/// - `.nextPot` (default) — banked to the room's NEXT pot at
///   its creation. Public next-pot money; the absent member's
///   social standing is untouched. Substrate line: drowning
///   stays private.
/// - `.hostCharityPot` — same transaction, meta
///   `destination='host_charity_pot'`. The host decides where
///   the room's charity pot sits.
/// - `.split` — same transaction, meta `destination='split'`.
///
enum NoShowTaxDestination: String, Codable, CaseIterable, Hashable {
    case nextPot = "next_pot"
    case hostCharityPot = "host_charity_pot"
    case split

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = NoShowTaxDestination(rawValue: raw) ?? .nextPot
    }

    var displayName: String {
        switch self {
        case .nextPot:        return "Next pot"
        case .hostCharityPot: return "Host charity pot"
        case .split:          return "Split"
        }
    }
}

///
/// One row from the V0.84 C3 `list_no_show_candidates(p_event_id)`
/// RPC (migration 082): a claimed RSVP whose owner has no
/// transactions row for the event — i.e. a candidate for the
/// host's prompt. `withinGrace` is true when the night is still
/// inside the room's grace window (the host hasn't waited longer
/// than the configured grace minutes).
///
struct NoShowTaxCandidate: Identifiable, Codable, Hashable {
    let userId: UUID
    let displayName: String
    let taxAmount: Int
    let withinGrace: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case taxAmount = "tax_amount"
        case withinGrace = "within_grace"
    }

    init(userId: UUID, displayName: String, taxAmount: Int, withinGrace: Bool) {
        self.userId = userId
        self.displayName = displayName
        self.taxAmount = taxAmount
        self.withinGrace = withinGrace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        taxAmount = try c.decodeIfPresent(Int.self, forKey: .taxAmount) ?? 0
        withinGrace = try c.decodeIfPresent(Bool.self, forKey: .withinGrace) ?? false
    }
}

///
/// V0.84 C3 — mascot-voiced copy for the host prompt. Pure
/// helper; no state. Lives here (not in MascotEngine.swift,
/// which C4 owns this slice) so the Foundation runner covers
/// every line. The locked directive is "the mascot is the only
/// system voice" — the prompt copy carries the mascot's name
/// as the attribution prefix (e.g. "Felty: Sam claimed a seat.
/// Sam didn't show. 200 CC into the next pot — apply?").
///
/// Swift string interpolation in `promptLine` /
/// `applyLine` / `skipLine` always takes the mascot name from
/// the caller; no implicit value is read from environment, so
/// tests can assert exact substrings across any mascot name.
///
enum NoShowTaxPromptVoice {

    /// The host-facing prompt: the mascot surfaces one candidate
    /// at a time so the host decides each in isolation. Always
    /// opens with the mascot's name so the substrate reads as
    /// "the mascot is the only system voice" (not a neutral
    /// system message).
    static func promptLine(
        mascotName: String,
        displayName: String,
        taxAmount: Int
    ) -> String {
        "\(mascotName): \(displayName) claimed a seat. \(displayName) didn't show. \(taxAmount) CC into the next pot — apply?"
    }

    /// Confirmation caption rendered after the host taps Apply.
    static func applyLine(
        mascotName: String,
        displayName: String,
        taxAmount: Int
    ) -> String {
        "\(mascotName): \(taxAmount) CC applied — \(displayName)'s forfeit is in the next pot."
    }

    /// Confirmation caption for Skip — `reason` is one of
    /// `texted` (the host texted the absent member) or `away`
    /// (the member told the host ahead of time). The caption
    /// reads the same way the host thinks it: a face-saving
    /// private fact, not a public label.
    static func skipLine(
        mascotName: String,
        displayName: String,
        reason: String
    ) -> String {
        switch reason {
        case "away":
            return "\(mascotName): Got it — \(displayName) was away. Waived."
        case "texted":
            return "\(mascotName): Got it — \(displayName) was texted. Waived."
        default:
            return "\(mascotName): Got it — \(displayName) waived."
        }
    }
}