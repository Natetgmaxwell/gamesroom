//
//  BroughtBy.swift
//  GamesRoom
//
//  V0.107 (slice S5a) — the "brought by" caption formatter.
//
//  Foundation only, no state. Every surface that shows who a
//  newcomer came with goes through `caption(...)`, so the wording
//  is decided in exactly one place:
//
//    briefing     "with Alex · first night · into bouldering"
//    seat grid    "Sam, with Alex"   (accessibility label)
//    pending      "via Alex"         (caption under the name)
//
//  Rules (spec §2, §3):
//
//    1. Order inside the caption is anchor, then first night, then
//       Currently Into. A missing part drops out with its separator,
//       so there is never a dangling " · ".
//    2. "First night" is passed in by the caller; this formatter
//       does not know what a night is.
//    3. With the room setting off, the anchor and first-night text
//       disappear everywhere and the caption is whatever the room
//       already showed for Currently Into. The setting never
//       changes the member's own words, so the Currently Into part
//       is built the same way either way.
//    4. Members type their own Currently Into value, and some of
//       them type the leading "into " themselves. Prefix it once,
//       never twice.
//    5. A member with no inviter (tier 1 host, tier 3 open code),
//       or one whose inviter is gone, shows no anchor. The caller
//       resolves that and passes nil.
//

import Foundation

enum BroughtBy {

    // MARK: - Briefing caption

    /// The grey line under a name. nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - anchorName: inviter's display name, nil when unknown.
    ///   - firstNight: the member has not played a night in the room.
    ///   - currentlyInto: the member's own Currently Into value.
    ///   - enabled: the room's "Show who brought newcomers" setting.
    static func caption(anchorName: String?,
                        firstNight: Bool,
                        currentlyInto: String?,
                        enabled: Bool) -> String? {
        let into = intoPart(currentlyInto)
        guard enabled else { return into }

        var parts: [String] = []
        if let anchor = nonEmpty(anchorName) {
            parts.append("with \(anchor)")
        }
        if firstNight {
            parts.append("first night")
        }
        if let into {
            parts.append(into)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Seat grid

    /// VoiceOver label for a claimed seat: "Sam, with Alex".
    static func seatLabel(name: String, anchorName: String?, enabled: Bool) -> String {
        guard enabled, let anchor = nonEmpty(anchorName) else { return name }
        return "\(name), with \(anchor)"
    }

    // MARK: - Pending invites

    /// Caption under a pending invite's name: "via Alex". nil when
    /// there is nothing to say, so the caller leaves the line out
    /// rather than rendering an empty one.
    static func viaLabel(anchorName: String?, enabled: Bool) -> String? {
        guard enabled, let anchor = nonEmpty(anchorName) else { return nil }
        return "via \(anchor)"
    }

    // MARK: - Parts

    /// "into bouldering", or the member's own text when they already
    /// wrote the "into " themselves.
    static func intoPart(_ raw: String?) -> String? {
        guard let text = nonEmpty(raw) else { return nil }
        if text.lowercased().hasPrefix("into ") { return text }
        return "into \(text)"
    }

    /// Trimmed, or nil when there is nothing left to show.
    static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}