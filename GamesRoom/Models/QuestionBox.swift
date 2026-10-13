//
//  QuestionBox.swift
//  GamesRoom
//
//  V0.106 — Question Box + Currently Into. Pure Foundation so the
//  harness (`build-and-run-tests.sh`) can test the rules directly.
//  Server-side twins live in migration 097; these mirror them for the
//  in-memory store and the UI gates.
//

import Foundation

// MARK: - Settings

/// Room-level Question Box settings (rooms.question_* columns, 097).
struct QuestionBoxSettings: Codable, Hashable {
    var enabled: Bool
    var showAuthor: Bool
    var houseDeck: Bool
    /// 0 = off; else 10 / 20 / 30.
    var cadenceMinutes: Int
    var speakingLight: Bool

    static let `default` = QuestionBoxSettings(
        enabled: true, showAuthor: false, houseDeck: true,
        cadenceMinutes: 20, speakingLight: true
    )

    static let cadenceOptions: [Int] = [10, 20, 30, 0]

    enum CodingKeys: String, CodingKey {
        case enabled = "question_box_enabled"
        case showAuthor = "question_show_author"
        case houseDeck = "question_house_deck"
        case cadenceMinutes = "question_cadence_minutes"
        case speakingLight = "question_speaking_light"
    }

    init(enabled: Bool, showAuthor: Bool, houseDeck: Bool, cadenceMinutes: Int, speakingLight: Bool) {
        self.enabled = enabled
        self.showAuthor = showAuthor
        self.houseDeck = houseDeck
        self.cadenceMinutes = cadenceMinutes
        self.speakingLight = speakingLight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        showAuthor = try c.decodeIfPresent(Bool.self, forKey: .showAuthor) ?? d.showAuthor
        houseDeck = try c.decodeIfPresent(Bool.self, forKey: .houseDeck) ?? d.houseDeck
        cadenceMinutes = try c.decodeIfPresent(Int.self, forKey: .cadenceMinutes) ?? d.cadenceMinutes
        speakingLight = try c.decodeIfPresent(Bool.self, forKey: .speakingLight) ?? d.speakingLight
    }
}

// MARK: - Questions

enum QuestionSource: String, Codable, Hashable {
    case member, host, house
}

/// One `room_questions` row as the host sees it (get_room_questions).
struct RoomQuestion: Identifiable, Codable, Hashable {
    let id: UUID
    let roomId: UUID
    let eventId: UUID?
    let source: QuestionSource
    var text: String
    var tag: QuestionTag?
    var drawnAt: Date?
    let createdAt: Date
    let authorId: UUID?
    let authorDisplayName: String?

    static let maxLength = 140

    enum CodingKeys: String, CodingKey {
        case id, source, text, tag
        case roomId = "room_id"
        case eventId = "event_id"
        case drawnAt = "drawn_at"
        case createdAt = "created_at"
        case authorId = "author_id"
        case authorDisplayName = "author_display_name"
    }
}

// MARK: - Turns

/// `get_question_box_state(p_event_id)` row (097). Only the reader and
/// hosts ever receive one. `askedBy` is nil unless the room shows
/// authorship — the anonymity guarantee lives server-side.
struct QuestionTurn: Identifiable, Codable, Hashable {
    let id: UUID
    let eventId: UUID
    let readerId: UUID
    let readerDisplayName: String
    let questionText: String
    let askedBy: String?
    let kind: String
    let createdAt: Date
    let isReader: Bool
    let speakingLight: Bool
    let answerFirstDisplayName: String?

    enum CodingKeys: String, CodingKey {
        case id = "turn_id"
        case eventId = "event_id"
        case readerId = "reader_id"
        case readerDisplayName = "reader_display_name"
        case questionText = "question_text"
        case askedBy = "asked_by"
        case kind
        case createdAt = "created_at"
        case isReader = "is_reader"
        case speakingLight = "speaking_light"
        case answerFirstDisplayName = "answer_first_display_name"
    }

    /// Ritual opener above the question (spec §1.4 / §1.5).
    static let ritualLine = "Question from the box:"

    var answerFirstLine: String? {
        guard let name = answerFirstDisplayName, !name.isEmpty else { return nil }
        return "Pick who answers first — maybe \(name)?"
    }
}

enum QuestionTurnAction: String {
    case done, pass
}

// MARK: - Rotation (spec §1.4 "Who")

enum QuestionBoxRotation {
    /// A withdrawal-ledger row for tonight's event.
    struct Withdrawal: Hashable {
        let memberId: UUID
        let at: Date
    }

    /// A claimed RSVP, with its claim time.
    struct Claim: Hashable {
        let memberId: UUID
        let at: Date
    }

    /// Members who withdrew tonight, ordered by first withdrawal. When
    /// nobody withdrew (no bank), claimed members in claim order.
    /// Ties break on uuid so the order is deterministic, matching 097.
    static func order(withdrawals: [Withdrawal], claims: [Claim]) -> [UUID] {
        if !withdrawals.isEmpty {
            var first: [UUID: Date] = [:]
            for w in withdrawals {
                if let existing = first[w.memberId], existing <= w.at { continue }
                first[w.memberId] = w.at
            }
            return first.sorted { lhs, rhs in
                lhs.value == rhs.value
                    ? lhs.key.uuidString.lowercased() < rhs.key.uuidString.lowercased()
                    : lhs.value < rhs.value
            }.map(\.key)
        }
        return claims.sorted { lhs, rhs in
            lhs.at == rhs.at
                ? lhs.memberId.uuidString.lowercased() < rhs.memberId.uuidString.lowercased()
                : lhs.at < rhs.at
        }.map(\.memberId)
    }

