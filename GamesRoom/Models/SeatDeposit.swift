//
//  SeatDeposit.swift
//  GamesRoom
//
//  V0.85 — seat deposit as real escrow (migration 085). A tax
//  needs enforcement; a deposit needs only a reclaim. The
//  reclaim tap ("I'm here") IS the attendance check-in — the
//  member wants their chips back, so attendance records itself
//  without the host marking anyone.
//
//  Pure data types. Foundation only. Mirrors migration 085's
//  extended public.seat_deposits (held/returned/forfeited/waived)
//  plus the trigger/destination enums, the arrival-candidate
//  row, and the mascot-voiced arrival card copy. The SwiftUI
//  surface (ArrivalCard) reads candidates from
//  RoomService.loadArrivalCandidates and renders with
//  ArrivalPromptVoice.
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

    /// V0.85 — held → returned | forfeited | waived. `refunded`
    /// is the 043 legacy raw; it decodes as `.returned` (043
    /// never shipped a live caller, so the mapping is cosmetic).
    enum Status: String, Codable, CaseIterable, Hashable {
        case held
        case returned
        case forfeited
        case waived

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            let raw = try c.decode(String.self)
            self = Status(rawValue: raw)
                ?? (raw == "refunded" ? .returned : .held)
        }

        var displayName: String {
            switch self {
            case .held:      return "Held"
            case .returned:  return "Returned"
            case .forfeited: return "Forfeited"
            case .waived:    return "Waived"
            }
        }

        var isResolved: Bool { self != .held }
    }

    var isResolved: Bool { status != .held }
}

// MARK: - Seat deposit enums (V0.85 — migration 085)

///
/// How the room runs the seat deposit. The V0.85 collapse of the
/// old auto/prompt/manual trigger domain:
///
/// - `.escrow` (default) — the canonical V0.85 mode: claiming a
///   seat moves the deposit into escrow (`claim_seat_with_
///   deposit`), arriving taps it back (`check_in_seat`), and a
///   no-show surfaces on the host's arrival card for the
///   Forfeit / Skip decision.
/// - `.off` — no deposit. Claims are plain RSVP upserts; the
///   arrival card never renders.
///
enum SeatDepositTrigger: String, Codable, CaseIterable, Hashable {
    case escrow
    case off

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        // Legacy V0.84 raws (auto/prompt/manual) all collapse to
        // `.escrow` — the host forfeit-confirm replaces them.
        self = SeatDepositTrigger(rawValue: raw) ?? .escrow
    }

    var displayName: String {
        switch self {
        case .escrow: return "Escrow"
        case .off:    return "Off"
        }
    }
}

/// Where a forfeited deposit lands. Locked since V0.84 C3:
///
/// - `.nextPot` (default) — banked to the room's NEXT pot at its
///   creation. Public next-pot money; the absent member's social
///   standing is untouched. Drowning stays private.
/// - `.hostCharityPot` — same ledger row, meta
///   `destination='host_charity_pot'`.
/// - `.split` — same ledger row, meta `destination='split'`.
///
enum SeatDepositDestination: String, Codable, CaseIterable, Hashable {
    case nextPot = "next_pot"
    case hostCharityPot = "host_charity_pot"
    case split

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        self = SeatDepositDestination(rawValue: raw) ?? .nextPot
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
/// One row from the V0.85 `list_arrival_candidates(p_event_id)`
/// RPC (migration 085): a held seat deposit whose member claimed,
/// never tapped "I'm here", and has no play transaction — i.e. a
/// candidate for the host's arrival card decision.
/// `withinGrace` is true when the night is still inside the
/// room's grace window.
///
struct SeatDepositCandidate: Identifiable, Codable, Hashable {
    let userId: UUID
    let displayName: String
    let depositAmount: Int
    let status: String
    let withinGrace: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case displayName = "display_name"
        case depositAmount = "deposit_amount"
        case status
        case withinGrace = "within_grace"
    }

    init(
        userId: UUID,
        displayName: String,
        depositAmount: Int,
        status: String = SeatDeposit.Status.held.rawValue,
        withinGrace: Bool
    ) {
        self.userId = userId
        self.displayName = displayName
        self.depositAmount = depositAmount
        self.status = status
        self.withinGrace = withinGrace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userId = try c.decode(UUID.self, forKey: .userId)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? "Member"
        depositAmount = try c.decodeIfPresent(Int.self, forKey: .depositAmount) ?? 0
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? SeatDeposit.Status.held.rawValue
        withinGrace = try c.decodeIfPresent(Bool.self, forKey: .withinGrace) ?? false
    }
}

///
/// V0.85 — mascot-voiced copy for the host's arrival card. Pure
/// helper; no state. The locked directive is "the mascot is the
/// only system voice" — every line carries the mascot's name as
/// the attribution prefix. Swift string interpolation always
/// takes the mascot name from the caller so tests can assert
/// exact substrings across any mascot name.
///
enum ArrivalPromptVoice {

    /// The host-facing prompt: the mascot surfaces one candidate
    /// at a time so the host decides each in isolation.
    static func promptLine(
        mascotName: String,
        displayName: String,
        depositAmount: Int
    ) -> String {
        "\(mascotName): \(displayName) hasn't checked in. \(displayName)'s \(depositAmount) CC deposit is still held — forfeit it?"
    }

    /// Confirmation caption rendered after the host taps Forfeit.
    static func forfeitLine(
        mascotName: String,
        displayName: String,
        depositAmount: Int
    ) -> String {
        "\(mascotName): \(depositAmount) CC forfeited — \(displayName)'s chips ride the next pot."
    }

    /// Confirmation caption for Skip — `reason` is one of
    /// `texted` (the host texted the absent member) or `away`
    /// (the member told the host ahead of time). The deposit
    /// returns; the caption reads the way the host thinks it: a
    /// face-saving private fact, not a public label.
    static func skipLine(
        mascotName: String,
        displayName: String,
        reason: String
    ) -> String {
        switch reason {
        case "away":
            return "\(mascotName): Got it — \(displayName) was away. Deposit returned."
        case "texted":
            return "\(mascotName): Got it — \(displayName) was texted. Deposit returned."
        default:
            return "\(mascotName): Got it — \(displayName)'s deposit returned."
        }
    }

    /// The member-facing reclaim caption rendered on the chair
    /// card after the "I'm here" tap — the deposit is back, and
    /// that fact IS the check-in.
    static func checkedInLine(
        mascotName: String,
        depositAmount: Int
    ) -> String {
        "\(mascotName): You're in. Your \(depositAmount) CC deposit is back in your balance."
    }
}
