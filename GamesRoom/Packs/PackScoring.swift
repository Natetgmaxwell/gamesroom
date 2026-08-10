//
//  PackScoring.swift
//  GamesRoom
//
//  Track P0.3 — the pack-scoring contract.
//
//  Every V0.8 pack round resolves to one or more `ScoreEntry` rows
//  that the host-side scoring dashboard submits atomically via
//  `ScoringService.recordRound(...)`. The contract is:
//
//    1. The host-side UI renders a pack-specific input form (see
//       `HostScoreEntryView.swift` in `Views/Scoring/`).
//    2. The form encodes its result into `PackScoringInput`,
//       a tagged enum whose cases match the four V0.8 packs.
//    3. `PackScoringResolver.resolve(input: against:)` projects
//       the input into one `ScoreEntry` per affected member.
//    4. `ScoringService.recordRound(...)` writes each entry to the
//       server via `record_round_score(p_room_id, p_event_id,
//       p_pack_slug, p_entries jsonb)` (see migration 035).
//
//  The two scoring-type families resolve differently:
//
//    * `single_winner` → one entry: the winner's user id +
//      `winPoints` season-score delta.
//    * `withdraw_return` → one entry per member with a net delta
//      (returned - withdrawn); the Casino pack.
//
//  Server-side validation is the source of truth; the Swift
//  resolver is the canonical pre-submit validator so the host sees
//  the projected deltas before tapping Save.
//

import Foundation

/// One row of a scoring submission. Mirrors the
/// `record_round_score` RPC's `p_entries jsonb` array shape
/// (migration 035). Each entry is one atomic ledger write:
/// a per-member season-score delta. The host-side dashboard
/// aggregates multiple `ScoreEntry`s into a single round
/// submission; the server is idempotent on
/// `(p_room_id, p_event_id, p_round_index)` so a retry doesn't
/// double-write.
struct ScoreEntry: Codable, Hashable, Identifiable {
    /// Member the row applies to. Mirrors
    /// `public.room_memberships.user_id`.
    let memberId: UUID

    /// Signed season-score delta. Positive for a win / returned
    /// chips, negative for a forfeit / net loss. Mirrors
    /// `public.transactions.amount_points` for the `casino_settlement`
    /// / `round_score` kinds.
    let pointsDelta: Int64

    /// Free-form metadata the pack writes alongside the ledger
    /// row. Single-winner packs write `{ "winner": true }`;
    /// Casino writes `{ "withdrawn": N, "returned": N }`. Used by
    /// the per-member recap screen.
    let meta: [String: PackMetaValue]

    /// Stable identity for SwiftUI lists. The submission id +
    /// member id together; the submission id comes from the
    /// dashboard and isn't a UUID, so we synthesise one.
    var id: String { "\(memberId.uuidString):\(pointsDelta)" }

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case pointsDelta = "points_delta"
        case meta
    }

    init(memberId: UUID, pointsDelta: Int64, meta: [String: PackMetaValue] = [:]) {
        self.memberId = memberId
        self.pointsDelta = pointsDelta
        self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        pointsDelta = try c.decodeIfPresent(Int64.self, forKey: .pointsDelta) ?? 0
        meta = try c.decodeIfPresent([String: PackMetaValue].self, forKey: .meta) ?? [:]
    }
}

/// One host-side scoring submission. Tagged enum whose cases
/// match the four V0.8 packs. The host-side dashboard encodes
/// its form into one of these; the resolver expands it into
/// the matching `ScoreEntry` array.
enum PackScoringInput: Hashable {
    /// Single-winner round. Mirrors `single_winner` packs
    /// (cards_against_humanity, monopoly_deal, pluto_chess).
    /// The resolver emits one entry: the winner's user id plus
    /// `winPoints` season-score delta.
    case singleWinner(roundIndex: Int, winnerMemberId: UUID, winPoints: Int)

    /// Multi-winner round. Same `single_winner` scoring family,
    /// but the round can crown more than one winner (a shared
    /// pot, a tied hand, a judge's double pick). The resolver
    /// emits one entry per winner, each with `winPoints`.
    /// F-MVP-05 V2 minimal (scope decision 2026-08-10).
    case multiWinner(roundIndex: Int, winnerMemberIds: [UUID], winPoints: Int)

    /// Withdraw/return round. Mirrors the `withdraw_return`
    /// pack (casino). One entry per member; the resolver emits
    /// `(returned - withdrawn)` per member and writes
    /// `meta["withdrawn"]` / `meta["returned"]` for the recap.
    case withdrawReturn(roundIndex: Int, perMember: [MemberNet])

    /// Convenience: which pack a given input was authored for.
    /// Used by the resolver to pick the right policy.
    var packSlug: String {
        switch self {
        case .singleWinner: return "single_winner" // pack-specific value resolved via registry
        case .multiWinner:  return "single_winner"
        case .withdrawReturn: return "casino"
        }
    }
}

/// One member's withdraw/return ledger row. The host-side
/// slider writes one of these per active member.
struct MemberNet: Hashable {
    let memberId: UUID
    let withdrawnPoints: Int64
    let returnedPoints: Int64

    /// The net delta the ledger write will record. Positive =
    /// member came out ahead, negative = member lost.
    var netDelta: Int64 { returnedPoints - withdrawnPoints }
}

/// Resolves a `PackScoringInput` into the matching `ScoreEntry`
/// list. Pure function — no side effects, no service calls.
/// The host-side dashboard calls this to preview the
/// projected ledger delta before the host taps Save.
struct PackScoringResolver {

    /// Resolves an input against the matching pack. The caller
    /// supplies the pack slug so the resolver can branch on
    /// scoring-type without importing the full pack types.
    static func resolve(_ input: PackScoringInput, packSlug: String) -> [ScoreEntry] {
        switch input {
        case .singleWinner(let roundIndex, let winnerMemberId, let winPoints):
            _ = roundIndex
            return [
                ScoreEntry(
                    memberId: winnerMemberId,
                    pointsDelta: Int64(winPoints),
                    meta: ["winner": .bool(true), "round_index": .int(Int64(roundIndex))]
                )
            ]

        case .multiWinner(let roundIndex, let winnerMemberIds, let winPoints):
            return winnerMemberIds.map { memberId in
                ScoreEntry(
                    memberId: memberId,
                    pointsDelta: Int64(winPoints),
                    meta: ["winner": .bool(true), "round_index": .int(Int64(roundIndex))]
                )
            }

        case .withdrawReturn(let roundIndex, let perMember):
            return perMember.map { net in
                ScoreEntry(
                    memberId: net.memberId,
                    pointsDelta: net.netDelta,
                    meta: [
                        "withdrawn": .int(net.withdrawnPoints),
                        "returned":  .int(net.returnedPoints),
                        "round_index": .int(Int64(roundIndex))
                    ]
                )
            }
        }
    }
}

/// JSON-safe metadata value for `ScoreEntry.meta`. Mirrors the
/// shape `AnyJSON` exposes in `CasinoService.swift` but as an
/// explicit enum so the per-pack metadata is type-safe (and the
/// server `jsonb` decoder has a fixed schema to validate against).
enum PackMetaValue: Codable, Hashable {
    case string(String)
    case int(Int64)
    case bool(Bool)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        self = .string("")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v):  try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }
}