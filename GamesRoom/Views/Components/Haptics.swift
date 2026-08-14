import SwiftUI

// MARK: - Haptics
//
// Thin wrapper over UIKit's feedback generators so call sites read as
// intent ("claim succeeded") rather than generator plumbing. All methods
// are no-ops on macOS (the parse-check gate compiles this file against
// the macOS SDK, where UIKit is unavailable).
enum Haptics {
    /// A success notification — seat claimed, score saved, config saved.
    static func success() {
        #if !os(macOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    /// A light impact — decline, release, pull-to-refresh completion.
    static func light() {
        #if !os(macOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A medium impact — a more deliberate action.
    static func medium() {
        #if !os(macOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// A warning — low-confidence scan result asking for a re-scan.
    static func warning() {
        #if !os(macOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}