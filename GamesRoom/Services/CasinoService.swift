//
//  CasinoService.swift
//  GamesRoom
//
//  Track D3 — casino pack service for the V0.8 per-member scan flow.
//
//  Scope of this file: the member-facing operations of the casino pack.
//  The V0.7.1 host-batched model (where the host scans every member's
//  stack and the members only self-attest) is replaced in V0.8 with the
//  per-member scan flow: each member scans their own stack on their own
//  phone, sees the vision result, and writes the ledger directly. The
//  host's role at cashout shifts from counter to referee + finalizer.
//
//  Why this service exists
//  -----------------------
//  CasinoService owns five entry points used by the At-play Witness
//  Screen and the post-play attestation banner:
//
//    1. loadWithdrawalBalance(eventId:userId:) -> Int
//         Drives the slider's max on the Withdraw surface. Reads the
//         member's current `points_balance` for the room that hosts
//         this event. Non-throwing: any failure collapses to 0 so the
//         UI can render a disabled slider instead of an error.
//
//    2. withdraw(eventId:roomId:amount:) -> CasinoWithdrawal
//         Member-side chip withdrawal. Calls the existing
//         `withdraw_casino_chips` RPC (V0.8 contract: p_event_id,
//         p_room_id, p_amount) which decrements the denormalized
//         balance on `room_memberships` and inserts one
//         `casino_withdrawals` row + a `casino_withdrawal`
//         `transactions` ledger row. Throws on the server's
//         `Insufficient points balance` (errcode 23514) so the caller
//         can show a neutral toast.
//
//    3. submitMemberScan(eventId:visionAmount:visionSnapshot:
//                         confidence:source:) -> SettlementAttestation
//         The member-facing scan RPC. V0.8 inverts V0.7.1: the
//         member calls this from their own `ChipScanView` after the
//         vision result is confirmed, instead of waiting for the host
//         to scan them. The new `record_member_scan(p_event_id,
//         p_vision_amount_points, p_vision_snapshot,
//         p_confidence_avg, p_detection_source)` RPC writes one
//         `casino_settlement` `transactions` row, updates
//         `room_memberships.{points_balance, season_score}` by the
//         net delta, and opens/updates a
//         `settlement_attestations` row for the dispute surface.
//
//    4. getMyOpenAttestations() -> [OpenAttestationSummary]
//         The RoomDetailView banner polls this on load. Wraps the
//         existing `getMyOpenAttestations` RPC. Also runs the lazy
//         24h stale-close (mirrors the V0.7.1 pattern) so any row
//         older than 24h collapses to closed on the next read.
//
//    5. getEventTransactions(eventId:) -> [EventTransaction]
//         A thin wrapper around the existing
//         `get_event_transactions(p_event_id)` RPC. Used by the
//         host's live transactions board (per Track E, moves behind
//         the host's room settings gear in V0.8) and the past-event
//         recap.
//
//  Wrapper pattern
//  ---------------
//  Every RPC call follows the V0.7.1 wrapper convention:
//
//      let result: T = try await SupabaseClientProvider.shared
//          .rpc("rpc_name", params: [...])
//          .execute()
//          .value
//
//  Boolean-returning RPCs use `let _: Bool = ... .value` (the bare
//  boolean decode). Table-returning RPCs declare the result type
//  (`[CasinoWithdrawal]`, `[SettlementAttestation]`, etc.) so the
//  PostgREST decoder routes the JSON array into the matching model.
//  Non-throwing reads use `(try? ...) ?? []` so a network blip
//  collapses to an empty collection rather than a thrown error
//  (mirrors the V0.7.1 `getWithdrawals` / `getSessionScans` /
//  `getMyOpenAttestations` wrappers).
//
//  The service is `@MainActor @ObservableObject` so SwiftUI views can
//  inject it via `@EnvironmentObject` and read published state on the
//  main thread. All published fields are `private(set)` to keep the
//  mutation surface in this file.
//

import Foundation
import Supabase
import SwiftUI

// MARK: - EventTransaction

