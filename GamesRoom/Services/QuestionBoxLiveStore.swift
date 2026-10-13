//
//  QuestionBoxLiveStore.swift
//  GamesRoom
//
//  V0.106 — Supabase-backed `QuestionBoxStore`. Every method is one
//  migration-097 RPC; see the protocol for the RPC names.
//

import Foundation
import Supabase

private struct SetQuestionBoxSettingsParams: Encodable, Sendable {
    let p_room_id: String
    let p_enabled: Bool
    let p_show_author: Bool
    let p_house_deck: Bool
    let p_cadence_minutes: Int
    let p_speaking_light: Bool
}

private struct UpsertRoomQuestionParams: Encodable, Sendable {
    let p_room_id: String
    let p_id: String?
    let p_text: String
    let p_tag: String?
}

private struct RegisterDeviceTokenParams: Encodable, Sendable {
    let p_device_token: String
    let p_environment: String
    let p_app_version: String?
}

private struct CurrentlyIntoRow: Decodable {
    let text: String?
    let updated_at: Date?
}

final class LiveQuestionBoxStore: QuestionBoxStore, @unchecked Sendable {
    static let shared = LiveQuestionBoxStore()
    private init() {}

    private var client: SupabaseClient { SupabaseClientProvider.shared }

    func fetchQuestionBoxSettings(roomId: UUID) async throws -> QuestionBoxSettings {
        let rows: [QuestionBoxSettings] = try await client
            .rpc("get_question_box_settings", params: ["p_room_id": roomId.uuidString])
            .execute().value
        return rows.first ?? .default
    }

    func setQuestionBoxSettings(roomId: UUID, settings: QuestionBoxSettings) async throws {
        try await client.rpc("set_question_box_settings", params: SetQuestionBoxSettingsParams(
            p_room_id: roomId.uuidString,
            p_enabled: settings.enabled,
            p_show_author: settings.showAuthor,
            p_house_deck: settings.houseDeck,
            p_cadence_minutes: settings.cadenceMinutes,
            p_speaking_light: settings.speakingLight
        )).execute()
    }

    func fetchRoomQuestions(roomId: UUID) async throws -> [RoomQuestion] {
        try await client
            .rpc("get_room_questions", params: ["p_room_id": roomId.uuidString])
            .execute().value
    }

    func upsertRoomQuestion(roomId: UUID, id: UUID?, text: String, tag: QuestionTag?) async throws -> UUID {
        try await client.rpc("upsert_room_question", params: UpsertRoomQuestionParams(
            p_room_id: roomId.uuidString,
            p_id: id?.uuidString,
            p_text: text,
            p_tag: tag?.rawValue
        )).execute().value
    }

    func deleteRoomQuestion(id: UUID) async throws {
        try await client.rpc("delete_room_question", params: ["p_id": id.uuidString]).execute()
    }

    func restoreRoomQuestion(id: UUID) async throws {
        try await client.rpc("restore_room_question", params: ["p_id": id.uuidString]).execute()
    }

    func submitMemberQuestion(eventId: UUID, text: String) async throws {
        try await client.rpc("submit_member_question", params: [
            "p_event_id": eventId.uuidString,
            "p_text": text
        ]).execute()
    }

    func fetchMyMemberQuestion(eventId: UUID) async throws -> String? {
        try await client
            .rpc("get_my_member_question", params: ["p_event_id": eventId.uuidString])
            .execute().value
    }

    func fetchMyCurrentlyInto(roomId: UUID) async throws -> CurrentlyInto {
        let rows: [CurrentlyIntoRow] = try await client
            .rpc("get_my_currently_into", params: ["p_room_id": roomId.uuidString])
            .execute().value
        guard let row = rows.first else { return CurrentlyInto(text: nil, updatedAt: nil) }
        return CurrentlyInto(text: row.text, updatedAt: row.updated_at)
    }

    func setCurrentlyInto(roomId: UUID, text: String) async throws {
        try await client.rpc("set_currently_into", params: [
            "p_room_id": roomId.uuidString,
            "p_text": text
        ]).execute()
    }

    func fetchEventCurrentlyInto(eventId: UUID) async throws -> [MemberCurrentlyInto] {
        try await client
            .rpc("get_event_currently_into", params: ["p_event_id": eventId.uuidString])
            .execute().value
    }

    func questionBoxTick(eventId: UUID) async throws {
        try await client.rpc("question_box_tick", params: ["p_event_id": eventId.uuidString]).execute()
    }

    func fetchQuestionBoxState(eventId: UUID) async throws -> QuestionTurn? {
        let rows: [QuestionTurn] = try await client
            .rpc("get_question_box_state", params: ["p_event_id": eventId.uuidString])
            .execute().value
        return rows.first
    }

    func respondQuestionTurn(turnId: UUID, action: QuestionTurnAction) async throws {
        try await client.rpc("respond_question_turn", params: [
            "p_turn_id": turnId.uuidString,
            "p_action": action.rawValue
        ]).execute()
    }

    func registerDeviceToken(_ token: String, sandbox: Bool, appVersion: String?) async throws {
        try await client.rpc("register_device_token", params: RegisterDeviceTokenParams(
            p_device_token: token,
            p_environment: sandbox ? "sandbox" : "production",
            p_app_version: appVersion
        )).execute()
    }
}
