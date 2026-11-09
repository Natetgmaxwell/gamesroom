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
    /// Vision chip scan (settle with a camera).
    case settleScan(Event)
    /// CAH black-card count scan.
    case cahScan(Event)
    /// Host score entry for one pack of the night.
    case hostScore(HostScoreTarget)
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
        case .cahScan(let event):
            return "cahScan:\(event.id.uuidString)"
        case .hostScore(let target):
            return "hostScore:\(target.id)"
        case .createRoom:
            return "createRoom"
        }
    }
}

/// The one confirmation dialog on the page. A dialog cannot be presented
/// from inside a sheet, so it keeps its own binding — but it is an enum,
/// not a Bool.
enum RoomConfirm: Identifiable, Equatable {
    /// "Score which game?" — the night has more than one scorable pack.
    case scoreChoice(event: Event, packs: [String])

    var id: String {
        switch self {
        case .scoreChoice(let event, let packs):
            return "scoreChoice:\(event.id.uuidString):\(packs.joined(separator: ","))"
        }
    }

    var event: Event {
        switch self {
        case .scoreChoice(let event, _):
            return event
        }
    }

    var packs: [String] {
        switch self {
        case .scoreChoice(_, let packs):
            return packs
        }
    }
}

/// The host's chosen pack for "Score a round".
struct HostScoreTarget: Identifiable, Equatable {
    let event: Event
    let packSlug: String
    var id: String { "\(event.id.uuidString):\(packSlug)" }
}

/// The config sheet the pack shelf is showing. The shelf used to stack
/// three `.sheet` modifiers on one VStack (audit 03 D12); this is the
/// one presenter that replaces them.
enum PackEditor: Identifiable, Equatable {
    /// Single-winner payout ("how much a win pays out").
    case payout(packSlug: String)
    /// Count-based points-per-card (CAH).
    case cahConfig(packSlug: String)
    /// Withdraw/return chip values (Casino's RoomSettingsCasinoSheet).
    case casinoConfig

    var id: String {
        switch self {
        case .payout(let slug):
            return "payout:\(slug)"
        case .cahConfig(let slug):
            return "cahConfig:\(slug)"
        case .casinoConfig:
            return "casinoConfig"
        }
    }

    /// The pack a config sheet edits. Casino's chip sheet is room-wide,
    /// so it has none.
    var packSlug: String? {
        switch self {
        case .payout(let slug), .cahConfig(let slug):
            return slug
        case .casinoConfig:
            return nil
        }
    }
}
