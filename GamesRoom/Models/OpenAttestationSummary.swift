//
//  OpenAttestationSummary.swift
//  GamesRoom
//
//  Track B model layer. Pure data type. Foundation only.
//
//  Per-member row shown in the Witness Screen's "your P&L" list.
//  Mirrors the pre-v0.8 archive shape and adds the V0.8
//  `hasDispute` bool so the UI can render the dispute icon without
//  re-querying the underlying attestation row.
//

import Foundation

/// Lightweight per-row summary for the Witness Screen's per-member
/// attest list. Built by joining `public.settlement_attestations`
/// with `public.rooms` and `public.sessions` server-side so the
/// client doesn't need to do the join itself.
///
/// `visionAmountPoints` is the value the host confirmed; the
/// member's own claim lives in the underlying
/// `SettlementAttestation` row (not surfaced in this summary to
/// keep the wire shape small). `hasDispute` is denormalized from
/// `attestation.disputed` for the same reason.
struct OpenAttestationSummary: Codable, Identifiable, Hashable {
    let attestationId: UUID
    let sessionId: UUID
    let roomId: UUID
    let roomName: String
    let sessionName: String?
    let visionAmountPoints: Int64
    let detectionSource: String
    let confidenceAvg: Double?
    let openedAt: Date

    /// Whether the underlying attestation row has an unresolved
    /// dispute. Drives the Witness Screen's amber dispute badge.
    /// V0.8 addition — the pre-v0.8 shape carried this implicitly
    /// via a separate fetch.
    let hasDispute: Bool

    /// `attestationId` is the stable identity — one summary row
    /// per attestation.
    var id: UUID { attestationId }

    enum CodingKeys: String, CodingKey {
        case attestationId = "attestation_id"
        case sessionId = "session_id"
        case roomId = "room_id"
        case roomName = "room_name"
        case sessionName = "session_name"
        case visionAmountPoints = "vision_amount_points"
        case detectionSource = "detection_source"
        case confidenceAvg = "confidence_avg"
        case openedAt = "opened_at"
        case hasDispute = "has_dispute"
    }

    init(
        attestationId: UUID,
        sessionId: UUID,
        roomId: UUID,
        roomName: String,
        sessionName: String? = nil,
        visionAmountPoints: Int64,
        detectionSource: String,
        confidenceAvg: Double? = nil,
        openedAt: Date,
        hasDispute: Bool = false
    ) {
        self.attestationId = attestationId
        self.sessionId = sessionId
        self.roomId = roomId
        self.roomName = roomName
        self.sessionName = sessionName
        self.visionAmountPoints = visionAmountPoints
        self.detectionSource = detectionSource
        self.confidenceAvg = confidenceAvg
        self.openedAt = openedAt
        self.hasDispute = hasDispute
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        attestationId = try c.decode(UUID.self, forKey: .attestationId)
        sessionId = try c.decode(UUID.self, forKey: .sessionId)
        roomId = try c.decode(UUID.self, forKey: .roomId)
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? "Room"
        sessionName = try c.decodeIfPresent(String.self, forKey: .sessionName)
        visionAmountPoints = try c.decodeIfPresent(Int64.self, forKey: .visionAmountPoints) ?? 0
        detectionSource = try c.decodeIfPresent(String.self, forKey: .detectionSource) ?? "on_device"
        confidenceAvg = try c.decodeIfPresent(Double.self, forKey: .confidenceAvg)
        openedAt = try c.decode(Date.self, forKey: .openedAt)
        // V0.8 field. Default false so older RPC responses that
        // pre-date the dispute column still parse — the UI will
        // fall back to re-querying the attestation for the badge.
        hasDispute = try c.decodeIfPresent(Bool.self, forKey: .hasDispute) ?? false
    }

    /// The label shown in the per-member row's left-side context.
    /// Prefers the session name when present, falls back to the
    /// room name (legacy rows have no session title).
    var contextLabel: String { sessionName ?? roomName }

    /// Whether the detection source carries a confidence number
    /// worth rendering on the row. `.on_device` and `.hosted` do;
    /// `.manual` and `.pending` don't.
    var showsConfidenceBadge: Bool {
        detectionSource == "on_device" || detectionSource == "hosted"
    }
}