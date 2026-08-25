//
//  MemberCalendarSettingsSheet.swift
//  GamesRoom
//
//  V0.86 — the per-member calendar auto-add surface. Replaces the
//  host's per-room `calendar_auto_add_host` toggle (which lived in
//  `RoomSettingsSheet`'s Operations sub-sheet) with a single per-user
//  toggle that applies to every room the member is in.
//
//  Two persistence layers wired together:
//   - The toggle itself lives server-side in
//     `room_memberships.calendar_auto_add` (migration 087). One RPC
//     `set_member_calendar_auto_add(p_enabled)` flips it across
//     every room the caller belongs to.
//   - The EventKit row identifier for each event lives in
//     `events.event_calendar_identifier` (migration 087), reported
//     back via `report_calendar_identifier(p_event_id, p_identifier)`
//     after each successful EKEvent.save(). The identifier
//     replaces the V0.26 UserDefaults map keyed by event UUID —
//     that map died with the device, which is the bug V0.86 fixes.
//
//  UI flow:
//   - First-time tap: triggers `requestAccess()` (the system
//     permission prompt), then writes the toggle ON if granted. A
//     denial flips a "Denied — open Settings to change" row so the
//     user can grant later without losing the toggle intent.
//   - Subsequent toggles: write the toggle directly; the next
//     event create / edit that the member does will mirror the row.
//   - The host's calendar row is NOT written unless the host is
//     also a member with the toggle on (host = user, same toggle
//     applies — no special-case for hosts).
//
//  Brief: "calendar solidifies the event." First-time-on is the
//  only moment this surface appears with no-coming-back
//  engagement; afterwards the row lives next to "My
//  notifications" in Room Settings and is reachable any time.
//

import EventKit
import SwiftUI

/// V0.86 — first-time-per-device gate for the calendar permission
/// voice line in BriefingSlot. Per-device scope by design (a wiped
/// app re-prompts once; the toggle in
/// `MemberCalendarSettingsSheet` is the durable surface).
enum CalendarPrompt {
    static func hasSeenVoiceLine() -> Bool {
        UserDefaults.standard.bool(forKey: "calendarPromptSeen.v0.86")
    }

    static func markVoiceLineSeen() {
        UserDefaults.standard.set(true, forKey: "calendarPromptSeen.v0.86")
    }
}

