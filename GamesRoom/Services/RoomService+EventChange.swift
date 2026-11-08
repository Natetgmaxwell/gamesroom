//
//  RoomService+EventChange.swift
//  GamesRoom
//
//  S3.3 — "the night changed under us".
//
//  A seat was claimed, released or declined; the night was renamed,
//  moved or cancelled. Every one of those changes invalidates the
//  night's pending briefing trio (the pushed logistics nudges were
//  scheduled against the old shape of the night) and the active
//  event the room page is rendering.
//
//  One entry point for all of it: `eventDidChange(eventId:)`.
//
//  The lane calls it after every claim / release / decline / edit
//  / cancel, so the notifications and the page never disagree with
//  the server.
//

import Foundation

extension RoomService {
    /// S3.3 — the event changed. Cancels the night's pending
    /// briefing trio, force-reloads the active event so the page
    /// shows the server's truth, and re-schedules the trio when the
    /// night still exists.
    ///
    /// The re-schedule is the reason this is not just a cancel: the
    /// trio is scheduled per (event, cadence, member), so a cancel
    /// on its own would drop the nudges for every member, not just
    /// the one who changed their mind. A night that is gone (cancelled
    /// or replaced) never gets a fresh schedule — the guard after
    /// the reload is what keeps that true.
    func eventDidChange(eventId: UUID) async {
        await NotificationDispatcher.shared.cancelBriefingTrio(eventId: eventId)

        // The active event is what carries the room id, so read it
        // before the reload.
        guard let event = activeEventByRoom.values.first(where: { $0.id == eventId }) else { return }
        let roomId = event.roomId

        let reloaded = await loadActiveEvent(roomId: roomId, force: true)

        // The night is gone (cancelled, settled and replaced) or is
        // no longer the room's active event: nothing to re-schedule.
        guard let live = reloaded, live.id == eventId else { return }

        // Lane S2 owns reminder scheduling: ONE reconcile entry point
        // for this device's signed-in user, planned from their
        // canonical seat state. No roster fan-out.
        await reconcileBriefing(eventId: eventId)
    }
}
