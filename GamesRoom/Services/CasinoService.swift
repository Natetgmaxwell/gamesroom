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

// MARK: - CasinoService

@MainActor
final class CasinoService: ObservableObject {
    /// Published so SwiftUI views can subscribe. Mirrors the V0.7.1
    /// pattern (`@Published private(set) var isLoading`) so views
    /// that gate spinners on the service get free reactivity.
    @Published private(set) var isLoading: Bool = false

    /// V0.69 — throttle the lazy `close_stale_attestations` write to
    /// at most once per 60s. The write was firing on every
    /// `getMyOpenAttestations` call (every refresh); measured: a
    /// 396-440ms refresh dropped to one write per minute on
    /// steady-state pull-to-refreshes.
    private var lastStaleCloseAt: Date?

    /// V0.69 — 30s TTL cache for the open-attestations read. Pull-
    /// to-refresh freshness comes from the TTL window; mutations
    /// invalidate via `invalidateEventCaches` (event-scoped caches
    /// only — this one is member-scoped, so it survives an event
    /// mutation and only the 30s window forces a re-fetch).
    private var attestationCache: (rows: [OpenAttestationSummary], at: Date)?

    /// V0.69 — 30s TTL cache for `get_event_working_hands(p_event_id)`
    /// keyed by eventId. Invalidated by mutation methods (withdraw,
    /// submit scan, settle/dispense) via `invalidateEventCaches`.
    private var workingHandsCache: [UUID: (hands: [WorkingHand], at: Date)] = [:]

    /// V0.69 — 30s TTL cache for `get_event_transactions(p_event_id)`
    /// keyed by eventId. Invalidated alongside workingHands on
    /// mutations via `invalidateEventCaches`.
    private var eventTransactionsCache: [UUID: (rows: [EventTransaction], at: Date)] = [:]

    /// V0.69 — 30s TTL window shared by the casino read caches.
    private let casinoCacheTTL: TimeInterval = 30

    /// V0.69 — 60s throttle window for the lazy
    /// `close_stale_attestations` write.
    private let staleCloseTTL: TimeInterval = 60

