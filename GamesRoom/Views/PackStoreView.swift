//
//  PackStoreView.swift
//  GamesRoom
//
//  Track F-MVP-07 — in-app pack store shell (W2.2).
//
//  Lists the four V0.8 packs with their installed state for the
//  room. All packs ship pre-installed in v1; the store is the
//  surface where paid packs will land (StoreKit deferred — the
//  shell carries the "v1-ready" placeholder, no purchase flow).
//  Tapping a pack opens its how-to body (PackDetailView).
//
//  Reachable from RoomSettingsSheet. Installed state reads the
//  room's enabled pack slugs via `RoomService.cachedRoomPacks`
//  (migration 041), falling back to the default installed set.
//

import SwiftUI

struct PackStoreView: View {
    let roomId: UUID

    @EnvironmentObject private var roomService: RoomService

    @State private var packDetailType: (any PackDefinition.Type)?
    @State private var enabledSlugs: Set<String> = []

    private var packs: [any PackDefinition.Type] {
        PackRegistry.shared.allPacks
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(packs.enumerated()), id: \.offset) { _, pack in
                    storeRow(pack)
                }
            } header: {
                Text("Available packs")
            } footer: {
                Text("All packs ship pre-installed in v1. Paid packs will appear here in a future release.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.background)
        .navigationTitle("Pack store")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let slugs = await roomService.loadRoomPacks(roomId: roomId)
            enabledSlugs = slugs.isEmpty
                ? Set(PackRegistry.shared.allPacks.map { $0.slug })
                : Set(slugs)
        }
        .sheet(item: Binding<AnyPackType?>(
            get: { packDetailType.map(AnyPackType.init) },
            set: { packDetailType = $0?.type }
        )) { wrapped in
            PackDetailView(
                pack: wrapped.type,
                onDismiss: { packDetailType = nil }
            )
        }
    }

    private func storeRow(_ pack: any PackDefinition.Type) -> some View {
        Button {
            packDetailType = pack
        } label: {
            HStack(spacing: Theme.Layout.gutter) {
                Image(systemName: pack.iconSystemName)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.displayName)
                        .font(Theme.Typography.body.weight(.semibold))
                        .foregroundStyle(Theme.Palette.primaryText)
                    Text(pack.description)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer()
                Text(enabledSlugs.contains(pack.slug) ? "Installed" : "Not enabled")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(enabledSlugs.contains(pack.slug)
                        ? Theme.Palette.accent
                        : Theme.Palette.primaryText.opacity(0.45))
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(pack.displayName), \(installedLabel(for: pack))"))
    }

    private func installedLabel(for pack: any PackDefinition.Type) -> String {
        enabledSlugs.contains(pack.slug) ? "installed" : "not enabled"
    }
}