/// One row from `public.transactions`, scoped to a single event.
///
/// Mirrors the `get_event_transactions(p_event_id)` RPC's return shape
/// (migration 024). Used by the host's live transactions board
/// (V0.30/V0.8) and the past-event recap. Lives next to the
/// service that wraps it because no other view needs it today —
/// promoting it to `Models/EventTransaction.swift` is a one-line
/// move when a second caller appears.
struct EventTransaction: Decodable, Identifiable, Hashable {
    let id: UUID
    let memberId: UUID
    let memberDisplayName: String
    let kind: String
    let amountPoints: Int64
    let meta: AnyJSON?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case memberId = "member_id"
        case memberDisplayName = "member_display_name"
        case kind
        case amountPoints = "amount_points"
        case meta
        case createdAt = "created_at"
    }

    init(
        id: UUID,
        memberId: UUID,
        memberDisplayName: String,
        kind: String,
        amountPoints: Int64,
        meta: AnyJSON? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.memberId = memberId
        self.memberDisplayName = memberDisplayName
        self.kind = kind
        self.amountPoints = amountPoints
        self.meta = meta
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        memberId = try c.decode(UUID.self, forKey: .memberId)
        memberDisplayName = try c.decodeIfPresent(String.self, forKey: .memberDisplayName) ?? "Member"
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        amountPoints = try c.decodeIfPresent(Int64.self, forKey: .amountPoints) ?? 0
        meta = try c.decodeIfPresent(AnyJSON.self, forKey: .meta)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

// MARK: - AnyJSON

/// A round-trippable wrapper for arbitrary JSON values. Carries the
/// `meta` payload from `public.transactions` through the wire without
/// forcing the iOS layer to declare a per-kind schema. Same shape as
/// the V0.7.1 archived version (`RoomService.swift`).
struct AnyJSON: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Int64.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([AnyJSON].self) { value = v.map(\.value); return }
        if let v = try? c.decode([String: AnyJSON].self) {
            value = v.mapValues(\.value); return
        }
        if c.decodeNil() { value = NSNull(); return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Int64: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case is NSNull: try c.encodeNil()
        case let v as [Any]: try c.encode(v.map(AnyJSON.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyJSON.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyJSON, rhs: AnyJSON) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: value))
    }
}

// MARK: - CasinoService

@MainActor
final class CasinoService: ObservableObject {
    /// Published so SwiftUI views can subscribe. Mirrors the V0.7.1
    /// pattern (`@Published private(set) var isLoading`) so views
    /// that gate spinners on the service get free reactivity.
    @Published private(set) var isLoading: Bool = false

    /// Most-recent error message. Cleared on every successful RPC.
    /// Surfaced to the UI as a transient banner per the V0.8 "no
    /// public-shame framing" rule (Track A §2).
    @Published private(set) var lastError: String?

    // MARK: Balance + withdraw

    /// Reads the member's current `points_balance` for the room that
    /// hosts this event. Drives the Withdraw slider's max.
    ///
    /// Non-throwing by design: a network blip on this read shouldn't
    /// cascade into the slider rendering as "0 points" — collapsing
    /// to 0 here means the slider shows a disabled state, which the
    /// caller can render as "checking your balance…" and re-poll.
    ///
    /// The server resolves room from `p_event_id` and the membership
    /// from `p_user_id`; the returned `bigint` is the member's
    /// `room_memberships.points_balance` at read time. Decoded into
    /// `Int` because the iOS slider and CasinoWithdrawal both use
    /// `Int` — a balance > 2^31 is out of scope for the casino pack
    /// (V0.27 spec: max bet is 1,000 points).
    func loadWithdrawalBalance(eventId: UUID, userId: UUID) async -> Int {
        let result: Int64 = (try? await SupabaseClientProvider.shared
            .rpc("get_withdrawal_balance", params: [
                "p_event_id": eventId.uuidString,
                "p_user_id": userId.uuidString
            ])
            .execute()
            .value as Int64) ?? 0
        return Int(result)
    }

    /// Records a chip withdrawal for the calling member. Calls the
    /// V0.8 contract of the existing `withdraw_casino_chips` RPC
    /// (p_event_id, p_room_id, p_amount) which:
    ///
    ///   1. Decrement `room_memberships.points_balance` by `p_amount`
    ///      (refuses with errcode 23514 if the balance would go
    ///      negative).
    ///   2. Insert one `casino_withdrawals` row for the member's
    ///      chip bracket.
    ///   3. Insert one `casino_withdrawal` `transactions` row
    ///      (`amount_points = -p_amount`) so the ledger-based
    ///      balance path stays consistent.
    ///
    /// The RPC is idempotent on (event_id, member_id) — re-issuing a
    /// withdrawal call with the same amount records a second row.
    /// The caller is expected to gate the slider to "Withdraw" only
    /// once per event.
    ///
    /// Returns the new `casino_withdrawals` row so the caller can
    /// confirm the persisted `points_withdrawn` + `withdrawn_at`
    /// without a follow-up read. Throws on any server error
    /// (insufficient balance, auth failure, etc.) so the UI can
    /// show a neutral toast.
    func withdraw(
        eventId: UUID,
        roomId: UUID,
        amount: Int
    ) async throws -> CasinoWithdrawal {
        let rows: [CasinoWithdrawal] = try await SupabaseClientProvider.shared
            .rpc("withdraw_casino_chips", params: [
                "p_event_id": eventId.uuidString,
                "p_room_id": roomId.uuidString,
                "p_amount": String(amount)
            ])
            .execute()
            .value
        self.lastError = nil
        guard let row = rows.first else {
            throw NSError(
                domain: "CasinoService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "withdraw_casino_chips returned no row"]
            )
        }
        return row
    }