    /// V0.69 — drop event-scoped read caches (working hands +
    /// event transactions) so the next read re-fetches. Called
    /// from mutation success paths (`withdraw`, `submitMemberScan`,
    /// any future settle/dispense). No-op if absent.
    func invalidateEventCaches(eventId: UUID) {
        workingHandsCache.removeValue(forKey: eventId)
        eventTransactionsCache.removeValue(forKey: eventId)
    }

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
        let result: Int64 = await Perf.span("rpc get_withdrawal_balance") {
            (try? await SupabaseClientProvider.shared
                .rpc("get_withdrawal_balance", params: [
                    "p_event_id": eventId.uuidString,
                    "p_user_id": userId.uuidString
                ])
                .execute()
                .value as Int64) ?? 0
        }
        return Int(result)
    }

    /// Records a chip withdrawal for the calling member. Calls the
    /// V0.8 contract of the existing `withdraw_casino_chips` RPC
    /// (p_session_id, p_member_id, p_points) which:
    ///
    ///   1. Decrement `room_memberships.points_balance` by `p_points`
    ///      (refuses with errcode 23514 if the balance would go
    ///      negative).
    ///   2. Insert one `casino_withdrawals` row for the member's
    ///      chip bracket.
    ///   3. Insert one `casino_withdrawal` `transactions` row
    ///      (`amount_points = -p_points`) so the ledger-based
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
    ///
    /// The `roomId` parameter is retained for the call-site
    /// signature but unused at the wire — the server derives room
    /// from `p_session_id` (migration 025). The caller's auth
    /// session supplies the member id.
    func withdraw(
        eventId: UUID,
        roomId: UUID,
        amount: Int
    ) async throws -> CasinoWithdrawal {
        guard let session = await SupabaseClientProvider.currentSession() else {
            throw NSError(
                domain: "CasinoService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "withdraw_casino_chips requires an authenticated session"]
            )
        }
        let rows: [CasinoWithdrawal] = try await SupabaseClientProvider.shared
            .rpc("withdraw_casino_chips", params: [
                "p_session_id": eventId.uuidString,
                "p_member_id": session.user.id.uuidString,
                "p_points": String(amount)
            ])
            .execute()
            .value
        self.lastError = nil
        // V0.69 — mutations invalidate the event-scoped read caches
        // so the next pull-to-refresh re-fetches (working hands +
        // event transactions). The attestation cache is
        // member-scoped and only TTL-invalidates.
        invalidateEventCaches(eventId: eventId)
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
        source: DetectionSource,
        memberId: UUID? = nil
    ) async throws -> SettlementAttestation {
        // Migration 030 ships record_member_scan as a 3-param RPC
        // (uuid, bigint, jsonb) — server extracts detection_source
        // and confidence_avg from inside the snapshot JSON
        // (`p_vision_snapshot->>'source'`, `->>'confidence_avg'`).
        // The Swift wrapper used to send them as separate params;
        // that signature never made it into the migration set,
        // so callers were 400-ing. Fold both into the snapshot
        // envelope before sending.
        //
        // V0.72 slice 3 — `memberId` carries the host manual
        // fallback (migration 070 carve-out): the room host records
        // on behalf of a member when the member can't scan (no
        // camera, model down, rate-limited). nil = record as the
        // caller (member scan, legacy on_device path).
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

        var params: [String: String] = [
            "p_session_id": eventId.uuidString,
            "p_vision_amount_points": String(visionAmount),
            "p_vision_snapshot": envelopeJSON
        ]
        if let memberId {
            params["p_member_id"] = memberId.uuidString
        }

        let result: Bool = try await SupabaseClientProvider.shared
            .rpc("record_member_scan", params: params)
            .execute()
            .value
        self.lastError = nil
        // V0.69 — mutations invalidate the event-scoped read caches
        // so the next pull-to-refresh re-fetches (working hands +
        // event transactions).
        invalidateEventCaches(eventId: eventId)
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
    ///
    /// V0.69 — the lazy 24h finalize (`close_stale_attestations`)
    /// is throttled to once per 60s; the read is TTL-cached for 30s.
    /// Pull-to-refresh freshness comes from the 30s window — there
    /// is no force parameter.
    func getMyOpenAttestations() async -> [OpenAttestationSummary] {
        // Lazy 24h finalize — throttled to once per 60s. Mirrors the
        // V0.7.1 archived behavior; the throttle prevents the write
        // from firing on every refresh.
        let now = Date()
        if lastStaleCloseAt == nil || now.timeIntervalSince(lastStaleCloseAt!) > staleCloseTTL {
            _ = await Perf.span("rpc close_stale_attestations") {
                try? await SupabaseClientProvider.shared
                    .rpc("close_stale_attestations")
                    .execute()
                    .value
            }
            lastStaleCloseAt = now
        }

        if let cached = attestationCache,
           now.timeIntervalSince(cached.at) < casinoCacheTTL {
            Perf.event("rpc get_my_open_attestations cache-hit")
            return cached.rows
        }

        let result: [OpenAttestationSummary] = await Perf.span("rpc get_my_open_attestations") {
            (try? await SupabaseClientProvider.shared
                .rpc("get_my_open_attestations")
                .execute()
                .value) ?? []
        }
        self.lastError = nil
        attestationCache = (rows: result, at: now)
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
    ///
    /// V0.69 — 30s TTL cache keyed by eventId; invalidated by
    /// mutation methods (`withdraw`, `submitMemberScan`) via
    /// `invalidateEventCaches`.
    func getEventTransactions(eventId: UUID) async -> [EventTransaction] {
        let now = Date()
        if let cached = eventTransactionsCache[eventId],
           now.timeIntervalSince(cached.at) < casinoCacheTTL {
            Perf.event("rpc get_event_transactions cache-hit")
            return cached.rows
        }
        let result: [EventTransaction] = await Perf.span("rpc get_event_transactions") {
            (try? await SupabaseClientProvider.shared
                .rpc("get_event_transactions", params: [
                    "p_event_id": eventId.uuidString
                ])
                .execute()
                .value) ?? []
        }
        self.lastError = nil
        eventTransactionsCache[eventId] = (rows: result, at: now)
        return result
    }

    /// V0.73 — host acknowledgement that chips were physically
    /// dispensed. Stamps the withdrawal's `meta` server-side via
    /// `mark_withdrawal_dispensed` (migration 073), then drops the
    /// transactions cache so the next read reflects the stamp.
    /// Persistent across relaunches, unlike the old local set.
    func markWithdrawalDispensed(transactionId: UUID) async -> Bool {
        do {
            _ = try await SupabaseClientProvider.shared
                .rpc("mark_withdrawal_dispensed", params: [
                    "p_transaction_id": transactionId.uuidString
                ])
                .execute()
            eventTransactionsCache.removeAll()
            return true
        } catch {
            self.lastError = (error as NSError).localizedDescription
            return false
        }
    }

    // MARK: Open-withdrawal lookup (M3.1)

    /// Returns the calling member's latest open (un-settled)
    /// `casino_withdrawals` row for one event, or `nil` if none.
    ///
    /// Powers the `ChipScanSheet` stepper default. The pre-M3
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
        let rows: [CasinoWithdrawal] = await Perf.span("rpc get_my_open_withdrawal") {
            (try? await SupabaseClientProvider.shared
                .rpc("get_my_open_withdrawal", params: [
                    "p_event_id": eventId.uuidString
                ])
                .execute()
                .value) ?? []
        }
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

    /// Returns every room member's current working hand for one
    /// event. Drives the V0.51 "Chips on the table" section on
    /// `RoomDetailView` — host sees working hand + bank balance;
    /// members see working hand only (balance column hidden by
    /// the view gate, not the SQL).
    ///
    /// Non-throwing by design: a network blip on this read should
    /// collapse to an empty list so the section can render its
    /// hidden state without an error path. Mirrors the
    /// `getEventTransactions` non-throwing pattern.
    ///
    /// Server side: `get_event_working_hands(p_event_id)` (migration
    /// 065). The RPC returns one row per room member with their
    /// open `casino_withdrawals` sum as `working_hand` and their
    /// current `room_memberships.points_balance` as `points_balance`.
    ///
    /// V0.69 — 30s TTL cache keyed by eventId; invalidated by
    /// mutation methods via `invalidateEventCaches`.
    func loadWorkingHands(eventId: UUID) async -> [WorkingHand] {
        let now = Date()
        if let cached = workingHandsCache[eventId],
           now.timeIntervalSince(cached.at) < casinoCacheTTL {
            Perf.event("rpc get_event_working_hands cache-hit")
            return cached.hands
        }
        let result: [WorkingHand] = await Perf.span("rpc get_event_working_hands") {
            (try? await SupabaseClientProvider.shared
                .rpc("get_event_working_hands", params: [
                    "p_event_id": eventId.uuidString
                ])
                .execute()
                .value) ?? []
        }
        self.lastError = nil
        workingHandsCache[eventId] = (hands: result, at: now)
        return result
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
            .rpc("upsert_casino_config", params: UpsertCasinoConfigParams(
                p_room_id: roomId.uuidString,
                p_enabled: enabled,
                p_chip_color_map: map,
                p_standard_presets: standardPresets
            ))
            .execute()
            .value as Void
        self.lastError = nil
    }
}