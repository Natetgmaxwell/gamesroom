import SwiftUI

struct SettingsPage: View {
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        AppSettingsView()
            .frame(maxWidth: Theme.Layout.contentMaxWidth(for: hSize), alignment: .center)
            .padding(.horizontal, Theme.Layout.gutter(for: hSize))
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Theme.background.ignoresSafeArea())
            .tint(Theme.accent)
    }
}