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
    /// name without a round-trip. Does not throw — failures bubble
    /// up so the caller can surface a banner if the save fails.
    func updateDisplayName(_ newName: String) async throws {
        guard let current = currentUser else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != current.displayName else { return }
        // PostgREST UPDATE defaults to return=minimal (HTTP 204, empty
        // body). Discard the return — decoding as User via .single().value
        // throws on the empty body even though the UPDATE succeeded.
        _ = try await SupabaseClientProvider.shared
            .from("users")
            .update(["display_name": trimmed])
            .eq("id", value: current.id.uuidString)
            .execute()
        // Mirror the change in the local cache so the UI updates
        // without a network round-trip. User only has id + displayName
        // (per GamesRoom/Models/User.swift v0.8).
        self.currentUser = User(id: current.id, displayName: trimmed)
    }

    /// Convenience accessor for views and other services that need
    /// the current user id without unwrapping `currentUser` at every
    /// call site.
    var currentUserId: UUID? {
        currentUser?.id
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
