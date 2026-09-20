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
        //
        // V0.102 build 17 — capture the wire-level response (HTTP
        // status + body length) so the regression test in
        // `iPadDisplayNameSaveWireTests` can assert that an actual
        // 2xx with a non-empty `representation` array was returned.
        // A 200/204 with `[]` is the symptom of RLS USING dropping
        // the row — the request "succeeded" but nothing was
        // updated, and the iOS dashboard flips the local cache
        // mirror to the new value while the server keeps the old
        // one. That mismatch is exactly what the user reports as
        // "Save won't save".
        let response = try await SupabaseClientProvider.shared
            .from("users")
            .update(["display_name": trimmed])
            .eq("id", value: idFilter)
            .execute()

        #if DEBUG
        let bodyBytes = response.data.count
        let status = response.status
        let line = "[GamesRoom] updateDisplayName: PATCH /rest/v1/users?id=eq.\(idFilter) → \(status) (\(bodyBytes)B body)\n"
        print(line, terminator: "")
        // V0.102 — also write to a stable on-disk log under the app
        // sandbox Documents so an XCUITest (or the orchestrator's
        // wire-capture helper) can read it back without going through
        // OSLog filtering or the xcresult stdout capture (which does
        // not surface SUT `print()` output reliably under Xcode 27).
        // File path is `/.../Documents/GamesRoom-wire.log`; the
        // orchestrator's `grep "updateDisplayName: PATCH" /tmp/dd/.../
        // GamesRoom-wire.log` is the post-run verifier.
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("GamesRoom-wire.log")
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
        #endif

        // V0.102 build 17 — root fix for the iPad display-name
        // save silent failure.
        //
        // Bug class (proven on the wire by the new
        // `iPadDisplayNameSaveWireTests` XCUITest against this
        // worktree): the screenshot-bypass stub user (and any user
        // whose JWT does not match the row they are trying to
        // update) sees the PATCH return `200 OK` with a `[]`
        // representation body. PostgREST considers the call
        // successful; the Supabase Swift client's `execute()` does
        // not throw; the local cache gets mirrored to the new name;
        // the iOS sheet dismisses; the user reads "saved". But the
        // server row is unchanged, and on the next session refresh
        // the old name reappears — which the user reports as
        // "Save won't save".
        //
        // Wire-evidence (from the regression test's
        // `GamesRoom-wire.log`, build 17):
        //
        //   [GamesRoom] updateDisplayName: PATCH
        //     /rest/v1/users?id=eq.00000000-0000-0000-0000-000000000001
        //     → 200 (2B body)
        //
        // …the `(2B body)` is the `[]` empty array. Pre-fix-17 the
        // response was discarded entirely; the local-cache mirror
        // ran unconditionally; the user got a silent no-op.
        //
        // The fix: read `response.data` and require a non-empty
        // representation. A 2xx with empty body is a real failure
        // (RLS dropped the row, or the row does not exist for the
        // id we are filtering on) and must throw so the caller
        // (`AppSettingsView.save`) can surface the alert the user
        // reported was missing.
        //
        // Why a thrown error and not a silent retry / refetch:
        // the iOS client cannot tell apart "RLS dropped the row
        // because the JWT was wrong" from "the row does not exist"
        // without a separate round-trip, and either case requires
        // the user to take action (re-sign-in or contact support)
        // that a silent retry would just delay. Surfacing the
        // error is the only honest answer.
        // Strip ASCII whitespace from `response.data` so a `[]\n` or
        // `[ ]\n` representation body is still recognised as empty.
        let whitespace: Set<UInt8> = [0x20, 0x0A, 0x09, 0x0D]
        let trimmedBytes: [UInt8] = Array(response.data.filter { !whitespace.contains($0) })
        let isEmptyRepresentation: Bool
        if trimmedBytes.count == 2
            && trimmedBytes[0] == UInt8(ascii: "[")
            && trimmedBytes[1] == UInt8(ascii: "]")
        {
            isEmptyRepresentation = true
        } else if trimmedBytes.isEmpty {
            // Empty body at all — 204 No Content from PostgREST.
            isEmptyRepresentation = true
        } else {
            isEmptyRepresentation = false
        }
        guard !isEmptyRepresentation else {
            // Don't mirror to the local cache — the server did NOT
            // persist the change. Throwing here lets
            // `AppSettingsView.save` surface the alert the user
            // reported was missing on iPad.
            throw DisplayNameSaveError.notPersisted(
                idFilter: idFilter,
                httpStatus: response.status
            )
        }

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

/// V0.102 — thrown by `AuthService.updateDisplayName` when the PATCH
/// to `public.users` returns a 2xx with an empty representation
/// array. PostgREST considers the call successful (and the Supabase
/// Swift client's `execute()` does not throw on it), but no row was
/// actually updated. Surfacing this lets `AppSettingsView.save`
/// show the alert the user reported was missing on iPad
/// ("Save won't save").
///
/// Localized description is the user-facing message the alert
/// displays. The `idFilter` and `httpStatus` are kept for the
/// regression test and for any future telemetry.
struct DisplayNameSaveError: LocalizedError {
    let idFilter: String
    let httpStatus: Int

    var errorDescription: String? {
        "We couldn't save your display name (server returned status \(httpStatus) with no rows updated). Try signing out and back in, or contact support."
    }

    static func notPersisted(idFilter: String, httpStatus: Int) -> DisplayNameSaveError {
        DisplayNameSaveError(idFilter: idFilter, httpStatus: httpStatus)
    }
}