    // MARK: Per-member scan flow

    /// Submits the member's own chip-scan result. Called from
    /// `ChipScanView` after the vision pipeline produces a confirmed
    /// stack value. This is the V0.8 inversion of the V0.7.1 host
    /// scan-and-attest model: the member writes the ledger directly
    /// from their phone instead of waiting for the host to scan
    /// them.
    ///
    /// The new RPC signature
    /// (`record_member_scan(p_event_id, p_vision_amount_points,
    /// p_vision_snapshot, p_confidence_avg, p_detection_source)`)
    /// takes confidence + source as separate parameters so the
    /// server can persist them as columns rather than extracting
    /// them from the JSON snapshot blob (which the V0.30 RPC
    /// still does as a fallback). The `VisionSnapshot` is JSON-
    /// encoded once and passed as a string per the V0.7.1 pattern.
    ///
    /// Returns the freshly-opened `SettlementAttestation` row. The
    /// row's `isAwaitingMember == false` and `attestedAt == nil`
    /// after this call — the dispute surface is a separate tap.
    /// Throws on server errors (no prior withdrawal, post-finalize
    /// re-record blocked, etc.).
    func submitMemberScan(
        eventId: UUID,
        visionAmount: Int64,
        visionSnapshot: VisionSnapshot,
        confidence: Double?,
        source: DetectionSource
    ) async throws -> SettlementAttestation {
        // Migration 030 ships record_member_scan as a 3-param RPC
        // (uuid, bigint, jsonb) — server extracts detection_source
        // and confidence_avg from inside the snapshot JSON
        // (`p_vision_snapshot->>'source'`, `->>'confidence_avg'`).
        // The Swift wrapper used to send them as separate params;
        // that signature never made it into the migration set,
        // so callers were 400-ing. Fold both into the snapshot
        // envelope before sending.
        let encoder = JSONEncoder()
        let snapshotData = try encoder.encode(visionSnapshot)
        let snapshotDict = try JSONSerialization.jsonObject(
            with: snapshotData, options: []
        ) as? [String: Any] ?? [:]
        var envelope = snapshotDict
        envelope["source"] = source.rawValue
        if let confidence {
            envelope["confidence_avg"] = confidence
        }
        let envelopeData = try JSONSerialization.data(
            withJSONObject: envelope, options: []
        )
        let envelopeJSON = String(data: envelopeData, encoding: .utf8) ?? "{}"

        let result: Bool = try await SupabaseClientProvider.shared
            .rpc("record_member_scan", params: [
                "p_session_id": eventId.uuidString,
                "p_vision_amount_points": String(visionAmount),
                "p_vision_snapshot": envelopeJSON
            ])
            .execute()
            .value
        self.lastError = nil
        // Server returns boolean; resolve attestation via a follow-up read.
        let rows: [SettlementAttestation] = (try? await SupabaseClientProvider.shared
            .from("settlement_attestations")
            .select()
            .eq("session_id", value: eventId.uuidString)
            .order("opened_at", ascending: false)
            .limit(1)
            .execute()
            .value) ?? []
        if let row = rows.first { return row }
        guard result else {
            throw NSError(
                domain: "CasinoService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "record_member_scan returned no attestation"]
            )
        }
        // Server ack'd but no row read back — synthesise a minimal
        // placeholder so the caller's UI doesn't have to handle a
        // missing row. The next refresh will surface the real row.
        return SettlementAttestation(
            id: UUID(),
            sessionId: eventId,
            roomId: UUID(),
            memberId: UUID(),
            visionAmountPoints: visionAmount,
            claimedAmountPoints: visionAmount,
            disputed: false,
            disputeReason: nil,
            detectionSource: source.rawValue,
            confidenceAvg: confidence,
            openedAt: Date(),
            attestedAt: nil,
            closedAt: nil
        )
    }

    // MARK: Attestations

