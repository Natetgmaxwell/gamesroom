//
//  AppSettingsView.swift
//  GamesRoom
//
//  App-level settings (display name, sign out, delete account).
//  Reachable from the Settings tab in ContentView.swift via
//  SettingsPage.swift.
//
//  V0.8 design notes:
//   - The form lives inside a Form / NavigationStack. V0.7.1 used
//     .confirmationAction in the toolbar; V0.8 keeps the same
//     pattern because it's the iOS-native way to express "save this".
//   - The view depends on AuthService for currentUser,
//     updateDisplayName, and deleteAccount. AuthService is the
//     source of truth for the signed-in user across the app; this
//     view does not cache.
//   - The archived V0.7.1 version used Theme.background / Theme.accent
//     directly. V0.8's theme has Palette.background / Palette.accent
//     with `.opacity(0.x)` for muted text — used sparingly here.
//
//  V0.99 — Apple App Review Guideline 5.1.1(v) requires an in-app
//  account-deletion path. The "Delete Account" button is a destructive
//  action with a two-stage confirmation: a tap surfaces a
//  confirmationDialog that names the irreversible consequences (rooms
//  hosted, memberships, ledger, events deleted) before any RPC call
//  is made. The actual deletion goes through
//  AuthService.deleteAccount(), which calls the
//  `delete_my_account()` RPC (migration 096) + clears the local
//  `@AppStorage` cache + signs out. The user lands back on the
//  sign-in screen because the root view tree observes
//  `authService.currentUser` and renders the auth flow when it
//  becomes nil.
//

import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var displayNameError: String?
    @State private var displayNameErrorVisible: Bool = false
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    // T1.2 — opt-in photo retention. Device-level privacy
    // preference, so it lives in app settings (not room settings).
    @AppStorage(StorageKeys.keepScanPhotos) private var keepScanPhotos = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Display name", text: $name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)

                    if let displayNameError {
                        Text(displayNameError)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("Log out")
                            .foregroundStyle(.red)
                    }
                }

                // V0.99 — App Review 5.1.1(v) in-app account deletion.
                // ConfirmationDialog names every consequence (rooms hosted,
                // memberships, ledger, events — all gone; permanent) so the
                // tap that confirms carries informed consent. The actual
                // call is in `deleteAccount()` below.
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Text(isDeleting ? "Deleting…" : "Delete Account")
                            .foregroundStyle(.red)
                    }
                    .disabled(isDeleting)
                } header: {
                    Text("Delete account")
                } footer: {
                    if let deleteError {
                        Text(deleteError)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.red)
                    } else {
                        Text("Permanently delete your Games Room account and every room, membership, ledger row and event tied to it. This cannot be undone.")
                    }
                }

                // T1.2 — scan-photo retention. Default off keeps the
                // F-CAS-03 discard path; the toggle is the opt-in.
                Section {
                    Toggle("Keep scan photos", isOn: $keepScanPhotos)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                } header: {
                    Text("Chip scans")
                } footer: {
                    Text("When on, confirmed scan photos are saved to this device only. They are never uploaded.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("App settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { Task { await save() } }
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                        .disabled(isSaving || name.isEmpty || name == authService.currentUser?.displayName)
                }
            }
            .tint(Theme.Palette.accent)
            // V0.101 — surface save failures as an alert so the user
            // never sees a silent "Save" tap. Earlier the failure was
            // only inline red text inside the Section, which on iPad
            // can sit under the software keyboard and read as "did
            // nothing." An alert is impossible to miss.
            .alert(
                "Couldn't save display name",
                isPresented: $displayNameErrorVisible,
                presenting: displayNameError
            ) { _ in
                Button("OK", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            .task {
                name = authService.currentUser?.displayName ?? ""
                #if DEBUG
                // V0.99 screenshot bypass: open the destructive
                // confirmationDialog immediately on appear so the
                // review-Notes capture shows the destructive copy
                // without needing a tap on a headless simulator.
                if CommandLine.arguments.contains("-screenshots-show-delete-confirm") {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    showDeleteConfirm = true
                }
                #endif
            }
            .confirmationDialog(
                "Log out?",
                isPresented: $showLogoutConfirm,
                titleVisibility: .visible
            ) {
                Button("Log out", role: .destructive) {
                    Task { await logout() }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You'll need to sign in again.")
            }
            // V0.99 — App Review 5.1.1(v). Use `.alert` (not
            // `.confirmationDialog`) for the destructive path because
            // the body message is long enough that an iPad popover
            // truncates the Cancel button. `.alert` is the centered
            // native pattern; it also renders identically across
            // iPhone and iPad, which matters because the App Review
            // recording demo will run on both.
            .alert(
                "Delete account?",
                isPresented: $showDeleteConfirm,
                presenting: authService.currentUser
            ) {
                _ in
                Button("Delete permanently", role: .destructive) {
                    Task { await deleteAccount() }
                }
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("All rooms you host, your memberships, chips and ledger rows, and your events will be deleted. Your account cannot be restored.")
            }
        }
    }

    private func save() async {
        displayNameError = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await authService.updateDisplayName(name)
            // AppSettingsView is @MainActor — dismiss() runs on the
            // main actor without needing MainActor.run.
            dismiss()
        } catch {
            // V0.101 — surface the failure both inline and as an
            // alert. Earlier the failure showed only as small red text
            // inside the Form section; on iPad that text can sit
            // under the keyboard and the user sees "Save" appear to
            // do nothing. The alert guarantees the error is visible
            // regardless of keyboard or layout.
            displayNameError = error.localizedDescription
            displayNameErrorVisible = true
        }
    }

    private func logout() async {
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastViewedRoomId)
        await authService.signOut()
        await MainActor.run { dismiss() }
    }

    // V0.99 — App Review 5.1.1(v). Called from the destructive
    // confirmationDialog. On success, the sheet dismisses the
    // settings sheet via the AuthService.currentUser = nil flip
    // (the root view tree observes currentUser and re-renders the
    // sign-in surface when it goes nil). On failure, the
    // errorMessage state surfaces in the section footer so the user
    // can retry without losing the dialog context.
    private func deleteAccount() async {
        deleteError = nil
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await authService.deleteAccount()
            // currentUser is already nil inside AuthService. Dismiss
            // so the Settings tab doesn't linger on a view for an
            // account that no longer exists. The authService
            // observer will keep the root view on the sign-in
            // surface even after dismiss.
            await MainActor.run { dismiss() }
        } catch {
            deleteError = error.localizedDescription
        }
    }
}
