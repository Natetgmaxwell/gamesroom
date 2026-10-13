//
//  QuestionBoxStore.swift
//  GamesRoom
//
//  V0.106 — Question Box + Currently Into data surface. A separate
//  protocol from `RoomStore` so the feature lands without widening
//  the 50-method room store. `LiveQuestionBoxStore` (Supabase, in
//  QuestionBoxLiveStore.swift) maps 1:1 to the migration-097 RPCs;
//  `InMemoryRoomStore` conforms below for previews, the harness and
//  the XCUITest bypass path.
//

import Foundation

protocol QuestionBoxStore: Sendable {
    /// `get_question_box_settings(p_room_id)` — any active member.
    func fetchQuestionBoxSettings(roomId: UUID) async throws -> QuestionBoxSettings
    /// `set_question_box_settings(...)` — host only.
    func setQuestionBoxSettings(roomId: UUID, settings: QuestionBoxSettings) async throws

    /// `get_room_questions(p_room_id)` — host only; includes authorship.
    func fetchRoomQuestions(roomId: UUID) async throws -> [RoomQuestion]
    /// `upsert_room_question(...)` — host only. `id == nil` adds a host question.
    func upsertRoomQuestion(roomId: UUID, id: UUID?, text: String, tag: QuestionTag?) async throws -> UUID
    /// `delete_room_question(p_id)` — host only.
    func deleteRoomQuestion(id: UUID) async throws
    /// `restore_room_question(p_id)` — host only; clears drawn_at.
    func restoreRoomQuestion(id: UUID) async throws

    /// `submit_member_question(p_event_id, p_text)` — empty clears.
    func submitMemberQuestion(eventId: UUID, text: String) async throws
    /// `get_my_member_question(p_event_id)`.
    func fetchMyMemberQuestion(eventId: UUID) async throws -> String?

    /// `get_my_currently_into(p_room_id)`.
    func fetchMyCurrentlyInto(roomId: UUID) async throws -> CurrentlyInto
    /// `set_currently_into(p_room_id, p_text)` — server stamps updated_at.
    func setCurrentlyInto(roomId: UUID, text: String) async throws
    /// `get_event_currently_into(p_event_id)` — claimed members only.
    func fetchEventCurrentlyInto(eventId: UUID) async throws -> [MemberCurrentlyInto]

    /// `question_box_tick(p_event_id)` — writes a turn only when one is due.
    func questionBoxTick(eventId: UUID) async throws
    /// `get_question_box_state(p_event_id)` — reader or host only.
    func fetchQuestionBoxState(eventId: UUID) async throws -> QuestionTurn?
    /// `respond_question_turn(p_turn_id, p_action)`.
    func respondQuestionTurn(turnId: UUID, action: QuestionTurnAction) async throws

    /// `register_device_token(...)` — APNs registration for reader pushes.
    func registerDeviceToken(_ token: String, sandbox: Bool, appVersion: String?) async throws
}

// MARK: - In-memory conformance

/// In-memory question-box state, owned by `InMemoryRoomStore`.
struct InMemoryQuestionBoxState {
    var settings: [UUID: QuestionBoxSettings] = [:]
    var questions: [UUID: [RoomQuestion]] = [:]
    var currentlyInto: [UUID: [UUID: CurrentlyInto]] = [:]
    var withdrawals: [UUID: [QuestionBoxRotation.Withdrawal]] = [:]
    var turns: [UUID: [StoredTurn]] = [:]
    var readerIndex: [UUID: Int] = [:]
    var deviceTokens: Set<String> = []

    struct StoredTurn {
        let id: UUID
        let readerId: UUID
        let questionId: UUID?
        let text: String
        let kind: String
        let createdAt: Date
        var closed: Bool
    }

    /// DEBUG/UITest: seconds per cadence "minute" (60 in production).
    static var secondsPerMinute: TimeInterval = {
        #if DEBUG
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("-question-box-minute-seconds=") }),
           let value = TimeInterval(raw.dropFirst("-question-box-minute-seconds=".count)), value > 0 {
            return value
        }
        #endif
        return 60
    }()
}

