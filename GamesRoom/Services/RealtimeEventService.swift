//
//  RealtimeEventService.swift
//  GamesRoom
//
//  V0.77 — member-side realtime event discovery.
//
//  Replaces the architecturally-dead "host schedules everyone's
//  notifications on the host's device" fan-out with per-device
//  self-scheduling: each signed-in member's device subscribes to
//  INSERTs on `public.events` (added to the supabase_realtime
//  publication in migration 077). When the host creates an event,
//  every connected member's device receives the insert and
//  schedules its own local briefing notifications via the existing
//  `NotificationDispatcher` 3×3 cadence machinery.
//
//  Delivery gates (all preserved from the V0.54 quiet-by-default
//  design):
//   1. RLS — the `members can read events` policy scopes realtime
//      delivery to room members; non-members receive nothing.
//   2. Room-level opt-in — the member's own
//      `room_memberships.notifications_enabled` must be true for
//      the briefing trio to be scheduled on this device.
//   3. Idempotency — the dispatcher's stable
//      (eventId, cadence, userId) identifiers mean a duplicate
//      insert delivery overwrites instead of stacking.
//
//  Deliberately NOT covered (accepted gaps, documented):
//   - Offline members miss the realtime moment entirely. The
//     briefing slot still renders in-app on next open. Full
//     offline delivery requires APNs (the V0.8+ remote-push slice).
//   - No realtime on event UPDATE/DELETE. The existing
//     cancel-on-delete / reschedule-on-RSVP-change paths in
//     RoomService handle those mutations for this device; other
//     devices' scheduled notifications may go stale until they
//     next open the room.
//   - The rooms list is the local membership cache. If the member
//     joined a room but the list is stale (e.g. signed in on a new
//     device mid-session), the insert is skipped. The next
//     `refresh()` covers it; no scheduling race.
//

import Foundation
import Supabase

@MainActor
final class RealtimeEventService {

    // MARK: - Singleton

    static let shared = RealtimeEventService()

    // MARK: - State

    /// The rooms cache the insert gate reads. Injected by
    /// `GamesRoomApp` at start time (the app owns the singleton
    /// `RoomService`). Weak so the service never keeps the store
    /// alive.
    private weak var roomService: RoomService?

    /// The active realtime channel, when subscribed. `nil` when
    /// stopped or not yet started.
    private var channel: RealtimeChannelV2?

    /// Guards against double-start / double-stop races.
    private var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    /// Subscribes to INSERTs on `public.events` for the signed-in
    /// session. Idempotent: a second call while running is a no-op.
    /// Call after sign-in (or on app launch with a live session).
    /// - Parameter roomService: the app-owned rooms cache.
    func start(roomService: RoomService) async {
        guard !isRunning else { return }
        isRunning = true
        self.roomService = roomService

        let channel = SupabaseClientProvider.shared.channel("realtime-events") { _ in }
        self.channel = channel

        // Register the stream BEFORE subscribe (per the SDK docs).
        let inserts = channel.postgresChange(InsertAction.self, table: "events")
        await channel.subscribe()

        Task { [weak self] in
            for await action in inserts {
                await self?.handleEventInsert(action)
            }
        }
    }

    /// Tears down the subscription. Call on sign-out.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        if let channel {
            await SupabaseClientProvider.shared.removeChannel(channel)
        }
        channel = nil
        roomService = nil
    }

    // MARK: - Insert handling

    /// A new event row arrived over realtime. Self-schedule this
    /// device's briefing notifications when the gates pass.
    private func handleEventInsert(_ action: InsertAction) async {
        guard
            let idString = action.record["id"]?.stringValue,
            let id = UUID(uuidString: idString),
            let roomIdString = action.record["room_id"]?.stringValue,
            let roomId = UUID(uuidString: roomIdString),
            let name = action.record["name"]?.stringValue,
            let playedAtString = action.record["played_at"]?.stringValue,
            let playedAt = Self.parseDate(playedAtString)
        else { return }

        // Resolve the room from the membership cache. RLS already
        // scoped delivery to members; this guards against
        // scheduling for a room the user has left (stale cache).
        guard let roomService, let room = roomService.rooms.first(where: { $0.id == roomId }) else {
            return
        }

        // Room-level notification opt-in for THIS device's user.
        guard room.notificationsEnabled else { return }

        // The caller's own user id — needed so the dispatcher's
        // per-(event, cadence, user) identifiers are stable.
        guard
            let callerId = try? await SupabaseClientProvider.shared.auth.session.user.id
        else { return }

        // Schedule the briefing trio for THIS device's user only —
        // one cadence entry (the local user, .unclaimed). The
        // host's own addEvent path already scheduled the host's.
        let callerName = roomService?.membersByRoom[roomId]?
            .first(where: { $0.userId == callerId })?.displayName
        await NotificationDispatcher.shared.scheduleBriefingTrio(
            eventId: id,
            eventName: name,
            playedAt: playedAt,
            mascotName: room.mascotName,
            perMemberCadence: [callerId: .unclaimed],
            memberNameById: [callerId: callerName ?? "friend"],
            optedInMemberIds: [callerId],
            mutedMemberIds: [],
            hostNote: nil,
            mascotPersonality: room.mascotPersonality,
            mascotIdeology: room.mascotPoliticalIdeology
        )
    }

    // MARK: - Date parsing

    /// Postgres timestamptz arrives as ISO 8601 with fractional
    /// seconds ("2026-08-16T09:00:00.123456+00:00"). Try both
    /// fractional and plain forms; `nil` fails the insert-safe
    /// guard above.
    private static func parseDate(_ raw: String) -> Date? {
        let fractional: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Test hook (Foundation-only test harness)

#if DEBUG
extension RealtimeEventService {
    /// Parses a raw realtime timestamptz string. Exposed for the
    /// Foundation-only test harness (no Supabase import there).
    static func testParseDate(_ raw: String) -> Date? {
        parseDate(raw)
    }
}
#endif

