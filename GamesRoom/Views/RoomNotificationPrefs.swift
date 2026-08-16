import SwiftUI

// MARK: - RoomNotificationPrefs (V0.79)
//
// One-time opt-in prompt → settings. The main room page carries a
// compact inline prompt exactly once per member per room (per
// device); after ANY response ("Notify me" or "Not now") the
// preference lives in Room settings → "My notifications" forever.
// The hero briefing card carries no notification controls at all —
// "Can't make it" already mutes via the dispatcher's declined gate.

/// UserDefaults keys for the one-time prompt gate. Per-device scope
/// by design: a wiped app re-prompts once; settings is the durable
/// surface.
enum RoomNotifPrompt {
    static func isAnswered(roomId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: "notifPromptAnswered.\(roomId.uuidString)")
    }

    static func markAnswered(roomId: UUID) {
        UserDefaults.standard.set(true, forKey: "notifPromptAnswered.\(roomId.uuidString)")
    }
}

/// The one-time inline prompt card. Self-contained: bell + question
/// + two actions. Rendered by RoomDetailView only while
/// `room.notificationsEnabled == false && !RoomNotifPrompt.isAnswered`.
struct RoomNotifPromptCard: View {
    let roomName: String
    let onOptIn: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Layout.gutter / 2) {
            Image(systemName: Theme.Icon.bellFill)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 10) {
                Text("Get a nudge when \(roomName) schedules a night?")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)

                HStack(spacing: 12) {
                    Button {
                        onOptIn()
                    } label: {
                        Text("Notify me")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .pressScale()

                    Button {
                        onDismiss()
                    } label: {
                        Text("Not now")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Theme.Palette.hairline)
                            )
                    }
                    .pressScale()
                }
            }
        }
        .padding(Theme.Layout.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Theme.Palette.hairline, lineWidth: 1)
                )
        )
    }
}

/// The "My notifications" section in Room settings. Visible to all
/// roles. Opt-in toggle + (opt-in ON, active event only) per-event
/// mute row wired to `set_event_notifications_muted`.
struct RoomNotifSettingsSection: View {
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var auth: AuthService
    let room: Room

    private var activeEvent: Event? {
        roomService.cachedActiveEvent(roomId: room.id)
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { room.notificationsEnabled },
                set: { newValue in
                    Task {
                        try? await roomService.setNotificationsEnabled(
                            roomId: room.id, enabled: newValue
                        )
                        Haptics.light()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remind me about this room's nights")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("On-create, 48-hour and morning-of nudges.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
            .tint(Theme.Palette.accent)

            // Per-event mute: only meaningful while pushes are on,
            // and only for the room's active (unsettled) event.
            if room.notificationsEnabled, let event = activeEvent {
                EventMuteRow(event: event, currentUserId: auth.currentUser?.id)
            }
        } header: {
            Text("My notifications")
        } footer: {
            Text(room.notificationsEnabled
                 ? "Mute a single night below. Declining a seat also mutes that night."
                 : "Turn on to get a nudge when \(room.name) schedules a night.")
        }
    }
}

/// Per-event mute row (active event only). Reads the caller's mute
/// state from the RSVP cache; the 078 RPC upserts on first toggle.
private struct EventMuteRow: View {
    @EnvironmentObject private var roomService: RoomService
    let event: Event
    let currentUserId: UUID?

    private var isMuted: Bool {
        guard let uid = currentUserId else { return false }
        return roomService.cachedEventRSVPs(eventId: event.id)
            .first(where: { $0.memberId == uid })?
            .notificationsMuted ?? false
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { isMuted },
            set: { newValue in
                Task {
                    try? await roomService.setEventNotificationsMuted(
                        eventId: event.id, muted: newValue,
                        currentUserId: currentUserId
                    )
                    Haptics.light()
                }
            }
        )) {
            HStack(spacing: 8) {
                Image(systemName: isMuted ? Theme.Icon.bellSlashFill : Theme.Icon.bellFill)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.accent.opacity(0.8))
                Text("Mute “\(event.name)”")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
            }
        }
        .tint(Theme.Palette.accent)
    }
}
