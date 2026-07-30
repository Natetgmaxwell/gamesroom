import SwiftUI

struct SettingsPage: View {
    var body: some View {
        AppSettingsView()
            .background(Theme.background.ignoresSafeArea())
            .tint(Theme.accent)
    }
}