    /// Reader for the turn. The opener (no prior turns) is always the
    /// host; after that `rotation[index % count]`.
    static func reader(isOpener: Bool, hostId: UUID, rotation: [UUID], index: Int) -> UUID? {
        if isOpener { return hostId }
        guard !rotation.isEmpty else { return nil }
        return rotation[((index % rotation.count) + rotation.count) % rotation.count]
    }

    /// Pass hands the turn to the next person in rotation. A reader not
    /// in the rotation (e.g. the host passing the opener) hands to the
    /// first person. Nil when nobody else is eligible.
    static func next(after readerId: UUID, rotation: [UUID]) -> UUID? {
        guard !rotation.isEmpty else { return nil }
        let pos = rotation.firstIndex(of: readerId).map { $0 + 1 } ?? 0
        let next = rotation[pos % rotation.count]
        return next == readerId ? nil : next
    }
}

// MARK: - Cadence (spec §1.4 "When", steer #2: fixed interval only)

enum QuestionBoxCadence {
    enum Decision: Equatable {
        case none
        case opener
        case interval
    }

    /// The only trigger is time. Opener once the event is live; then one
    /// turn every `cadenceMinutes` from the previous turn; nothing after
    /// settle; `cadenceMinutes == 0` (off) allows only the opener.
    static func decide(
        now: Date,
        playedAt: Date,
        settledAt: Date?,
        enabled: Bool,
        cadenceMinutes: Int,
        lastTurnAt: Date?
    ) -> Decision {
        guard enabled, settledAt == nil, playedAt <= now else { return .none }
        guard let last = lastTurnAt else { return .opener }
        guard cadenceMinutes > 0 else { return .none }
        let due = last.addingTimeInterval(TimeInterval(cadenceMinutes * 60))
        return now >= due ? .interval : .none
    }

    static func label(for minutes: Int) -> String {
        minutes == 0 ? "Off" : "Every \(minutes) min"
    }
}

// MARK: - Currently Into (spec §2)

struct CurrentlyInto: Codable, Hashable {
    let text: String?
    let updatedAt: Date?

    static let maxLength = 60
    static let freshDays = 30

    enum CodingKeys: String, CodingKey {
        case text
        case updatedAt = "updated_at"
    }

    /// Non-empty and updated within the last 30 days.
    func isFresh(now: Date = Date()) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) <= TimeInterval(Self.freshDays * 86_400)
    }

    /// Briefing display text: nil when stale or empty (no placeholder).
    func displayText(now: Date = Date()) -> String? {
        isFresh(now: now) ? text?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}

/// `get_event_currently_into(p_event_id)` row.
struct MemberCurrentlyInto: Codable, Hashable {
    let memberId: UUID
    let text: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case memberId = "member_id"
        case text
        case updatedAt = "updated_at"
    }
}

// MARK: - One-ask rule (spec §3)

enum ClaimedCardAsk: Equatable {
    case currentlyInto(prefill: String)
    case question
    case none

    static func resolve(
        currentlyInto: CurrentlyInto,
        questionBoxEnabled: Bool,
        now: Date = Date()
    ) -> ClaimedCardAsk {
        if !currentlyInto.isFresh(now: now) {
            return .currentlyInto(prefill: currentlyInto.text ?? "")
        }
        return questionBoxEnabled ? .question : .none
    }

    /// Clamps member input to the field cap; whitespace-only is empty.
    static func sanitize(_ raw: String, max: Int) -> String {
        String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }
}

// MARK: - Speaking light (steer #2)

/// The torch seam. `AVTorch` in the app; a fake in tests.
protocol TorchControlling: AnyObject {
    var hasTorch: Bool { get }
    /// Returns false when the torch is unavailable or busy.
    func setOn(level: Float) -> Bool
    func setOff()
}

/// Steady low glow while the reader's card is open. Off on Done/Pass,
/// on card dismiss, on background, and automatically after 3 minutes.
/// Never flashes: one `setOn` per card open, one `setOff` per close.
final class SpeakingLightController {
    static let level: Float = 0.1
    static let autoOffSeconds: TimeInterval = 180

    private let torch: TorchControlling
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private var generation = 0
    private(set) var isOn = false

    init(
        torch: TorchControlling,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    ) {
        self.torch = torch
        self.schedule = schedule
    }

    /// Card opened. No-op when the room setting is off, the device has
    /// no torch, or the torch is busy (silent skip).
    func cardOpened(settingEnabled: Bool) {
        guard settingEnabled, !isOn, torch.hasTorch else { return }
        guard torch.setOn(level: Self.level) else { return }
        isOn = true
        generation += 1
        let mine = generation
        schedule(Self.autoOffSeconds) { [weak self] in
            guard let self, self.generation == mine else { return }
            self.turnOff()
        }
    }

    /// Done, Pass, dismiss, or app backgrounded.
    func cardClosed() {
        turnOff()
    }

    private func turnOff() {
        guard isOn else { return }
        isOn = false
        generation += 1
        torch.setOff()
    }
}
