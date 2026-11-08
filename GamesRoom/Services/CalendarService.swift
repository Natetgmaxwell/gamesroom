//
//  CalendarService.swift
//  GamesRoom
//
//  V0.86 — EventKit calendar auto-add (VISION.md §8).
//
//  Lane S2 (1.2.4): calendar rows per member. Every member who
//  claims a seat, with their calendar auto-add on
//  (`Room.calendarAutoAdd`, a per-member toggle on the membership
//  row), gets their own row; declining or releasing the seat, or
//  leaving the room, removes it.
//
//  The EventKit identifier is a per-device fact, so it lives on the
//  device: `CalendarRowStore` keeps a dictionary eventId ->
//  identifier in UserDefaults. The old shared column
//  (`events.event_calendar_identifier`, migration 087) held ONE
//  identifier for the whole table, so the second member's phone
//  looked up the first member's row and found nothing; it is no
//  longer read or written for lookups. A reinstall loses the map,
//  and the next claim writes a fresh row.
//
//  Each row carries `gamesroom://event/<eventId>` as its URL.
//
//  Failure is non-fatal by design: calendar writes never block the
//  seat flow. Errors collapse to `lastError`.
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
    /// The member-facing consent prompt is triggered by this call:
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
    /// "Denied. Open Settings to change"). Reads
    /// `EKEventStore.authorizationStatus(for: .event)` which is the
    /// system truth; the toggle's RPC lives separately.
    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Adds this member's calendar row for a night, or updates it
    /// when one is already on this device. With `createIfMissing`
    /// false, a night with no row on this device is left alone (an
    /// edit to a night the member has not claimed writes nothing).
    func upsertEvent(_ event: Event, createIfMissing: Bool = true) async {
        let known = CalendarRowStore.identifier(eventId: event.id)
        if known == nil, !createIfMissing { return }
        guard await requestAccess() else { return }

        let row: EKEvent
        if let known, let existing = store.event(withIdentifier: known) {
            row = existing
        } else {
            guard createIfMissing else { return }
            row = EKEvent(eventStore: store)
            row.calendar = store.defaultCalendarForNewEvents
        }
        row.title = event.name
        row.startDate = event.playedAt
        row.endDate = event.playedAt.addingTimeInterval(2 * 3600)
        row.notes = venueNotes(event.venue)
        row.url = CalendarRowStore.eventURL(eventId: event.id)

        do {
            try store.save(row, span: .thisEvent, commit: true)
            lastError = nil
            if let identifier = row.eventIdentifier {
                CalendarRowStore.set(identifier, eventId: event.id)
            }
        } catch {
            lastError = "Couldn't add to calendar: \(error.localizedDescription)"
        }
    }

    /// Removes this member's calendar row for a night, if this
    /// device wrote one. No-op otherwise.
    func removeEvent(eventId: UUID) async {
        guard let identifier = CalendarRowStore.identifier(eventId: eventId) else { return }
        guard let row = store.event(withIdentifier: identifier) else {
            // Already gone (deleted by hand, or another device's
            // sync): forget it.
            CalendarRowStore.remove(eventId: eventId)
            return
        }
        do {
            try store.remove(row, span: .thisEvent, commit: true)
            CalendarRowStore.remove(eventId: eventId)
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
