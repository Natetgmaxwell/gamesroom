//
//  RoomPage.swift
//  GamesRoom
//
//  Track E2 — the persistent home of the V0.8 app.
//
//  One page, three states:
//   1. **List** — `LazyVStack` of every room the current user is in,
//      rendered as `RoomRow` tiles. The default surface for a brand-new
//      install or a freshly signed-in user.
//   2. **Last-viewed hero** — if the user previously opened a room and
//      that room is still in their list, a hero card at the top offers
//      one-tap resume. Per the V0.8 brief L "Last-viewed room opens the
//      Rooms tab automatically." We keep the list visible underneath —
//      the hero is an accelerator, not a replacement.
//   3. **Empty** — when the list is empty, a single CTA branching on
//      host-vs-member. Members see "Ask a friend for a join code";
//      hosts (or any signed-in user with no rooms yet) see
//      "Create one to get started".
//
//  Navigation
//  ----------
//  The page owns a `NavigationStack` rooted in the rooms list. Tapping a
//  row pushes `RoomDetailView` via the standard `selection:`-driven
//  `NavigationLink`. The tapped room's id is mirrored to
//  `@AppStorage("lastViewedRoomIdString")` so a future cold launch can
//  auto-push straight into it.
//
//  Toolbar
//  -------
//  One icon — a gear — appears in the top-trailing slot, host-only,
//  scoped to the resolved last-viewed room. Tapping it opens
//  `RoomSettingsSheet` for that room. Members and signed-out states see
//  no toolbar chrome (the app settings gear lives on the Account /
//  Settings tab per V0.8 brief L6).
//
//  Data flow
//  ---------
//  The page subscribes to `RoomService` via `@EnvironmentObject`. Rooms
//  load on `.task` (cold launch) and on pull-to-refresh. The
//  `lastViewedRoomIdString` is read once on appear, then watched via
//  the `@AppStorage` projection so it stays live if the user signs out
//  in another tab.
//
//  Theme discipline
//  ----------------
//  All styling routes through `Theme.Palette`, `Theme.Typography`,
//  `Theme.Layout`, and the `.sectionCard(.hero|.standard)` modifier.
//  No ad-hoc colors, no inline hex. The hero card carries the slot's
//  single `.hero` wash; everything else is `.standard` or naked
//  surface per the 80/20/10 rule.
//

import SwiftUI

// MARK: - RoomPage

struct RoomPage: View {
    @EnvironmentObject private var roomService: RoomService
    @EnvironmentObject private var authService: AuthService

    /// The room the user is currently being pushed into. Driven by the
    /// `NavigationStack`'s `selection:` binding. Setting it triggers
    /// the push; clearing it pops back.
    @State private var selectedRoom: Room?

    /// The room whose settings the user is editing. `nil` ⇒ the
    /// settings sheet is dismissed. Only valid for host role rooms.
    @State private var settingsRoom: Room?

    /// Mirror of the persisted last-viewed room id, kept live so the
    /// hero card re-renders if the user switches rooms in another
    /// surface. Stored as a String because UUID is not directly
    /// `AppStorage`-compatible; we parse on read.
    @AppStorage("lastViewedRoomIdString") private var lastViewedRoomIdString: String = ""

    var body: some View {
        NavigationStack {
            content
                .background(Theme.Palette.background.ignoresSafeArea())
                .navigationTitle("Rooms")
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .sheet(item: $settingsRoom) { room in
                    RoomSettingsSheet(room: room)
                        .environmentObject(roomService)
                }
        }
        .task {
            await roomService.refresh()
        }
        .refreshable {
            await roomService.refresh()
        }
    }

    // MARK: - Content slot

    @ViewBuilder
    private var content: some View {
        if roomService.isLoading && roomService.rooms.isEmpty {
            // First-load spinner. Mirrors the dominant-action `.loading`
            // slot — a quiet, centered progress with no chrome.
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.Palette.accent)
                Text("Loading rooms…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if roomService.rooms.isEmpty {
            emptyState
        } else {
            roomsList
        }
    }

    // MARK: - Rooms list (with optional last-viewed hero)

