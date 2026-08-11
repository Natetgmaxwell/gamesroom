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
    func addEvent(room: Room, event: Event) async {
        guard room.calendarAutoAddHost else { return }
        guard await requestAccess() else { return }

        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.name
        ekEvent.startDate = event.playedAt
        ekEvent.endDate = event.playedAt.addingTimeInterval(2 * 3600)
        ekEvent.calendar = store.defaultCalendarForNewEvents
        ekEvent.notes = venueNotes(event.venue)

        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            UserDefaults.standard.set(ekEvent.eventIdentifier, forKey: StorageKeys.calendarEventIdentifier(eventId: event.id))
            lastError = nil
        } catch {
            lastError = "Couldn't add to calendar: \(error.localizedDescription)"
        }
    }

    /// Updates the calendar row for a room event, creating it when
    /// no row was written before. Keeps title/start/venue in sync
    /// with event edits.
    func updateEvent(room: Room, event: Event) async {
        guard room.calendarAutoAddHost else { return }
        guard await requestAccess() else { return }

        let key = StorageKeys.calendarEventIdentifier(eventId: event.id)
        if let identifier = UserDefaults.standard.string(forKey: key),
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
            await addEvent(room: room, event: event)
        }
    }

    /// Removes the calendar row for a room event, if one was written.
    /// No-op when the event was never added (or already removed).
    func removeEvent(eventId: UUID) async {
        let key = StorageKeys.calendarEventIdentifier(eventId: eventId)
        guard let identifier = UserDefaults.standard.string(forKey: key),
              let ekEvent = store.event(withIdentifier: identifier) else { return }
        do {
            try store.remove(ekEvent, span: .thisEvent, commit: true)
            UserDefaults.standard.removeObject(forKey: key)
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
