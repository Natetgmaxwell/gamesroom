//
//  MascotVoiceService.swift
//  GamesRoom
//
//  V0.81 — transport for server-side mascot caption generation.
//
//  POSTs {room_id, event_id?} to the `mascot-voice` edge function
//  with the caller's Supabase JWT. The edge function reads the
//  room's mascot settings (name, personality, ideology) and live
//  state (active event, leaderboard, members, working hand) from
//  the DB — the authoritative source — calls MiniMax-M3 with
//  thinking disabled, and returns {caption}. The MiniMax key lives
//  ONLY in edge secrets; the client never sees it.
//
//  Why its own URLSession: the shared `SupabaseClientProvider`
//  session has a 15s request timeout; the edge function allows the
//  MiniMax call up to 20s. A shared-session call would abort
//  client-side while the server still generates.
//

import Foundation

enum MascotVoiceService {

    // MARK: - Errors

    enum MascotVoiceError: LocalizedError {
        case badStatus(Int)
        case emptyCaption
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .badStatus(let code):
                return "Mascot voice service returned HTTP \(code)."
            case .emptyCaption:
                return "Mascot voice service returned an empty caption."
            case .invalidResponse:
                return "Couldn't read the mascot voice service response."
            }
        }
    }

    // MARK: - Wire

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        config.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: config)
    }()

    /// `{SUPABASE_URL}/functions/v1/mascot-voice`. Same
    /// fallback-and-validate pattern as `SupabaseClientProvider` /
    /// `ScanSettleService`: read Info.plist, guard against `$(...)`
    /// build-setting unsubstitution, fall back to the compiled
    /// default.
    private static var defaultEndpoint: URL {
        let fallbackURL = "https://bnrgkdcluopicqdpmrtu.supabase.co"
        let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        let urlString = (raw?.isEmpty ?? true) || raw?.hasPrefix("$(") == true
            ? fallbackURL
            : raw!
        let base = URL(string: urlString) ?? URL(string: fallbackURL)!
        return base.appendingPathComponent("functions/v1/mascot-voice")
    }

    private static var anonKey: String {
        let fallback = "MISSING_SUPABASE_ANON_KEY_CONFIG_ERROR"
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !raw.isEmpty,
              !raw.hasPrefix("$(") else {
            return fallback
        }
        return raw
    }

    // MARK: - Public API

    /// POSTs the room/event ids and returns the generated caption.
    /// Throws on transport failure, non-200, or a missing caption —
    /// the caller (MascotEngine) falls back to the template.
    static func fetchCaption(
        roomId: UUID,
        eventId: UUID?,
        authToken: String,
        endpoint: URL? = nil
    ) async throws -> String {
        let url = endpoint ?? defaultEndpoint
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["room_id": roomId.uuidString]
        if let eventId {
            body["event_id"] = eventId.uuidString
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw MascotVoiceError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw MascotVoiceError.badStatus(http.statusCode)
        }

        let decoded: VoiceResponse
        do {
            decoded = try JSONDecoder().decode(VoiceResponse.self, from: data)
        } catch {
            throw MascotVoiceError.invalidResponse
        }
        guard !decoded.caption.isEmpty else {
            throw MascotVoiceError.emptyCaption
        }
        return decoded.caption
    }

    // MARK: - Response DTO

    struct VoiceResponse: Decodable {
        let caption: String
    }
}
