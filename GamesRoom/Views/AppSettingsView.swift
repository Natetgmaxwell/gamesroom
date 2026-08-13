//
//  AppSettingsView.swift
//  GamesRoom
//
//  App-level settings (display name, sign out). Reachable from the
//  Settings tab in ContentView.swift via SettingsPage.swift.
//
//  V0.8 design notes:
//   - The form lives inside a Form / NavigationStack. V0.7.1 used
//     .confirmationAction in the toolbar; V0.8 keeps the same
//     pattern because it's the iOS-native way to express "save this".
//   - The view depends on AuthService for currentUser and
//     updateDisplayName. AuthService is the source of truth for the
//     signed-in user across the app; this view does not cache.
//   - The archived V0.7.1 version used Theme.background / Theme.accent
//     directly. V0.8's theme has Palette.background / Palette.accent
//     with `.opacity(0.x)` for muted text — used sparingly here.
//

import SwiftUI

struct AppSettingsView: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var errorMessage: String?
    @State private var showLogoutConfirm = false
    @State private var isSaving = false

    // T1.2 — opt-in photo retention. Device-level privacy
    // preference, so it lives in app settings (not room settings).
    @AppStorage(StorageKeys.keepScanPhotos) private var keepScanPhotos = false

    @AppStorage(StorageKeys.mascotApiKey) private var mascotApiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Display name") {
                    TextField("Display name", text: $name)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    SecureField("MiniMax API key", text: $mascotApiKey)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                } header: {
                    Text("Mascot voice (MiniMax)")
                } footer: {
                    Text("Used to generate the mascot's LLM voice. Leave empty to use the built-in template.")
                }

                Section {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Text("Log out")
                            .foregroundStyle(.red)
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
            .task {
                name = authService.currentUser?.displayName ?? ""
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
        }
    }

    private func save() async {
        errorMessage = nil
        isSaving = true
        defer { isSaving = false }
        do {
            try await authService.updateDisplayName(name)
            await MainActor.run { dismiss() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func logout() async {
        UserDefaults.standard.removeObject(forKey: StorageKeys.lastViewedRoomId)
        await authService.signOut()
        await MainActor.run { dismiss() }
    }
}