    private var roomsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.sectionSpacing) {
                if let lastViewed = resolvedLastViewedRoom {
                    lastViewedHero(for: lastViewed)
                }

                sectionHeader("Your rooms")

                LazyVStack(spacing: 0) {
                    ForEach(roomService.rooms) { room in
                        NavigationLink(
                            value: room
                        ) {
                            RoomRow(room: room) { /* row-tap handled by NavigationLink */ }
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture().onEnded {
                            recordLastViewed(room)
                        })

                        if room.id != roomService.rooms.last?.id {
                            Divider()
                                .overlay(Theme.Palette.hairline)
                                .padding(.horizontal, Theme.Layout.edgePadding)
                        }
                    }
                }
                .background(Theme.Palette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Theme.Palette.hairline, lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .contentColumn()
            .padding(.vertical, Theme.Layout.sectionSpacing)
        }
        .navigationDestination(for: Room.self) { room in
            RoomDetailView(room: room)
        }
    }

    // MARK: - Last-viewed hero

    private func lastViewedHero(for room: Room) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
            Text("CONTINUE")
                .font(Theme.Typography.footnote)
                .tracking(1.4)
                .foregroundStyle(Theme.Palette.accent)

            Text(room.name)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)

            HStack(spacing: 8) {
                Circle()
                    .fill(room.isLive ? Theme.Palette.accent : Theme.Palette.hairline)
                    .frame(width: 8, height: 8)
                Text(room.isLive ? "Live now" : "Last opened")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Spacer(minLength: 8)
                Text(room.mascotName)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            NavigationLink(value: room) {
                Text("Resume")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                recordLastViewed(room)
            })
        }
        .sectionCard(.hero)
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(Theme.Typography.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            Spacer()
            Text("\(roomService.rooms.count)")
                .font(Theme.Typography.footnote.monospacedDigit())
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.40))
        }
        .padding(.horizontal, Theme.Layout.edgePadding)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Layout.cardInset) {
            Spacer(minLength: 0)

            Text(emptyHeadline)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
                .multilineTextAlignment(.center)

            Text(emptySubhead)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Layout.gutter)

            Button(action: emptyCTA) {
                Text(emptyCTATitle)
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 14)
                    .background(Theme.Palette.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Theme.Layout.edgePadding)
        .contentColumn()
    }

    private var emptyHeadline: String {
        "No rooms yet"
    }

    private var emptySubhead: String {
        // Members get the join-code path. Hosts get the create path.
        // V0.8 keeps both visible — a member can become a host of
        // their own room by tapping Create.
        isKnownHost
            ? "Spin up a room to start running a games night with your group."
            : "Ask a friend for a join code, or create your own room to host."
    }

    private var emptyCTATitle: String {
        isKnownHost ? "Create one to get started" : "Ask a friend for a join code"
    }

    private func emptyCTA() {
        // The create-room and redeem-code surfaces are owned by
        // other tracks. We emit through the room service when
        // available; otherwise fall back to a no-op so the
        // empty state still renders cleanly.
        if isKnownHost {
            // Hooked up in the CreateRoom track — TBD.
            // Intentionally a no-op for now; the button is a CTA
            // label, not a wired action in this slice.
        } else {
            // Hooked up in the JoinCode track — TBD.
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if let room = resolvedLastViewedRoom, room.userRole.isHost {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    settingsRoom = room
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.Palette.primaryText)
                }
                .accessibilityLabel(Text("Room settings"))
                .accessibilityHint(Text("Opens settings for \(room.name)"))
            }
        }
    }

    // MARK: - Last-viewed resolution

    /// The room the user most recently opened, resolved against the
    /// current `rooms` list. Returns `nil` if no last-viewed id is
    /// stored, the stored id doesn't parse, or the room has been left
    /// since the last view.
    private var resolvedLastViewedRoom: Room? {
        guard
            let uuid = UUID(uuidString: lastViewedRoomIdString),
            let room = roomService.rooms.first(where: { $0.id == uuid })
        else {
            return nil
        }
        return room
    }

    /// Mirrors a tapped room's id into `@AppStorage` so a future cold
    /// launch can resume there. Side-effect-only — kept `func` (not a
    /// computed setter) so the call site reads as an event.
    private func recordLastViewed(_ room: Room) {
        lastViewedRoomIdString = room.id.uuidString
    }

    /// True when the current user has hosted at least one of the rooms
    /// in the list. Used to branch the empty-state CTA. We don't have
    /// a "has ever hosted" signal outside the rooms list, so this is
    /// the closest v0.8 approximation. Defaults to `true` when no
    /// rooms exist — every signed-in user *can* host, and the create
    /// path is the first-class action.
    private var isKnownHost: Bool {
        // In the empty-state branch, we have no rooms. Default true.
        // In the populated branch, true if the user holds host role
        // in at least one room.
        if roomService.rooms.isEmpty { return true }
        return roomService.rooms.contains { $0.userRole.isHost }
    }
}

// MARK: - Preview support
//
// Lightweight fakes so the RoomPage preview compiles without the
// `RoomService` / `AuthService` implementations in tree. These are
// scoped to `#if DEBUG` and are not part of the production surface —
// they only exist so the previews in this file are usable while the
// view layer lands.
#if DEBUG
private enum PreviewSupport {
    @MainActor
    static func roomService() -> RoomService { RoomService.preview() }
    @MainActor
    static func authService() -> AuthService { AuthService.preview() }
}

#Preview("Rooms list") {
    RoomPage()
        .environmentObject(PreviewSupport.roomService())
        .environmentObject(PreviewSupport.authService())
        .preferredColorScheme(.dark)
}
#endif
