//
//  PackDetailView.swift
//  GamesRoom
//
//  Track V0.9 Wave 2 Slice 2.1 - per-pack how-to body. Renders
//  the `PackHowTo` content for a pack as a sheet. Reached from
//  the pack-toggle rows in `RoomSettingsSheet`; the sheet does
//  not allow any host action - it's a read-only rules surface.
//
//  Packs without bundled how-to content show a "rules coming
//  soon" placeholder so the picker still drills down cleanly.
//  The placeholder copy is intentionally low-key so the empty
//  state doesn't feel like a missing feature.
//

import SwiftUI

struct PackDetailView: View {
    let pack: any PackDefinition
    let onDismiss: () -> Void

    private var howTo: PackHowTo? {
        PackHowToCatalog.howTo(forSlug: pack.howToSlug)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.cardInset) {
                    header
                    if let howTo {
                        summaryBlock(howTo)
                        ForEach(howTo.sections) { section in
                            sectionBlock(section)
                        }
                    } else {
                        placeholder
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Layout.cardInset)
            }
            .background(Theme.Palette.background)
            .navigationTitle(pack.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .font(Theme.Typography.body.weight(.semibold))
                }
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: pack.iconSystemName)
                .font(.system(size: 36))
                .foregroundStyle(Theme.Palette.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(pack.displayName)
                    .font(Theme.Typography.title.weight(.semibold))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text(pack.scoringType == .singleWinner ? "Single winner" : "Withdraw & return")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func summaryBlock(_ howTo: PackHowTo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(howTo.headline)
                .font(Theme.Typography.title3.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            Text(howTo.summary)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: PackHowTo.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            Text(section.body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.8))
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(pack.description)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.7))
        Text("Detailed rules are coming soon.")
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            .padding(.top, 4)
    }
}
