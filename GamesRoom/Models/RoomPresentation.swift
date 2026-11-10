//
//  RoomPresentation.swift
//  GamesRoom
//
//  P2 (audit 03 C1 + D12) — the room page's presentation machines.
//
//  One enum per presenter NODE. SwiftUI gets one `.sheet(item:)` per
//  node and nothing else, so two sheets can never be asked of the same
//  view. `.confirmationDialog` is a different presentation slot, so the
//  page keeps exactly two bindings: `RoomPresentation` for sheets and
//  `RoomConfirm` for the one dialog.
//
//  `id` is what `.sheet(item:)` keys on: a new case must carry a new
//  id, or SwiftUI keeps the old content on screen.
//

import Foundation

/// The modal sheet the room page is showing. Every call site that used
/// to set a Bool or an optional payload sets one of these instead.
enum RoomPresentation: Identifiable, Equatable {
    /// Room Settings (host hub + member notification prefs).
    case settings(Room)
    /// Member-side event edit.
    case editEvent(Event)
    /// AddEventSheet. `seed` is the pre-filled date ("Plan the next
    /// night" passes playedAt + 7 days); nil opens on the default.
    case addEvent(seed: Date?)
    /// Casino chip withdrawal.
    case withdraw(Event)
    /// Vision chip scan: the cash-out.
    case settleScan(Event)
    /// Inline "+" on the room switcher.
    case createRoom

    var id: String {
        switch self {
        case .settings(let room):
            return "settings:\(room.id.uuidString)"
        case .editEvent(let event):
            return "editEvent:\(event.id.uuidString)"
        case .addEvent(let seed):
            // A seed is part of the identity: "Plan the next night" on
            // two different nights opens two different sheets.
            return "addEvent:\(seed.map { String($0.timeIntervalSince1970) } ?? "none")"
        case .withdraw(let event):
            return "withdraw:\(event.id.uuidString)"
        case .settleScan(let event):
            return "settleScan:\(event.id.uuidString)"
        case .createRoom:
            return "createRoom"
        }
    }
}

/// The one confirmation dialog on the page. A dialog cannot be presented
/// from inside a sheet, so it keeps its own binding — but it is an enum,
/// not a Bool.
enum RoomConfirm: Identifiable, Equatable {
    /// "Sam hasn't cashed out. Settle the night anyway?" — the host
    /// settling while players still have chips on the table.
    case settleEarly(event: Event, stillPlaying: [String])

    var id: String {
        switch self {
        case .settleEarly(let event, let names):
            return "settleEarly:\(event.id.uuidString):\(names.joined(separator: ","))"
        }
    }

    var event: Event {
        switch self {
        case .settleEarly(let event, _):
            return event
        }
    }
}

enum PackEditor: Identifiable, Equatable {
    /// The chip values and vision settings. Every night is scored in
    /// chips, so this is the only scoring editor a room has.
    case casinoConfig

    var id: String {
        switch self {
        case .casinoConfig:
            return "casinoConfig"
        }
    }
}
