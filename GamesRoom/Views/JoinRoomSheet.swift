//
//  JoinRoomSheet.swift
//  GamesRoom
//
//  Track P0.2 — member-side join-code redemption.
//
//  Presented from `RoomPage`'s empty-state CTA when the signed-in
//  user has no rooms and is not a known host. One input:
//
//    1. Six-character code — uppercase, no ambiguous glyphs.
//       The server's alphabet is `'ABCDEFGHJKMNPQRSTUVWXYZ23456789'`
//       (31 chars, per migration 004) — the picker accepts both
//       upper and lower case, trims whitespace, and refuses any
//       string that isn't exactly six characters after
//       normalisation.
//
//  Save fires `RoomService.redeemJoinCode(code:)` which routes
//  through the store to either Supabase (production) or the
//  in-memory fake. On success the sheet dismisses and the parent
//  `RoomPage` re-renders with the joined room at the top of the
//  list (the service eagerly refreshes). On failure the inline
//  error replaces the dismiss path so the member can edit + retry
//  without losing input.
//
//  Idempotency: re-redeeming for an existing member returns the
//  room row without mutating points — the sheet treats that as
//  success. The error path fires only on not-found /
//  already-redeemed / RLS rejection.
//

import SwiftUI
import UserNotifications

struct JoinRoomSheet: View {

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    @State private var code: String = ""
    @State private var isRedeeming: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "Join code",
                        text: $code,
                        prompt: Text("ABC23F")
                    )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled(true)
                    .font(Theme.Typography.title.monospaced())
                    .onChange(of: code) { _, newValue in
                        // Hard-clamp to 6 chars + uppercase. Anything
                        // pasted with whitespace gets trimmed; the
                        // server is idempotent so the same code can
                        // be re-entered without an extra state
                        // transition.
                        let filtered = newValue
                            .uppercased()
                            .filter { $0.isLetter || $0.isNumber }
                        let clamped = String(filtered.prefix(6))
                        if clamped != code { code = clamped }
                    }
                } header: {
                    Text("Code")
                } footer: {
                    Text("Ask the host for the six-character code from their Room Settings. Codes are case-insensitive and look like ABC23F.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("Join a room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") {
                        Task { await redeem() }
                    }
                    .disabled(isRedeeming || normalisedCode.count != 6)
                    .tint(Theme.Palette.accent)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Validation

    private var normalisedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Redeem

    private func redeem() async {
        guard !isRedeeming else { return }
        let resolved = normalisedCode
        guard resolved.count == 6 else {
            errorMessage = "Codes are six characters."
            return
        }
        isRedeeming = true
        errorMessage = nil
        defer { isRedeeming = false }
        do {
            _ = try await roomService.redeemJoinCode(code: resolved)
            // M2.4 — per vision §6.1 Q3 lean: prompt for notification
            // permission at room join, not at install. The on-page
            // briefing slot is the fallback if the member denies.
            // Best-effort; never blocks the dismiss path on failure.
            await requestNotificationsIfNeeded()
            dismiss()
        } catch {
            // Map the most common server errors to user-facing
            // copy. The V0.8 brief explicitly avoids public-shame
            // framing so a not-found code reads as "ask for a new
            // code" rather than "your code was wrong".
            let nsError = error as NSError
            switch nsError.code {
            case -1 where nsError.localizedDescription.contains("already redeemed"):
                errorMessage = "That code was already used. Ask the host for a fresh one."
            case -1:
                errorMessage = "Couldn't find that code. Double-check it with the host."
            default:
                errorMessage = "Couldn't join right now. Try again in a moment."
            }
        }
    }

    /// M2.4 — request notification permission after a successful
    /// join. `requestAuthorization` is idempotent: iOS will surface
    /// the system prompt only on the first call per app install;
    /// subsequent calls return the cached answer immediately.
    /// Errors (e.g., `NotificationsDeniedAtJoin`) are logged via
    /// the ponytail comment but do not block the dismiss path —
    /// the briefing slot is the documented fallback.
    private func requestNotificationsIfNeeded() async {
        do {
            _ = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .badge, .sound])
            // ponytail: notifications permission requested at join;
            // the briefing slot remains the fallback for denied
            // members per vision §6.1 Q3.
        } catch {
            // ponytail: notifications denied at join; the briefing
            // slot is the fallback. No UI affordance needed.
        }
    }
}