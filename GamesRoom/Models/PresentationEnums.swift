//
//  PresentationEnums.swift
//  GamesRoom
//
//  The per-screen presentation machines that live outside
//  `RoomDetailView`. Each replaces a cluster of independent Bool / Optional
//  bindings with one named value, so "which sheet is up" and "which confirm
//  is up" are single questions with single answers. SwiftUI still wants a
//  binding per presentation *slot* — these types make one slot per screen.
//
//  Foundation-only on purpose: `id` is the part worth testing (stable and
//  unique across cases), and the harness compiles Models/ but not Views/.
//

import Foundation

// MARK: - Room settings: destructive confirms (D11)

/// The three destructive confirms that used to be three Bools on the
/// settings hub. One value, one `confirmationDialog`.
enum RoomSettingsConfirm: String, Identifiable, Equatable, CaseIterable {
    case declareSeason
    case deleteRoom
    case leaveRoom

    var id: String { rawValue }
}

// MARK: - Question Box editor (D14)

/// Which question sheet the editor has up. Two `.sheet` modifiers on one
/// `List` meant "+ then tap a row" could try to present both.
enum QBSheet: Identifiable, Equatable {
    case editing(RoomQuestion)
    case adding

    var id: String {
        switch self {
        case .editing(let question):
            return "edit-\(question.id.uuidString)"
        case .adding:
            return "add"
        }
    }
}

// MARK: - Rooms list (audit 03, cross-lane note 3)

/// The four sheets the rooms list used to own as separate bindings:
/// room settings, create, join, and the iPad-only app settings.
enum RoomListPresentation: Identifiable, Equatable {
    case settings(Room)
    case createRoom
    case joinRoom
    case appSettings

    var id: String {
        switch self {
        case .settings(let room):
            return "settings-\(room.id.uuidString)"
        case .createRoom:
            return "createRoom"
        case .joinRoom:
            return "joinRoom"
        case .appSettings:
            return "appSettings"
        }
    }
}
