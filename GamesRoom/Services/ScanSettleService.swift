//
//  ScanSettleService.swift
//  GamesRoom
//
//  V0.72 slice 3 — transport for authoritative hosted counts.
//
//  Posts the captured JPEG to the `scan-settle` edge function (slice 2,
//  deployed). The model's count is final and recorded server-side via
//  service role (migration 069 RPCs). The member client never posts a
//  count — the count comes back in the response body and is rendered
//  read-only on the result screen.
//
//  Photo bytes transit to the cloud vision model and are never stored
//  server-side: the edge function hashes + discards the JPEG (the
//  SHA-256 hash rides in the response so a disputed count can be
//  matched to its capture frame).
//
//  Why its own URLSession
//  ----------------------
//  The shared `SupabaseClientProvider` session has a 15s request
//  timeout; the edge function allows the MiniMax call up to 55s. A
//  shared-session call would abort client-side while the server still
//  records the scan — the member would see "offline" but the count
//  would land on the ledger. This service uses a fresh ephemeral
//  URLSession with its own (75s request, 90s resource) timeouts so
//  the in-flight round-trip is tolerated.
//

import Foundation

@MainActor
final class ScanSettleService: ObservableObject {

    // MARK: - Errors

    enum ScanSettleError: LocalizedError {
        case offline
        case rateLimited(attemptsUsed: Int)
        case modelDeclined
        case unreadable
        case serviceDown
        case unauthorized
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .offline:
                return "You're offline — check your connection and try again."
            case .rateLimited(let attemptsUsed):
                return "Scan limit reached (\(attemptsUsed) per night). Ask your host to enter the count by hand."
            case .modelDeclined, .unreadable:
                return "Couldn't read the table — improve lighting and retake."
            case .serviceDown:
                return "Scanning is briefly unavailable. Try again in a moment."
            case .unauthorized:
                return "Please sign in again."
            case .invalidResponse:
                return "Couldn't read the scan service response."
            case .server(let msg):
                return "Scan failed: \(msg)."
            }
        }
    }

    // MARK: - Response DTOs

    /// 5 attempts per event per spec; the server enforces the same
    /// cap and returns 429 with an `attempts_used` body.
    static let maxAttempts = 5

    // MARK: - Wire

    private let urlSession: URLSession
    private let baseURL: URL
    private let endpoint: URL
    private let anonKey: String

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 75
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 6
        self.urlSession = URLSession(configuration: config)

        // Same fallback-and-validate pattern as SupabaseClientProvider:
        // read Info.plist, guard against `$(...)` build-setting
        // unsubstitution, validate URL + host, fall back to the
        // compiled default. Mirrored here so the service stays
        // independent of SupabaseClientProvider's internal symbols.
        let fallbackURL = "https://bnrgkdcluopicqdpmrtu.supabase.co"
        let fallbackKey = "MISSING_SUPABASE_ANON_KEY_CONFIG_ERROR"

        func readConfig(_ key: String, fallback: String) -> String {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !raw.isEmpty,
                  !raw.hasPrefix("$(") else {
                return fallback
            }
            return raw
        }

        let urlString = readConfig("SUPABASE_URL", fallback: fallbackURL)
        let url: URL
        if let parsed = URL(string: urlString),
           let host = parsed.host,
           !host.isEmpty {
            url = parsed
        } else {
            url = URL(string: fallbackURL) ?? URL(string: "https://example.com")!
        }
        self.baseURL = url
        self.endpoint = URL(string: "\(url.absoluteString)/functions/v1/scan-settle")
            ?? url
        self.anonKey = readConfig("SUPABASE_ANON_KEY", fallback: fallbackKey)
    }

    // MARK: - Public API

    func submitChips(eventId: UUID, jpeg: Data) async throws -> ScanSettleChipsResult {
        let data = try await post(kind: "chips", eventId: eventId, jpeg: jpeg)
        do {
            return try JSONDecoder().decode(ScanSettleChipsResult.self, from: data)
        } catch {
            throw ScanSettleError.invalidResponse
        }
    }

    func submitCards(eventId: UUID, jpeg: Data) async throws -> ScanSettleCardsResult {
        let data = try await post(kind: "cards", eventId: eventId, jpeg: jpeg)
        do {
            return try JSONDecoder().decode(ScanSettleCardsResult.self, from: data)
        } catch {
            throw ScanSettleError.invalidResponse
        }
    }

    // MARK: - Private

    private struct ErrorBody: Decodable {
        let error: String?
        let reason: String?
        let detail: String?
        let attemptsUsed: Int?

        enum CodingKeys: String, CodingKey {
            case error
            case reason
            case detail
            case attemptsUsed = "attempts_used"
        }
    }

    private func post(kind: String, eventId: UUID, jpeg: Data) async throws -> Data {
        guard let auth = await SupabaseClientProvider.currentSession() else {
            throw ScanSettleError.unauthorized
        }
        let token = auth.accessToken

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "kind": kind,
            "event_id": eventId.uuidString,
            "image_base64": jpeg.base64EncodedString()
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let urlError as URLError {
            switch urlError.code {
            case .notConnectedToInternet,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .timedOut,
                 .dnsLookupFailed:
                throw ScanSettleError.offline
            default:
                throw ScanSettleError.server(urlError.localizedDescription)
            }
        }

        guard let http = response as? HTTPURLResponse else {
            throw ScanSettleError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            return data
        case 401:
            throw ScanSettleError.unauthorized
        case 429:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw ScanSettleError.rateLimited(
                attemptsUsed: body?.attemptsUsed ?? ScanSettleService.maxAttempts
            )
        case 422:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            let errCode = body?.error ?? ""
            switch errCode {
            case "model_declined", "unparseable_response":
                throw ScanSettleError.modelDeclined
            case "record_failed":
                throw ScanSettleError.server(body?.detail ?? body?.reason ?? "record failed")
            default:
                throw ScanSettleError.unreadable
            }
        case 500, 502, 503, 504:
            throw ScanSettleError.serviceDown
        default:
            let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
            throw ScanSettleError.server("HTTP \(http.statusCode)\(body?.detail.map { " — \($0)" } ?? "")")
        }
    }
}