extension InMemoryRoomStore: QuestionBoxStore {

    private func qbSettings(_ roomId: UUID) -> QuestionBoxSettings {
        questionBox.settings[roomId] ?? .default
    }

    private func qbSeedDeckIfNeeded(_ roomId: UUID) {
        guard questionBox.questions[roomId] == nil else { return }
        questionBox.questions[roomId] = QuestionBoxHouseDeck.entries.map { entry in
            RoomQuestion(
                id: UUID(), roomId: roomId, eventId: nil, source: .house,
                text: entry.text, tag: entry.tag, drawnAt: nil,
                createdAt: Date(timeIntervalSince1970: 0), authorId: nil, authorDisplayName: nil
            )
        }
    }

    func fetchQuestionBoxSettings(roomId: UUID) async throws -> QuestionBoxSettings {
        qbSettings(roomId)
    }

    func setQuestionBoxSettings(roomId: UUID, settings: QuestionBoxSettings) async throws {
        guard QuestionBoxSettings.cadenceOptions.contains(settings.cadenceMinutes) else {
            throw NSError(domain: "QuestionBox", code: 22023,
                          userInfo: [NSLocalizedDescriptionKey: "invalid cadence"])
        }
        questionBox.settings[roomId] = settings
    }

    func fetchRoomQuestions(roomId: UUID) async throws -> [RoomQuestion] {
        qbSeedDeckIfNeeded(roomId)
        let rank: (QuestionSource) -> Int = { $0 == .member ? 0 : ($0 == .host ? 1 : 2) }
        return (questionBox.questions[roomId] ?? []).enumerated().sorted { lhs, rhs in
            rank(lhs.element.source) == rank(rhs.element.source)
                ? lhs.offset < rhs.offset
                : rank(lhs.element.source) < rank(rhs.element.source)
        }.map(\.element)
    }

    func upsertRoomQuestion(roomId: UUID, id: UUID?, text: String, tag: QuestionTag?) async throws -> UUID {
        qbSeedDeckIfNeeded(roomId)
        let clean = ClaimedCardAsk.sanitize(text, max: RoomQuestion.maxLength)
        guard !clean.isEmpty else {
            throw NSError(domain: "QuestionBox", code: 23514,
                          userInfo: [NSLocalizedDescriptionKey: "Question can't be empty."])
        }
        var rows = questionBox.questions[roomId] ?? []
        if let id, let idx = rows.firstIndex(where: { $0.id == id }) {
            rows[idx].text = clean
            rows[idx].tag = tag
            questionBox.questions[roomId] = rows
            return id
        }
        let new = RoomQuestion(
            id: UUID(), roomId: roomId, eventId: nil, source: .host, text: clean, tag: tag,
            drawnAt: nil, createdAt: Date(), authorId: nil, authorDisplayName: nil
        )
        rows.append(new)
        questionBox.questions[roomId] = rows
        return new.id
    }

    func deleteRoomQuestion(id: UUID) async throws {
        for (roomId, rows) in questionBox.questions {
            questionBox.questions[roomId] = rows.filter { $0.id != id }
        }
    }

    func restoreRoomQuestion(id: UUID) async throws {
        for (roomId, rows) in questionBox.questions {
            if let idx = rows.firstIndex(where: { $0.id == id }) {
                questionBox.questions[roomId]?[idx].drawnAt = nil
            }
        }
    }