/// Member-facing calendar settings. Reachable from the per-room
/// settings gear (member-visible; the host does not need to enter
/// the room — `RoomSettingsSheet` opens this sheet as a separate
/// `NavigationLink` next to `RoomNotifSettingsSection`).
struct MemberCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var roomService: RoomService

    /// Live room from the service cache — the toggle RPC mirrors
    /// into `room.calendarAutoAdd`, so the toggle reflects server
    /// truth instead of the snapshot captured when the sheet
    /// opened. Same source of truth the BriefingSlot reads.
    let room: Room

    /// True when the system has granted EventKit access. Tracked
    /// locally so a denial flips the status row without bouncing
    /// the toggle back off (the user can fix access in iOS
    /// Settings later).
    @State private var authorizationStatus: EKAuthorizationStatus

    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    init(room: Room) {
        self.room = room
        _authorizationStatus = State(initialValue: CalendarService.shared.authorizationStatus())
    }

    private var liveRoom: Room {
        roomService.rooms.first(where: { $0.id == room.id }) ?? room
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(
                        get: { liveRoom.calendarAutoAdd },
                        set: { newValue in
                            Task { await toggle(newValue) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Add Games Room events to my calendar")
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Palette.primaryText)
                            Text("Applies to every room you're in. Events appear on your default iOS calendar.")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        }
                    }
                    .tint(Theme.Palette.accent)
                    .disabled(isSaving)
                } header: {
                    Text("Calendar")
                } footer: {
                    Text("iOS will ask to allow calendar access. To change it later: Settings → Games Room → Calendars.")
                }

                Section {
                    HStack {
                        Image(systemName: statusIcon)
                            .foregroundStyle(statusTint)
                        Text(statusLabel)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Palette.primaryText)
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(.red.opacity(0.85))
                    }
                } header: {
                    Text("Permission")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.Palette.background)
            .navigationTitle("My calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
                }
            }
        }
        .tint(Theme.Palette.accent)
        .onAppear {
            // Refresh the system auth status when the user comes
            // back from iOS Settings (they may have flipped the
            // permission there).
            authorizationStatus = CalendarService.shared.authorizationStatus()
        }
    }

    private var statusIcon: String {
        switch authorizationStatus {
        case .fullAccess, .authorized, .writeOnly:
            return Theme.Icon.checkmarkCircleFill
        case .denied, .restricted:
            return Theme.Icon.exclamationmarkTriangleFill
        case .notDetermined:
            return Theme.Icon.infoCircle
        @unknown default:
            return Theme.Icon.infoCircle
        }
    }

    private var statusTint: Color {
        switch authorizationStatus {
        case .fullAccess, .authorized, .writeOnly:
            return Theme.Palette.accent
        case .denied, .restricted:
            return Color.red.opacity(0.85)
        case .notDetermined:
            return Theme.Palette.primaryText.opacity(0.55)
        @unknown default:
            return Theme.Palette.primaryText.opacity(0.55)
        }
    }

    private var statusLabel: String {
        switch authorizationStatus {
        case .fullAccess, .authorized, .writeOnly:
            return "Allowed"
        case .denied, .restricted:
            return "Denied — open Settings to change"
        case .notDetermined:
            return "Not yet asked"
        @unknown default:
            return "Unknown"
        }
    }

    /// Flips the toggle server-side. If the user is enabling for
    /// the first time, request EventKit access first; on denial,
    /// surface the inline status row but DO NOT flip the server
    /// toggle off (the user's intent is preserved — they'll
    /// re-tap after granting in iOS Settings).
    private func toggle(_ newValue: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        if newValue {
            let granted = await CalendarService.shared.requestAccess()
            authorizationStatus = CalendarService.shared.authorizationStatus()
            // V0.86 — gate the BriefingSlot mascot voice line. Any
            // first-time interaction with the toggle is "seen" —
            // denied or granted, the row doesn't come back.
            CalendarPrompt.markVoiceLineSeen()
            if !granted {
                errorMessage = "Calendar access denied. Open Settings → Games Room → Calendars to allow it, then toggle back on."
                // Don't write the server-side toggle — the user
                // hasn't consented yet. They can retry after
                // granting permission.
                return
            }
        }

        do {
            try await roomService.setMemberCalendarAutoAdd(enabled: newValue)
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}

/// V0.86 — the BriefingSlot mascot voice line for first-time
/// calendar permission. Substrate: one-time, then gone (the
/// `CalendarPrompt.markVoiceLineSeen` gate ensures the row never
/// re-appears, even after a system permission denial). Tap opens
/// the per-member settings sheet where the user can flip the
/// toggle + trigger the system permission prompt via
/// `CalendarService.requestAccess()`.
/// Non-private: rendered from RoomDetailView.swift (BriefingSlot).
struct CalendarVoiceLineRow: View {
    @State private var showSettings: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Layout.gutter / 2) {
            Image(systemName: "calendar.badge.plus")
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.accent)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Games Room events to your calendar.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Button {
                    showSettings = true
                } label: {
                    Text("Allow")
                        .font(Theme.Typography.caption.weight(.semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
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
        .sheet(isPresented: $showSettings) {
            // The settings sheet reads `room` from the briefing
            // context — but the voice line doesn't carry a
            // specific room reference (the toggle is per-user).
            // Use a placeholder room; the sheet only reads
            // `room.calendarAutoAdd` (a mirrored boolean) and
            // ignores the rest. The roomService mirror ensures
            // every cached room shows the live toggle state.
            MemberCalendarSettingsSheet(room: Room.voiceLinePlaceholder)
        }
    }
}

private extension Room {
    /// V0.86 — placeholder room for the voice-line tap handler.
    /// The toggle is per-user; the sheet only reads
    /// `calendarAutoAdd` (live from `roomService.rooms` mirror).
    static var voiceLinePlaceholder: Room {
        Room(
            id: UUID(),
            name: "",
            mascotName: "",
            mascotPersonality: .friendly,
            mascotPoliticalIdeology: .centrist,
            createdBy: UUID(),
            createdAt: Date(),
            updatedAt: Date(),
            isLive: false,
            userRole: .member
        )
    }
}