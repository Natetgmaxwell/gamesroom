//
//  AppSettingsView.swift
//  GamesRoom
//
//  App-level settings (display name, sign out, delete account).
//  Reachable from the Settings tab in ContentView.swift via
//  SettingsPage.swift.
//
//  V0.8 design notes:
//   - The form lives inside a Form / NavigationStack. v1.1 — the
//     display name autosaves (debounced, plus Return), matching Room
//     settings; the Cancel/Save toolbar is gone (Cancel did nothing
//     in a tab).
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
    // V0.81 promoted — the display name runs the same write machine the
    // room settings sheet does. `displayNameError` was a private copy of
    // `.failed`; keeping it here meant "Saved" could outlive a later
    // failure (D8).
    @State private var writeState: WriteState = .idle
    /// The `isWriting` / `refireAfterWrite` serializer, wrapped. D7: an
    /// edit that lands while a save is in flight queues one refire, so the
    /// final character is persisted instead of dropped.
    @State private var gate = WriteGate()
    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    // T1.2 — opt-in photo retention. Device-level privacy
    // preference, so it lives in app settings (not room settings).
    @AppStorage(StorageKeys.keepScanPhotos) private var keepScanPhotos = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                        .submitLabel(.done)
                        .onSubmit { Task { await save() } }

                    if let nameError = writeState.failure(for: .displayName) {
                        Text(nameError)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Display name")
                } footer: {
                    Text(displayNameFooter)
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
            .tint(Theme.Palette.accent)
            // v1.1 — autosave like Room settings: the name writes
            // 800ms after the last keystroke (or on Return). No
            // Cancel/Save toolbar; this is a tab, not a sheet.
            // D8 — the edit clears "Saved" (or a stale failure) at once;
            // the debounce alone left the footer saying "Saved" forever.
            .task(id: name) {
                writeState = writeState.reduce(.edited)
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled else { return }
                await save()
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

    /// The footer reads the write machine, never a separate flag: a save in
    /// flight says so, the last save says "Saved" until the next edit clears
    /// it (D8), and a failure never sits behind "Saved".
    private var displayNameFooter: String {
        switch writeState {
        case .saving:
            return "Saving…"
        case .saved:
            return "Saved"
        case .failed(_, _):
            return "Edits save automatically"
        case .idle:
            return "Edits save automatically"
        }
    }

    private func save() async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != authService.currentUser?.displayName
        else { return }
        // D7 — one write at a time. An edit that lands while a write is in
        // flight queues a single refire instead of being dropped on the
        // floor (the old `guard !isSaving` returned and nothing rescheduled).
        guard gate.begin() else { return }
        defer {
            if gate.end() {
                Task { await save() }
            }
        }
        writeState = writeState.reduce(.begin(.displayName))
        do {
            try await authService.updateDisplayName(trimmed)
            writeState = writeState.reduce(.succeed(at: Date()))
        } catch {
            writeState = writeState.reduce(.fail(.displayName, error.localizedDescription))
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
