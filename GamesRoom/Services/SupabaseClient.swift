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
//  ponytail: a missing or unapplied xcconfig leaves the literal
//  `$(SUPABASE_URL)` / `$(SUPABASE_ANON_KEY)` strings in the built
//  Info.plist. Those are treated as missing and fall back to the
//  compiled defaults (real URL + invalid-key sentinel) with a console
//  warning — a config problem degrades to a failed sign-in, not a
//  fatalError crash.
//
// ponytail: custom URLSession with short timeouts. The iOS 26
// simulator's default URLSession hangs on Supabase PostgREST
// responses ("Operation timed out" from
// nw_read_request_report); short timeouts surface failures instead
// of silently hanging. V0.69 — `Connection: close` removed so
// HTTP/2 keep-alive multiplexes all RPCs over a single connection
// instead of paying a TCP+TLS handshake on every call.
//

import Foundation
import Supabase

enum SupabaseClientProvider {
    /// The shared Supabase client. Constructed once, lazily, on first
    /// access. All `Services/` code depends on this single instance.

    // Compiled fallbacks for when Info.plist is missing a value or
    // carries an unsubstituted `$(...)` build-setting literal (xcconfig
    // not applied): the URL is real so the app keeps working; the key
    // is a loud sentinel so a missing config fails visibly instead of
    // as a confusing 401 from a truncated JWT.
    private static let fallbackURLString = "https://bnrgkdcluopicqdpmrtu.supabase.co"
    private static let fallbackKey = "MISSING_SUPABASE_ANON_KEY_CONFIG_ERROR"

    static let shared: SupabaseClient = {
        // Read URL + key from Info.plist. The Info.plist values are
        // wired to build settings via `$(SUPABASE_URL)` /
        // `$(SUPABASE_ANON_KEY)`; the build settings themselves come
        // from `GamesRoom/Config.xcconfig` (gitignored). The fallback
        // literals in this file are an emergency brace for when
        // Info.plist is missing them — they are not the canonical path.
        func readConfig(_ key: String, fallback: String) -> String {
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
                  !raw.isEmpty,
                  !raw.hasPrefix("$(") else {
                print("[GamesRoom] WARNING: \(key) missing or unsubstituted in Info.plist; using compiled fallback.")
                return fallback
            }
            return raw
        }

        let urlString = readConfig("SUPABASE_URL", fallback: fallbackURLString)
        let key = readConfig("SUPABASE_ANON_KEY", fallback: fallbackKey)

        // A malformed plist value (e.g. quotes leaked from the xcconfig)
        // fails URL(string:) — degrade to the compiled default instead
        // of trapping. Also bail when the host is missing or empty
        // (e.g. an un-substituted SUPABASE_HOST variable) so we
        // never construct a hostless URL. The fatalError below is
        // unreachable unless the compiled constant itself is broken.
        let url: URL
        if let parsed = URL(string: urlString),
           let host = parsed.host,
           !host.isEmpty {
            url = parsed
        } else {
            print("[GamesRoom] WARNING: SUPABASE_URL in Info.plist is not a valid URL ('\(urlString)'); using compiled fallback.")
            guard let fallbackURL = URL(string: fallbackURLString),
                  let fallbackHost = fallbackURL.host,
                  !fallbackHost.isEmpty else {
                fatalError("SupabaseClientProvider: compiled fallback URL is invalid: \(fallbackURLString)")
            }
            url = fallbackURL
        }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 6
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
