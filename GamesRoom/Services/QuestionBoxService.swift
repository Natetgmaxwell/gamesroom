//
//  QuestionBoxService.swift
//  GamesRoom
//
//  V0.106 — the one owner of Question Box / Currently Into client
//  state. Views read the @Published caches; mutations round-trip the
//  `QuestionBoxStore` (migration 097 RPCs, or the in-memory store).
//
//  Turn delivery (spec §1.4): the server decides who reads and when.
//  This service only (a) nudges the lazy driver with
//  `question_box_tick` while a live event is on screen, and (b) reads
//  `get_question_box_state`, which returns a row ONLY for the reader
//  and hosts. A realtime insert on `question_turns` (097 publication,
//  same reader-or-host RLS) or a reader push triggers an immediate
//  refresh; the poll is the fallback.
//

import Foundation
import SwiftUI

@MainActor
final class QuestionBoxService: ObservableObject {

    private let store: QuestionBoxStore

    init(store: QuestionBoxStore) {
        self.store = store
    }

    @Published private(set) var settingsByRoom: [UUID: QuestionBoxSettings] = [:]
    @Published private(set) var questionsByRoom: [UUID: [RoomQuestion]] = [:]
    @Published private(set) var myCurrentlyIntoByRoom: [UUID: CurrentlyInto] = [:]
    @Published private(set) var currentlyIntoByEvent: [UUID: [UUID: CurrentlyInto]] = [:]
    @Published private(set) var myQuestionByEvent: [UUID: String] = [:]
    @Published private(set) var turnByEvent: [UUID: QuestionTurn] = [:]
    /// The reader's full-screen card. Non-nil only when THIS device's
    /// user is the reader and hasn't answered Done/Pass.
    @Published var readerCard: QuestionTurn?
    @Published private(set) var lastError: String?

    /// Turn ids the reader already closed locally, so a racing poll
    /// can't re-present the card.
    private var dismissedTurnIds: Set<UUID> = []

    // MARK: Settings

    func settings(roomId: UUID) -> QuestionBoxSettings {
        settingsByRoom[roomId] ?? .default
    }

    @discardableResult
    func loadSettings(roomId: UUID) async -> QuestionBoxSettings {
        do {
            let value = try await store.fetchQuestionBoxSettings(roomId: roomId)
            settingsByRoom[roomId] = value
            return value
        } catch {
            lastError = error.localizedDescription
            return settings(roomId: roomId)
        }
    }

    func saveSettings(roomId: UUID, settings: QuestionBoxSettings) async throws {
        let previous = settingsByRoom[roomId]
        settingsByRoom[roomId] = settings
        do {
            try await store.setQuestionBoxSettings(roomId: roomId, settings: settings)
        } catch {
            settingsByRoom[roomId] = previous
            throw error
        }
    }

    // MARK: Host question list

    func questions(roomId: UUID) -> [RoomQuestion] {
        questionsByRoom[roomId] ?? []
    }