    /// Returns the calling member's open attestations across all
    /// rooms. Used by the Witness Screen banner (the "Your P&L: +$X"
    /// bar) and any per-room attestation surface. Typically returns
    /// 0 or 1 row.
    ///
    /// Also runs the lazy 24h stale-close on every read so a row
    /// that aged past its window closes before this read returns it
    /// — mirrors the V0.7.1 `getMyOpenAttestations` pattern. The
    /// stale-close call is cheap (single SQL update with a WHERE
    /// clause) and idempotent.
    ///
    /// Non-throwing: any failure (no session, network blip, schema
    /// drift on the V0.8-added `has_dispute` column) collapses to
    /// an empty list so the banner can render its "all settled"
    /// state without an error path. The `OpenAttestationSummary`
    /// model's `init(from:)` falls back to `hasDispute = false` on
    /// older RPC responses that pre-date the dispute column.
    func getMyOpenAttestations() async -> [OpenAttestationSummary] {
        // Lazy 24h finalize — closes rows that aged past the
        // attestation window so they don't surface as "open" on the
        // next read. Mirrors the V0.7.1 archived behavior.
        _ = try? await SupabaseClientProvider.shared
            .rpc("close_stale_attestations")
            .execute()
            .value

        let result: [OpenAttestationSummary] = (try? await SupabaseClientProvider.shared
            .rpc("getMyOpenAttestations")
            .execute()
            .value) ?? []
        self.lastError = nil
        return result
    }

    // MARK: Event transactions

    /// Returns the transactions (withdrawals + settlements + future
    /// kinds) for one event. Used by the host's live transactions
    /// board and the past-event recap.
    ///
    /// A thin wrapper around `get_event_transactions(p_event_id)`
    /// (migration 024). Non-throwing by design: a missing event id
    /// or empty result is a valid state (no transactions yet), and
    /// the UI can render the empty surface without a thrown error.
    func getEventTransactions(eventId: UUID) async -> [EventTransaction] {
        let result: [EventTransaction] = (try? await SupabaseClientProvider.shared
            .rpc("get_event_transactions", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value) ?? []
        self.lastError = nil
        return result
    }

    // MARK: Open-withdrawal lookup (M3.1)

    /// Returns the calling member's latest open (un-settled)
    /// `casino_withdrawals` row for one event, or `nil` if none.
    ///
    /// Powers the `SettleCasinoSheet` stepper default. The pre-M3
    /// placeholder was `withdrawn: 0` — the member saw an
    /// empty slider even after a withdrawal. After this wiring,
    /// the sheet renders with the actual chip bracket the
    /// member moved at the start of the round.
    ///
    /// Non-throwing: any RPC failure collapses to `nil` so the
    /// sheet can still render with the safe-zero default. Errors
    /// surface via `lastError` for the UI banner.
    ///
    /// Server-side: `get_my_open_withdrawal(p_event_id)` RPC,
    /// migration 040.
    func loadMyOpenWithdrawal(eventId: UUID) async -> CasinoWithdrawal? {
        let rows: [CasinoWithdrawal] = (try? await SupabaseClientProvider.shared
            .rpc("get_my_open_withdrawal", params: [
                "p_event_id": eventId.uuidString
            ])
            .execute()
            .value) ?? []
        self.lastError = nil
        return rows.first
    }

    // MARK: Casino config (W-06, US-26)

    /// Returns the room's casino config, or `nil` when the room
    /// has never been configured (the caller falls back to
    /// standard presets). Non-throwing by design: a network blip
    /// on this read shouldn't block the host's settings sheet —
    /// collapsing to nil renders the default-presets state.
    ///
    /// Server side: `get_casino_config(p_room_id)` (migration 014).
    func loadCasinoConfig(roomId: UUID) async -> CasinoConfig? {
        let rows: [CasinoConfig] = (try? await SupabaseClientProvider.shared
            .rpc("get_casino_config", params: [
                "p_room_id": roomId.uuidString
            ])
            .execute()
            .value) ?? []
        self.lastError = nil
        return rows.first
    }

    /// Host-only upsert of the room's casino config. Throws on
    /// server errors (non-host write, network failure) so the
    /// settings sheet can surface a neutral toast.
    ///
    /// Server side: `upsert_casino_config(p_room_id, p_enabled,
    /// p_chip_color_map, p_standard_presets)` (migration 014).
    func updateCasinoConfig(
        roomId: UUID,
        enabled: Bool,
        chipColorMap: [ChipColor: Int],
        standardPresets: Bool
    ) async throws {
        let map = Dictionary(uniqueKeysWithValues: chipColorMap.map {
            ($0.key.rawValue, $0.value)
        })
        _ = try await SupabaseClientProvider.shared
            .rpc("upsert_casino_config", params: [
                "p_room_id": roomId.uuidString,
                "p_enabled": enabled,
                "p_chip_color_map": map,
                "p_standard_presets": standardPresets
            ])
            .execute()
            .value as Void
        self.lastError = nil
    }
}