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
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 10) {
                Text("Get a nudge when \(roomName) schedules a night?")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)

                // v1.1 — text buttons: the room state's one filled
                // button lives in the hero card, not here.
                HStack(spacing: 20) {
                    Button {
                        onOptIn()
                    } label: {
                        Text("Notify me")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onDismiss()
                    } label: {
                        Text("Not now")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        // v1.2.1 — flat, like every other room-page section. The boxed
        // card floated between flat sections with uneven air around it.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The "My notifications" section in Room settings. Visible to all
/// roles. Opt-in toggle + (opt-in ON, active event only) per-event
/// mute row wired to `set_event_notifications_muted`.
struct RoomNotifSettingsSection: View {
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var auth: AuthService
    let room: Room

    /// Live room from the service cache — the opt-in RPC mirrors into
    /// it, so the toggle reflects server truth instead of the frozen
    /// snapshot captured when the sheet opened. Same source of truth
    /// the room page reads.
    private var liveRoom: Room {
        roomService.rooms.first(where: { $0.id == room.id }) ?? room
    }

    private var activeEvent: Event? {
        roomService.cachedActiveEvent(roomId: room.id)
    }

    var body: some View {
        Section {
            Toggle(isOn: Binding(
                get: { liveRoom.notificationsEnabled },
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
                    Text("When a night is set, a week before, a few days before and the morning of.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
            .tint(Theme.Palette.accent)

            // Per-event mute: only meaningful while pushes are on,
            // and only for the room's active (unsettled) event.
            if liveRoom.notificationsEnabled, let event = activeEvent {
                EventMuteRow(event: event, currentUserId: auth.currentUser?.id)
            }

            // V0.107 §2b — the member's OWN anchor-push switch. Every
            // role sees it (it is about their phone, not about the
            // room), and it is greyed while the room's notifications
            // are off because the server drops the nudge then
            // anyway — migration 105 checks `notifications_enabled`
            // before it ever queues one.
            AnchorPushRow(
                room: room,
                notificationsOn: liveRoom.notificationsEnabled
            )
        } header: {
            Text("My notifications")
        } footer: {
            Text(liveRoom.notificationsEnabled
                 ? "Mute a single night below. Declining a seat also mutes that night."
                 : "Turn on to get a nudge when \(liveRoom.name) schedules a night. The reminder for someone you brought waits behind it.")
        }
    }
}

/// V0.107 §2b — "Remind me when someone I brought is coming", the
/// member switch that gates the anchor push. Self-contained (own
/// `.task` to load, own error row) so it seeds the same way the
/// per-event mute row does, rather than relying on a host-only
/// settings sheet lifecycle.
///
/// The toggle is NOT optimistically flipped: its `get` reads the
/// service cache, which is only written once the server accepted
/// the save. A failed save therefore leaves the switch on the last
/// acknowledged value AND shows the reason beside it — the member
/// is never left believing a nudge is coming when none will.
private struct AnchorPushRow: View {
    @EnvironmentObject private var roomService: RoomService
    let room: Room
    let notificationsOn: Bool

    @State private var saveError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(
                get: { roomService.cachedAnchorPushEnabled(roomId: room.id) },
                set: { newValue in
                    Task { await save(newValue) }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remind me when someone I brought is coming")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text("A nudge when they claim a seat and you haven't — while they're new.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
            }
            .tint(Theme.Palette.accent)
            // Greyed, not hidden: the switch is part of "My
            // notifications" whatever the room switch says, and
            // the room switch is right above it.
            .disabled(!notificationsOn)
            .accessibilityIdentifier("anchor-push-enabled-toggle")
            // Full width so the switch lands on the trailing edge
            // like the two toggles above it — this row carries the
            // error line too, so it cannot rely on the Form row's
            // own layout to push the switch out.
            .frame(maxWidth: .infinity, alignment: .leading)

            if let saveError {
                HStack(spacing: 8) {
                    Image(systemName: Theme.Icon.exclamationmarkTriangleFill)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
                        .accessibilityHidden(true)
                    Text("Couldn't save that reminder: \(saveError)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
                .accessibilityIdentifier("anchor-push-enabled-error")
            }
        }
        .task {
            _ = await roomService.loadAnchorPushEnabled(roomId: room.id)
        }
    }

    private func save(_ on: Bool) async {
        do {
            try await roomService.setAnchorPushEnabled(roomId: room.id, on: on)
            saveError = nil
            Haptics.light()
        } catch {
            saveError = (error as NSError).localizedDescription
            Haptics.warning()
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
                    .accessibilityHidden(true)
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
