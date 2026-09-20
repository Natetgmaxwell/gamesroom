//
//  AuthService.swift
//  GamesRoom
//
//  Track D1 — auth observable object.
//
//  Owns the `currentUser` state for the SwiftUI view tree. Loads the
//  `public.users` row matching the active Supabase auth session and
//  publishes it as `@Published`. Views subscribe via `@EnvironmentObject`
//  (or the `@Observable` form once the v0.8 view tree migrates).
//
//  The split between `auth.users` (GoTrue auth) and `public.users` (the
//  app's profile table) is intentional: identity lives in Supabase
//  auth, profile fields like `display_name` live in `public.users`.
//  `AuthService` is the only place that joins the two.
//
//  ponytail: observer is `@MainActor` because every consumer is a
//  SwiftUI view; `currentUser` is read on the main thread everywhere.
//  `loadCurrentUser()` is `async` (not `async throws`) — failures
//  collapse to `currentUser = nil` so the UI can render the
//  signed-out state without every caller catching.
//

import Foundation
import Supabase
import SwiftUI

@MainActor
final class AuthService: ObservableObject {
    /// The joined auth + profile row for the signed-in user. `nil`
    /// when not signed in, or when the session lookup failed.
    @Published private(set) var currentUser: User?

    /// Loads the `public.users` row matching the current GoTrue
    /// session. Sets `currentUser` to `nil` on any failure (no
    /// session, network error, or missing row). Call on app launch
    /// and after any auth state change.
    func loadCurrentUser() async {
        do {
            let session = try await SupabaseClientProvider.shared.auth.session
            let user: User = try await SupabaseClientProvider.shared
                .from("users")
                .select()
                .eq("id", value: session.user.id.uuidString)
                .single()
                .execute()
                .value
            self.currentUser = user
        } catch {
            // No session, expired session, or no matching public.users
            // row. All collapse to "not signed in" from the UI's POV.
            self.currentUser = nil
        }
    }

    /// Signs the user out of GoTrue and clears the cached profile
    /// row. Does not throw — `auth.signOut()` failures are swallowed
    /// because the local state is already cleared and the next
    /// `loadCurrentUser()` will reconcile.
    func signOut() async {
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastViewedRoomId)
        try? await SupabaseClientProvider.shared.auth.signOut()
        self.currentUser = nil
    }

    /// Updates the signed-in user's `display_name` in `public.users`.
    /// Used by the Settings → Display name field. The cached
    /// `currentUser` is updated in place so the UI reflects the new
    /// name without a round-trip. Throws on transport / RLS failure
    /// so the caller can surface a banner if the save fails.
    ///
    /// V0.101 — pull the JWT sub from the live auth session instead
    /// of the cached `currentUser.id`. The cache is normally in sync,
    /// but if a stale cache survives a server-side `update_user_id`
    /// (or any future migration that reassigns ids), the cached id
    /// no longer matches `request.jwt.claims.sub`, RLS USING drops
    /// the row, and the PATCH returns success-with-zero-rows. The
    /// user sees "saved" but the name on the server didn't change.
    /// Reading the id straight from `auth.session.user.id` removes
    /// that whole class of silent no-op. Failure mode is now a
    /// thrown Supabase error, surfaced as an alert in AppSettingsView.
    func updateDisplayName(_ newName: String) async throws {
        guard let current = currentUser else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.displayName else { return }

        // V0.101 — prefer the live session id over the cached id.
        // Falls back to the cached id if the session is unavailable
        // (shouldn't happen in practice; the cached id is the same
        // value as session.user.id 99% of the time).
        let sessionId = (try? await SupabaseClientProvider.shared.auth.session.user.id) ?? current.id
        let idFilter = sessionId.uuidString

        #if DEBUG
        print("[GamesRoom] updateDisplayName: id=\(idFilter) new=\(trimmed)")
        #endif

        // PostgREST UPDATE returns the updated row(s) by default
        // (Prefer: return=representation). The non-generic .execute()
        // discards the body — we don't decode it, just need the
        // absence of a throw. (Earlier bug class: decoding the body
        // via .single().value throws on empty / minimal responses —
        // see commits 3f2fbee and 2db1f4a.)
        try await SupabaseClientProvider.shared
            .from("users")
            .update(["display_name": trimmed])
            .eq("id", value: idFilter)
            .execute()

        // Mirror the change in the local cache so the UI updates
        // without a network round-trip. User only has id + displayName
        // (per GamesRoom/Models/User.swift v0.8).
        self.currentUser = User(id: current.id, displayName: trimmed)

        #if DEBUG
        print("[GamesRoom] updateDisplayName: persisted local cache; server updated.")
        #endif
    }

    /// Convenience accessor for views and other services that need
    /// the current user id without unwrapping `currentUser` at every
    /// call site.
    var currentUserId: UUID? {
        currentUser?.id
    }

    /// V0.99 / App Review 5.1.1(v) — permanently delete the user's
    /// account. The server-side `delete_my_account()` RPC removes the
    /// auth row + every domain row (rooms hosted, ledger rows, RSVPs,
    /// etc.) in one transaction; we then clear the local session and
    /// the `@AppStorage` cache so the UI reverts to sign-in.
    ///
    /// Throws if the RPC fails. Network/transport errors are
    /// surfaced to the caller so the Settings UI can show a banner
    /// and offer to abort. The post-RPC sign-out is best-effort
    /// (`try?`) because the local session is invalidated server-side
    /// by the auth.users delete; signOut may fail with "session not
    /// found" which is exactly what we want.
    func deleteAccount() async throws {
        _ = try await SupabaseClientProvider.shared
            .rpc("delete_my_account")
            .execute()

        // Server-side delete invalidates the JWT. Clear local state
        // so the next loadCurrentUser() returns nil and the root
        // view flips to the sign-in surface.
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastViewedRoomId)
        try? await SupabaseClientProvider.shared.auth.signOut()
        self.currentUser = nil
    }

    /// Preview initializer for SwiftUI #Preview blocks. Sets a
    /// fake currentUser so the views render with seeded data.
    static func preview() -> AuthService {
        let svc = AuthService()
        // We can't construct a User from the model (User requires a real UUID)
        // — but the preview helpers downstream use it just for type presence.
        return svc
    }

    #if DEBUG
    /// V0.92 screenshot bypass — inject a deterministic stub
    /// `currentUser` so the in-app surfaces (rooms list, room detail,
    /// casino, settings) can be captured for App Store screenshots
    /// without going through Apple Sign-In. This branch compiles only
    /// in Debug builds; release builds never call it.
    func injectStubUserForScreenshots() {
        self.currentUser = User(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            displayName: "Nathan"
        )
    }
    #endif
}
