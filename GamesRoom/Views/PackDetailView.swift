//
//  PackDetailView.swift
//  GamesRoom
//
//  Track V0.9 Wave 2 Slice 2.1 - per-pack how-to body. Renders
//  the `PackHowTo` content for a pack as a sheet. Reached from
//  the pack-toggle rows in `RoomSettingsSheet`; the sheet does
//  not allow any host action - it's a read-only rules surface.
//
//  Packs without bundled how-to content show their description
//  so the picker still drills down cleanly.
//

import SwiftUI

struct PackDetailView: View {
    let pack: any PackDefinition.Type
    let onDismiss: () -> Void

    private var howTo: PackHowTo? {
        PackHowToCatalog.howTo(forSlug: pack.howToSlug)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Layout.cardGroupGap) {
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
        // v1.2.4 S4.7 — the nav title already carries the pack name,
        // so the header no longer prints it a second time. What is
        // left is the pack's mark and its scoring type: the icon wears
        // the app's title face (scaled up) and the label sits
        // `cardInset` from it.
        HStack(spacing: Theme.Layout.cardInset) {
            Image(systemName: pack.iconSystemName)
                .accessibilityHidden(true)
                .font(Theme.Typography.title)
                .imageScale(.large)
                .foregroundStyle(Theme.Palette.accent)
            Text(pack.scoringType.displayLabel)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            Spacer()
        }
    }

    @ViewBuilder
    private func summaryBlock(_ howTo: PackHowTo) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            Text(howTo.headline)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.primaryText)
            Text(howTo.summary)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.bodyMuted)
        }
    }

    @ViewBuilder
    private func sectionBlock(_ section: PackHowTo.Section) -> some View {
        // v1.2.4 S4.7 — the ad-hoc 4pt top bump is gone: the outer
        // stack's `cardGroupGap` is the only gap between two sections.
        VStack(alignment: .leading, spacing: Theme.Layout.cardLineGap) {
            Text(section.title)
                .font(Theme.Typography.body.weight(.semibold))
                .foregroundStyle(Theme.Palette.primaryText)
            Text(section.body)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Palette.bodyMuted)
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        Text(pack.description)
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Palette.labelText)
    }
}
