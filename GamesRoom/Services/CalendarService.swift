//
//  CalendarService.swift
//  GamesRoom
//
//  Track T1.1 — EventKit calendar auto-add (VISION.md §8).
//
//  Honors the host's per-room `calendarAutoAddHost` toggle with
//  real EventKit writes. The toggle itself is persisted via the
//  existing `update_room` RPC; this service is the write side.
//
//  Failure is non-fatal by design: calendar writes never block the
//  event flow. Errors collapse to `lastError` so a transient banner
//  can surface them; the event itself is already durable server-side.
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
    /// The host-facing consent prompt is triggered by this call —
    /// the toggle's onChange fires it the first time the host
    /// enables auto-add.
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            lastError = "Calendar access unavailable: \(error.localizedDescription)"
            return false
        }
    }

    /// Writes (or updates) the EKEvent for a room event. The
    /// eventIdentifier is persisted keyed by the room-event id so
    /// a later settle/delete can remove the calendar row.
    func addEvent(room: Room, eventId: UUID, name: String, playedAt: Date, venue: String?) async {
        guard room.calendarAutoAddHost else { return }
        guard await requestAccess() else { return }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = name
        ekEvent.startDate = playedAt
        ekEvent.endDate = playedAt.addingTimeInterval(2 * 3600)
        ekEvent.calendar = store.defaultCalendarForNewEvents
        if let venue, !venue.isEmpty {
            ekEvent.notes = "Games Room · \(venue)"
        } else {
            ekEvent.notes = "Games Room"
        }

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            var identifiers = UserDefaults.standard.dictionary(forKey: StorageKeys.calendarEventIdentifiers) as? [String: String] ?? [:]
            identifiers[eventId.uuidString] = ekEvent.eventIdentifier
            UserDefaults.standard.set(identifiers, forKey: StorageKeys.calendarEventIdentifiers)
            lastError = nil
        } catch {
            lastError = "Couldn't add to calendar: \(error.localizedDescription)"
        }
    }

    /// Removes the calendar row for a room event, if one was written.
    /// No-op when the event was never added (or already removed).
    func removeEvent(eventId: UUID) async {
        guard let identifiers = UserDefaults.standard.dictionary(forKey: StorageKeys.calendarEventIdentifiers) as? [String: String],
              let identifier = identifiers[eventId.uuidString],
              let ekEvent = store.event(withIdentifier: identifier) else { return }
        do {
            try store.remove(ekEvent, span: .thisEvent, commit: true)
            var updated = identifiers
            updated.removeValue(forKey: eventId.uuidString)
            UserDefaults.standard.set(updated, forKey: StorageKeys.calendarEventIdentifiers)
        } catch {
            lastError = "Couldn't remove calendar event: \(error.localizedDescription)"
        }
    }
}