    func loadQuestions(roomId: UUID) async {
        do {
            questionsByRoom[roomId] = try await store.fetchRoomQuestions(roomId: roomId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func saveQuestion(roomId: UUID, id: UUID?, text: String, tag: QuestionTag?) async throws {
        _ = try await store.upsertRoomQuestion(roomId: roomId, id: id, text: text, tag: tag)
        await loadQuestions(roomId: roomId)
    }

    func deleteQuestion(roomId: UUID, id: UUID) async throws {
        try await store.deleteRoomQuestion(id: id)
        await loadQuestions(roomId: roomId)
    }

    func restoreQuestion(roomId: UUID, id: UUID) async throws {
        try await store.restoreRoomQuestion(id: id)
        await loadQuestions(roomId: roomId)
    }

    // MARK: Claimed-card (one ask)

    func myCurrentlyInto(roomId: UUID) -> CurrentlyInto {
        myCurrentlyIntoByRoom[roomId] ?? CurrentlyInto(text: nil, updatedAt: nil)
    }

    func loadClaimedCard(roomId: UUID, eventId: UUID) async {
        async let settings = loadSettings(roomId: roomId)
        do {
            myCurrentlyIntoByRoom[roomId] = try await store.fetchMyCurrentlyInto(roomId: roomId)
            if let text = try await store.fetchMyMemberQuestion(eventId: eventId) {
                myQuestionByEvent[eventId] = text
            }
        } catch {
            lastError = error.localizedDescription
        }
        _ = await settings
    }

    func ask(roomId: UUID, now: Date = Date()) -> ClaimedCardAsk {
        ClaimedCardAsk.resolve(
            currentlyInto: myCurrentlyInto(roomId: roomId),
            questionBoxEnabled: settings(roomId: roomId).enabled,
            now: now
        )
    }

    func submitCurrentlyInto(roomId: UUID, text: String) async {
        let clean = ClaimedCardAsk.sanitize(text, max: CurrentlyInto.maxLength)
        do {
            try await store.setCurrentlyInto(roomId: roomId, text: clean)
            myCurrentlyIntoByRoom[roomId] = CurrentlyInto(text: clean.isEmpty ? nil : clean, updatedAt: Date())
        } catch {
            lastError = error.localizedDescription
        }
    }

    func submitQuestion(eventId: UUID, text: String) async {
        let clean = ClaimedCardAsk.sanitize(text, max: RoomQuestion.maxLength)
        do {
            try await store.submitMemberQuestion(eventId: eventId, text: clean)
            myQuestionByEvent[eventId] = clean.isEmpty ? nil : clean
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Briefing who's-coming

    func loadEventCurrentlyInto(eventId: UUID) async {
        do {
            let rows = try await store.fetchEventCurrentlyInto(eventId: eventId)
            currentlyIntoByEvent[eventId] = Dictionary(
                rows.map { ($0.memberId, CurrentlyInto(text: $0.text, updatedAt: $0.updatedAt)) },
                uniquingKeysWith: { first, _ in first }
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Grey secondary line under a claimed member, or nil (stale/empty).
    func currentlyIntoLine(eventId: UUID, memberId: UUID, now: Date = Date()) -> String? {
        currentlyIntoByEvent[eventId]?[memberId]?.displayText(now: now)
    }

    // MARK: Turns

    /// One driver pass for a live event: nudge the server, then read
    /// what (if anything) this device should show.
    func tick(eventId: UUID) async {
        do {
            try await store.questionBoxTick(eventId: eventId)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshTurn(eventId: eventId)
    }

    func refreshTurn(eventId: UUID) async {
        do {
            let turn = try await store.fetchQuestionBoxState(eventId: eventId)
            turnByEvent[eventId] = turn
            if let turn, turn.isReader, !dismissedTurnIds.contains(turn.id) {
                if readerCard?.id != turn.id { readerCard = turn }
            } else if readerCard?.eventId == eventId {
                readerCard = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func respond(_ turn: QuestionTurn, action: QuestionTurnAction) async {
        dismissedTurnIds.insert(turn.id)
        if readerCard?.id == turn.id { readerCard = nil }
        do {
            try await store.respondQuestionTurn(turnId: turn.id, action: action)
        } catch {
            lastError = error.localizedDescription
        }
        await refreshTurn(eventId: turn.eventId)
    }

    /// Poll cadence while a live event is on screen. The server-side
    /// interval is minutes; 15s keeps the opener within a breath of the
    /// start time without hammering the RPC.
    static var pollInterval: TimeInterval {
        #if DEBUG
        if let raw = CommandLine.arguments.first(where: { $0.hasPrefix("-question-box-poll-seconds=") }),
           let value = TimeInterval(raw.dropFirst("-question-box-poll-seconds=".count)), value > 0 {
            return value
        }
        #endif
        return 15
    }

    /// Runs until the calling `.task` is cancelled (view disappears or
    /// the event changes).
    func driveLiveEvent(eventId: UUID) async {
        while !Task.isCancelled {
            await tick(eventId: eventId)
            try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
        }
    }

    // MARK: Push

    func registerDeviceToken(_ token: String, sandbox: Bool) async {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        do {
            try await store.registerDeviceToken(token, sandbox: sandbox, appVersion: version)
        } catch {
            lastError = error.localizedDescription
        }
    }
}