    func submitMemberQuestion(eventId: UUID, text: String) async throws {
        guard let roomId = roomIdForEvent(eventId) else { return }
        qbSeedDeckIfNeeded(roomId)
        let me = qbCurrentMemberId()
        let clean = ClaimedCardAsk.sanitize(text, max: RoomQuestion.maxLength)
        var rows = questionBox.questions[roomId] ?? []
        let existing = rows.firstIndex { $0.source == .member && $0.eventId == eventId && $0.authorId == me }
        if clean.isEmpty {
            if let existing, rows[existing].drawnAt == nil { rows.remove(at: existing) }
        } else if let existing {
            if rows[existing].drawnAt == nil { rows[existing].text = clean }
        } else {
            rows.append(RoomQuestion(
                id: UUID(), roomId: roomId, eventId: eventId, source: .member, text: clean, tag: nil,
                drawnAt: nil, createdAt: Date(), authorId: me, authorDisplayName: "Host"
            ))
        }
        questionBox.questions[roomId] = rows
    }

    func fetchMyMemberQuestion(eventId: UUID) async throws -> String? {
        guard let roomId = roomIdForEvent(eventId) else { return nil }
        let me = qbCurrentMemberId()
        return questionBox.questions[roomId]?
            .first { $0.source == .member && $0.eventId == eventId && $0.authorId == me }?.text
    }

    func fetchMyCurrentlyInto(roomId: UUID) async throws -> CurrentlyInto {
        questionBox.currentlyInto[roomId]?[qbCurrentMemberId()] ?? CurrentlyInto(text: nil, updatedAt: nil)
    }

    func setCurrentlyInto(roomId: UUID, text: String) async throws {
        let clean = ClaimedCardAsk.sanitize(text, max: CurrentlyInto.maxLength)
        questionBox.currentlyInto[roomId, default: [:]][qbCurrentMemberId()] =
            CurrentlyInto(text: clean.isEmpty ? nil : clean, updatedAt: Date())
    }

    /// Mirrors the 097 RPC row set (claimed members with a value) but
    /// does NOT apply the 30-day filter, so the client gate is what the
    /// XCUITest exercises. The server filters too (tests/sql/097).
    func fetchEventCurrentlyInto(eventId: UUID) async throws -> [MemberCurrentlyInto] {
        guard let roomId = roomIdForEvent(eventId) else { return [] }
        let claimed = try await fetchEventRSVPs(eventId: eventId).filter { $0.state == .claimed }
        let values = questionBox.currentlyInto[roomId] ?? [:]
        return claimed.compactMap { rsvp in
            guard let value = values[rsvp.memberId], let text = value.text, let at = value.updatedAt else { return nil }
            return MemberCurrentlyInto(memberId: rsvp.memberId, text: text, updatedAt: at)
        }
    }

    func questionBoxTick(eventId: UUID) async throws {
        guard let event = eventById(eventId) else { return }
        let settings = qbSettings(event.roomId)
        let turns = questionBox.turns[eventId] ?? []
        // Same rule as the server; the DEBUG minute scale shifts the
        // previous turn back so a "minute" can be seconds in UI tests.
        let minute = InMemoryQuestionBoxState.secondsPerMinute
        let shift = TimeInterval(settings.cadenceMinutes) * (60 - minute)
        let decision = QuestionBoxCadence.decide(
            now: Date(),
            playedAt: event.playedAt,
            settledAt: event.settledAt,
            enabled: settings.enabled,
            cadenceMinutes: settings.cadenceMinutes,
            lastTurnAt: turns.last.map { $0.createdAt.addingTimeInterval(-shift) }
        )
        let due = decision != .none
        guard due else { return }
        let isOpener = turns.isEmpty
        let rotation = try await qbRotation(eventId: eventId)
        let index = questionBox.readerIndex[eventId] ?? 0
        guard let reader = QuestionBoxRotation.reader(
            isOpener: isOpener, hostId: qbCurrentMemberId(), rotation: rotation, index: index
        ), let question = qbDraw(roomId: event.roomId, eventId: eventId, houseDeck: settings.houseDeck) else { return }
        qbCloseOpenTurns(eventId)
        questionBox.turns[eventId, default: []].append(.init(
            id: UUID(), readerId: reader, questionId: question.id, text: question.text,
            kind: isOpener ? "opener" : "interval", createdAt: Date(), closed: false
        ))
        if !isOpener { questionBox.readerIndex[eventId] = index + 1 }
    }

