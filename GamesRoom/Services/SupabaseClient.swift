//
//  SupabaseClient.swift
//  GamesRoom
//
//  Track D1 — shared Supabase client wrapper.
//
//  Wraps the `supabase-swift` SDK from the SPM package ("supabase-swift",
//  https://github.com/supabase/supabase-swift) referenced in the Xcode
//  project. Exposes the three SDK namespaces the rest of the app uses
//  (`auth`, `database`, `functions`) and a `currentSession()` async
//  accessor that returns `Session?` for callers that don't want to
//  handle the throwable form of `auth.session`.
//
//  ponytail: hard-coded URL/key for dev. The Config.xcconfig path
//  fails because xcconfig parses `//` as the start of a line comment,
//  so https://... always loses everything after the `//`. Replace
//  with xcconfig-driven values once we have a build setting that
//  doesn't contain `//` (e.g. split into SUPABASE_URL_SCHEME +
//  SUPABASE_URL_HOST, or move to Info.plist literals).
//
//  ponytail: custom URLSession with HTTP/1.1 forced and short
//  timeouts. The iOS 26 simulator's default URLSession hangs on
//  Supabase PostgREST responses ("Operation timed out" from
//  nw_read_request_report). Forcing HTTP/1.1 via configuration avoids
//  the HTTP/3 keep-alive issue. Short timeouts surface failures
//  instead of silently hanging.
//

import Foundation
import Supabase

enum SupabaseClientProvider {
    /// The shared Supabase client. Constructed once, lazily, on first
    /// access. All `Services/` code depends on this single instance.
    static let shared: SupabaseClient = {
        let urlString = "https://bnrgkdcluopicqdpmrtu.supabase.co"
        let key = "eyJhbG...gO5Q"
        guard let url = URL(string: urlString) else {
            fatalError("Invalid Supabase URL: \(urlString)")
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
        config.httpAdditionalHeaders = ["Connection": "close"]
        let session = URLSession(configuration: config)
        return SupabaseClient(
            supabaseURL: url,
            supabaseKey: key,
            options: SupabaseClientOptions(
                global: SupabaseClientOptions.GlobalOptions(session: session)
            )
        )
    }()

    // MARK: - SDK namespace re-exports

    /// Auth namespace — `auth.session`, `auth.signIn`, `auth.signOut`,
    /// `auth.onAuthStateChange`, etc. Used by `AuthService` and the
    /// sign-in surface.
    static var auth: AuthClient { shared.auth }

    /// Database namespace — `database.from("…").select()…`. Used by
    /// `RoomService`, `CasinoService`, and the views that read the
    /// `public.users` / `rooms` / `room_memberships` / etc. tables.
    static var database: PostgrestClient { shared.database }

    /// Edge-functions namespace — `functions.invoke("…")`. Used by
    /// `NotificationDispatcher` for the mascot voice fan-out and by
    /// any RPC-ish operations that aren't first-class Postgres
    /// functions.
    static var functions: FunctionsClient { shared.functions }

    // MARK: - Session helpers

    /// Returns the current session, or `nil` if the user is signed
    /// out / the session has expired. Never throws — any failure
    /// (no session, decode error, keychain error) collapses to `nil`.
    /// Use `loadCurrentUser()` on `AuthService` for the full session
    /// + user-row fetch.
    static func currentSession() async -> Session? {
        try? await shared.auth.session
    }
}
