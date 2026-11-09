//
//  InviteCodePhase.swift
//  GamesRoom
//
//  P2 (audit 03 C6) — the empty-room hero's join code, named.
//
//  The hero used three flags: `heroJoinCode`, `isMintingHeroCode` and
//  `heroCodeError`. A retry did not clear the old error until the new
//  code landed (`mintHeroJoinCode` only cleared on success), so a second
//  attempt showed the previous failure for its whole round trip.
//

import Foundation

enum InviteCodePhase: Equatable {
    /// No code, nothing in flight. Also the state after a room with a
    /// table stops showing the hero.
    case idle
    /// The mint RPC is in flight. The action is disabled.
    case minting
    /// The code is minted and the hero offers the share sheet.
    case ready(String)
    /// The mint failed. The line under the action says so, and a tap
    /// mints again.
    case failed(String)

    /// The one line a failed mint shows.
    static let failureMessage = "Couldn't make a join code. Try again."

    var code: String? {
        if case .ready(let code) = self { return code }
        return nil
    }

    var isMinting: Bool {
        if case .minting = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
