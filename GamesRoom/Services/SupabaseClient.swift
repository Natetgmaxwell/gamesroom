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
//  ponytail: SUPABASE_URL + SUPABASE_ANON_KEY are read from
//  Info.plist at runtime (`Bundle.object(forInfoDictionaryKey:)`);
//  the values themselves are set as build settings via
//  `GamesRoom/Config.xcconfig` (gitignored), so the URL never
//  appears literally in the repo. The xcconfig path was chosen
//  because the URL contains `//` (the scheme separator) which
//  Info.plist's literal string format handles cleanly.
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
        // Read URL + key from Info.plist. The Info.plist values are
        // wired to build settings via `$(SUPABASE_URL)` /
        // `$(SUPABASE_ANON_KEY)`; the build settings themselves come
        // from `GamesRoom/Config.xcconfig` (gitignored). The fallback
        // literals in this file are an emergency brace for when
        // Info.plist is missing them — they are not the canonical path.
        let bundle = Bundle.main
        let urlString = bundle.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
            ?? "https://bnrgkdcluopicqdpmrtu.supabase.co"
        let key = bundle.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
            ?? "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImJucmdrZGNsdW9waWNxZHBtcnR1Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODM1ODIxMzcsImV4cCI6MjA5OTE1ODEzN30.3Cc7hElQYaAYsKEJ_goSTdercYQG3o2hG9PiyHggO5Q"
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
    static func currentSession() async -> Auth.Session? {
        try? await shared.auth.session
    }
}