    private func qbRotation(eventId: UUID) async throws -> [UUID] {
        let claims = try await fetchEventRSVPs(eventId: eventId)
            .filter { $0.state == .claimed }
            .enumerated()
            .map { QuestionBoxRotation.Claim(memberId: $0.element.memberId, at: Date(timeIntervalSince1970: Double($0.offset))) }
        return QuestionBoxRotation.order(withdrawals: questionBox.withdrawals[eventId] ?? [], claims: claims)
    }

    private func qbDraw(roomId: UUID, eventId: UUID, houseDeck: Bool) -> RoomQuestion? {
        qbSeedDeckIfNeeded(roomId)
        var rows = questionBox.questions[roomId] ?? []
        let pool = rows.indices.filter { idx in
            let q = rows[idx]
            guard q.drawnAt == nil else { return false }
            switch q.source {
            case .member: return q.eventId == eventId
            case .host: return true
            case .house: return houseDeck
            }
        }
        let rank: (QuestionSource) -> Int = { $0 == .member ? 0 : ($0 == .host ? 1 : 2) }
        guard let pick = pool.min(by: { lhs, rhs in
            rank(rows[lhs].source) == rank(rows[rhs].source) ? lhs < rhs : rank(rows[lhs].source) < rank(rows[rhs].source)
        }) else { return nil }
        rows[pick].drawnAt = Date()
        questionBox.questions[roomId] = rows
        return rows[pick]
    }

    private func qbCloseOpenTurns(_ eventId: UUID) {
        guard var list = questionBox.turns[eventId] else { return }
        for idx in list.indices { list[idx].closed = true }
        questionBox.turns[eventId] = list
    }

    func fetchQuestionBoxState(eventId: UUID) async throws -> QuestionTurn? {
        guard let event = eventById(eventId),
              let turn = questionBox.turns[eventId]?.last, !turn.closed else { return nil }
        let me = qbCurrentMemberId()
        let room = roomById(event.roomId)
        let isHost = room?.userRole == .host
        guard turn.readerId == me || isHost else { return nil }
        let members = try await fetchRoomMembers(roomId: event.roomId)
        let name: (UUID) -> String = { id in members.first { $0.userId == id }?.displayName ?? "Member" }
        let settings = qbSettings(event.roomId)
        let rotation = try await qbRotation(eventId: eventId)
        let answerFirst = QuestionBoxRotation.next(after: turn.readerId, rotation: rotation).map(name)
        let question = questionBox.questions[event.roomId]?.first { $0.id == turn.questionId }
        return QuestionTurn(
            id: turn.id, eventId: eventId, readerId: turn.readerId,
            readerDisplayName: name(turn.readerId), questionText: turn.text,
            askedBy: settings.showAuthor ? question?.authorDisplayName : nil,
            kind: turn.kind, createdAt: turn.createdAt, isReader: turn.readerId == me,
            speakingLight: settings.speakingLight, answerFirstDisplayName: answerFirst
        )
    }

    func respondQuestionTurn(turnId: UUID, action: QuestionTurnAction) async throws {
        for (eventId, list) in questionBox.turns {
            guard let idx = list.firstIndex(where: { $0.id == turnId }), !list[idx].closed else { continue }
            let turn = list[idx]
            questionBox.turns[eventId]?[idx].closed = true
            if action == .pass,
               let next = QuestionBoxRotation.next(after: turn.readerId, rotation: try await qbRotation(eventId: eventId)) {
                questionBox.turns[eventId, default: []].append(.init(
                    id: UUID(), readerId: next, questionId: turn.questionId, text: turn.text,
                    kind: "pass", createdAt: turn.createdAt, closed: false
                ))
            }
            return
        }
    }

    func registerDeviceToken(_ token: String, sandbox: Bool, appVersion: String?) async throws {
        questionBox.deviceTokens.insert(token)
    }
}
