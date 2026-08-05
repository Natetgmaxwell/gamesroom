//
//  SettingsPage.swift
//  GamesRoom
//
//  The Settings tab in ContentView.swift. Wraps AppSettingsView in
//  the V0.8 page chrome: edge padding, gutter, max content width,
//  background, and the single brass accent tint.
//
//  The V0.7.1 version of this file used Theme.Layout.contentMaxWidth(for:)
//  and Theme.background — neither of which exist in the V0.8 theme.
//  V0.8 has Layout.gutter (fixed at 32pt) and Palette.background; the
//  adaptive iPad-vs-iPhone branching is gone (the V0.7 → V0.8
//  refactor reverted that). So V0.8 ships a single-shape page.
//

import SwiftUI

struct SettingsPage: View {
    var body: some View {
        AppSettingsView()
            .padding(.horizontal, Theme.Layout.gutter)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Theme.Palette.background.ignoresSafeArea())
            .tint(Theme.Palette.accent)
            .navigationTitle("Settings")
    }
}
