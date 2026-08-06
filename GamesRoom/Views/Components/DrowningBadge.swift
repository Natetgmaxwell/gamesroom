//
//  DrowningBadge.swift
//  GamesRoom
//
//  Wave 1 Slice 1.1 — privacy-aware rendering of the Drowning
//  season-end award.
//
//  Renders a Drowning `SeasonAward` row with one of three surfaces:
//
//    1. Recipient view (current user IS the recipient):
//       The full row PLUS an opt-in toggle that flips
//       `room_memberships.member_drowning_opt_in` for the current
//       user's membership in this room. Default = off (privacy-
//       respecting per the roadmap's Q-DROWNING-OPT-IN-DEFAULT).
//
//    2. Opted-in viewer view (current user has opted in AND is not
//       the recipient): The muted "shared drowning" row. Reads the
//       same shape as the host-public awards but with a quieter
//       treatment so the recipient's privacy is still honoured
//       visually.
//
//    3. Non-opted-in viewer: NOT rendered at all (the upstream
//       resolver in `RoomDetailView.seasonAwardsForPrivacy` filters
//       drowning rows out for non-opted-in members). The RLS policy
//       in migration 045 enforces the same gate at the database.
//
//  The toggle's persistence path is `set_drowning_opt_in(p_room_id,
//  p_opt_in)` RPC (migration 045). On toggle, the parent view calls
//  `RoomService.setDrowningOptIn(roomId:optIn:)` which wraps the RPC
//  and refreshes the cached Room so the toggle reflects in the
//  RoomSettingsSheet and the awards card without a manual reload.
//

import SwiftUI

/// Privacy-aware view of a single Drowning `SeasonAward`.
/// Render only when:
///   - the current user is the recipient (and may opt in / out), OR
///   - the current user has opted in (and sees the muted row).
struct DrowningBadge: View {
    let award: SeasonAward
    let isRecipient: Bool
    let isOptedIn: Bool
    let onToggleOptIn: (Bool) -> Void

    private var iconName: String { "drop.fill" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(award.recipientDisplayName)
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Text("·")
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.4))
                        Text("Drowning")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                    if let caption = award.caption, !caption.isEmpty {
                        Text(caption)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    }
                }
                Spacer()
            }

            if isRecipient {
                // Recipient view: the opt-in toggle. Muted copy so the
                // privacy affordance reads as a deliberate choice, not
                // a default action.
                optInToggle
            } else {
                // Viewer view: explain that this row is opt-in only.
                viewerFootnote
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var optInToggle: some View {
        Toggle(isOn: Binding(
            get: { isOptedIn },
            set: { onToggleOptIn($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Share with the room")
                    .font(Theme.Typography.caption.weight(.semibold))
                Text("Members who opt in can see this row. Off by default.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
        }
        .tint(Theme.Palette.accent)
        .padding(.leading, 28)  // align under the row text, past the icon
    }

    @ViewBuilder
    private var viewerFootnote: some View {
        Text("Visible because you've opted in to Drowning shares.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            .padding(.leading, 28)
    }
}
