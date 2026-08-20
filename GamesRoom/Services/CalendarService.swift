//
//  CalendarService.swift
//  GamesRoom
//
//  V0.86 — EventKit calendar auto-add (VISION.md §8).
//
//  The host's per-room toggle (`calendarAutoAddHost`) was retired:
//  the EventKit identifier was stored in UserDefaults keyed by
//  event UUID, and iOS event UUIDs are not stable across
//  reinstalls. The toggle persisted server-side but the
//  identifier map died: writes looked like they succeeded but
//  update / delete couldn't find the EKEvent row.
//
//  V0.86 surfaces a per-member toggle (`Room.calendarAutoAdd`).
//  The EventKit identifier is persisted server-side in
//  `events.event_calendar_identifier` (migration 087). The
//  identifier survives reinstalls + device transfers — and the
//  toggle survives a re-install because it lives on the
//  membership row, not in the app's UserDefaults.
//
//  Flow:
//   - Member turns the toggle on in `MemberCalendarSettingsSheet`.
//     First turn triggers `requestAccess()`; granted → write
//     members.calendar_auto_add via `setMember_calendar_auto_add`.
//   - RoomService.addEvent / updateEventMemberFields sees the
//     toggle on and calls `CalendarService.addEvent / updateEvent`
//     with the server-cached `eventCalendarIdentifier`.
//   - After a successful EKEvent.save(), the service reports the
//     EventKit row id back to the server via
//     `report_calendar_identifier`. The host's calendar row is
//     written when the host is also a member with the toggle on
//     (no special-case for hosts).
//
//  Failure is non-fatal by design: calendar writes never block
//  the event flow. Errors collapse to `lastError` so a transient
//  banner can surface them; the event itself is already durable
//  server-side.
//

import EventKit
import Foundation

@MainActor
final class CalendarService: ObservableObject {

    static let shared = CalendarService()

    @Published private(set) var lastError: String?

    private let store = EKEventStore()

    private init() {}

    /// Requests full calendar access. Returns true when granted.
    /// The member-facing consent prompt is triggered by this call —
    /// the toggle's onChange fires it the first time the member
    /// enables auto-add.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            lastError = "Calendar access unavailable: \(error.localizedDescription)"
            return false
        }
    }

    /// V0.86 — returns the current EKEventStore authorization status
    /// so the settings UI can render the right row ("Allowed" /
    /// "Denied — open Settings to change"). Reads
    /// `EKEventStore.authorizationStatus(for: .event)` which is the
    /// system truth; the toggle's RPC lives separately.
    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Writes the EKEvent for a room event. Triggered by the
    /// `RoomService.addEvent` post-write path when the member's
    /// `calendarAutoAdd` toggle is on. After a successful save,
    /// reports the EventKit row id back to the server so the next
    /// update / delete can find it (replaces the old UserDefaults
    /// map keyed by event UUID).
    func addEvent(
        room: Room,
        event: Event,
        memberToggleOn: Bool,
        reportIdentifier: ((UUID, String) async -> Void)?
    ) async {
        guard memberToggleOn else { return }
        guard await requestAccess() else { return }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.name
        ekEvent.startDate = event.playedAt
        ekEvent.endDate = event.playedAt.addingTimeInterval(2 * 3600)
        ekEvent.calendar = store.defaultCalendarForNewEvents
        ekEvent.notes = venueNotes(event.venue)

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            lastError = nil
            // V0.86 — server-side identifier persistence. Reports
            // the EventKit row id so the next update / delete can
            // find the row without a local map. A failure here is
            // swallowed (the calendar row is still written; the
            // next edit will re-report).
            if let reportIdentifier, let identifier = ekEvent.eventIdentifier {
                await reportIdentifier(event.id, identifier)
            }
        } catch {
            lastError = "Couldn't add to calendar: \(error.localizedDescription)"
        }
    }

    /// Updates the calendar row for a room event, creating it when
    /// no row was written before. Keeps title/start/venue in sync
    /// with event edits. The identifier is read from the event
    /// model (server-canonical) — no UserDefaults lookup.
    func updateEvent(
        room: Room,
        event: Event,
        memberToggleOn: Bool,
        reportIdentifier: ((UUID, String) async -> Void)?
    ) async {
        guard memberToggleOn else { return }
        guard await requestAccess() else { return }

        if let identifier = event.eventCalendarIdentifier,
           let existing = store.event(withIdentifier: identifier) {
            existing.title = event.name
            existing.startDate = event.playedAt
            existing.endDate = event.playedAt.addingTimeInterval(2 * 3600)
            existing.notes = venueNotes(event.venue)
            do {
                try store.save(existing, span: .thisEvent, commit: true)
                lastError = nil
            } catch {
                lastError = "Couldn't update calendar event: \(error.localizedDescription)"
            }
        } else {
            // No identifier on file (the event was created before
            // the toggle was on, or a previous report failed). Fall
            // back to creating a fresh row + reporting back.
            await addEvent(
                room: room,
                event: event,
                memberToggleOn: memberToggleOn,
                reportIdentifier: reportIdentifier
            )
        }
    }

    /// Removes the calendar row for a room event. The EventKit
    /// row identifier is passed in (read from the server-cached
    /// event) — no local map. No-op when no identifier was
    /// reported yet (the event was never written to any calendar).
    func removeEvent(eventId: UUID, identifier: String?) async {
        guard let identifier,
              let ekEvent = store.event(withIdentifier: identifier) else { return }
        do {
            try store.remove(ekEvent, span: .thisEvent, commit: true)
        } catch {
            lastError = "Couldn't remove calendar event: \(error.localizedDescription)"
        }
    }

    private func venueNotes(_ venue: String?) -> String {
        if let venue, !venue.isEmpty {
            return "Games Room · \(venue)"
        }
        return "Games Room"
    }
}