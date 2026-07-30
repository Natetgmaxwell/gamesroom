import SwiftUI

// ponytail: hardcoded constants, not a Theme EnvironmentValue. Promote when a second view reads the same value.
enum Theme {
    static let background = Color(red: 0.039, green: 0.039, blue: 0.043)        // #0A0A0B
    static let primaryText = Color(red: 0.957, green: 0.937, blue: 0.902)        // #F4EFE6
    static let secondaryText = Color(red: 0.6, green: 0.6, blue: 0.6)
    static let accent = Color(red: 0.690, green: 0.553, blue: 0.341)              // #B08D57 brass
    static let hairline = Color(red: 0.239, green: 0.239, blue: 0.251)            // #3D3D40 ash
    static let cardSurface = Color(red: 0.075, green: 0.075, blue: 0.082)        // #131315
    static let successTint = Color(red: 0.45, green: 0.65, blue: 0.45)
    static let heroShadow = Color.black.opacity(0.6)

    static let displayFont = Font.system(size: 28, weight: .regular, design: .serif)
    static let bodyFont = Font.system(size: 17, weight: .regular, design: .default)

    /// Adaptive layout tokens. One source of truth for every view that
    /// reads a size class — no more scattered `32` / `48` / `maxWidth: 720`
    /// hardcodes. Each value branches on horizontal size class so the
    /// same screen reads correctly on iPhone and fills the iPad canvas
    /// proportionally. Pass the size class explicitly to keep this
    /// token set free of @Environment dependencies (the views already
    /// read the size class once and forward it).
    enum Layout {
        /// Horizontal gutter on either side of the main content column.
        /// 32 on iPhone (matches the human-interface margin), 64 on iPad
        /// (roomier so wide canvases don't strand empty space).
        static func gutter(compact: CGFloat = 32, regular: CGFloat = 64) -> CGFloat {
            regular
        }

        /// Maximum width of the centered content column. The view grows
        /// horizontally into this cap, then centers. Lets the iPad canvas
        /// actually carry content instead of stretching iPhone-sized
        /// cards into 2000pt of empty edges.
        ///
        /// `nil` = no cap (view fills the gutter-constrained column).
        static func contentMaxWidth(compact: CGFloat? = nil, regular: CGFloat? = 920) -> CGFloat? {
            regular
        }

        /// Inset for inner card content. Tighter on iPhone, roomier on
        /// iPad so the card doesn't read as an iPhone rectangle glued
        /// onto an iPad screen.
        static func cardInset(compact: CGFloat = 16, regular: CGFloat = 24) -> CGFloat {
            regular
        }

        /// Min width for an adaptive grid cell (rooms, packs).
        static func gridCellMin(compact: CGFloat = 320, regular: CGFloat = 420) -> CGFloat {
            regular
        }

        /// Branching helper: pass the size class, get the value.
        static func gutter(for hSize: UserInterfaceSizeClass?) -> CGFloat {
            hSize == .regular ? 64 : 32
        }
        static func contentMaxWidth(for hSize: UserInterfaceSizeClass?) -> CGFloat? {
            hSize == .regular ? 920 : nil
        }
        static func cardInset(for hSize: UserInterfaceSizeClass?) -> CGFloat {
            hSize == .regular ? 24 : 16
        }
        static func gridCellMin(for hSize: UserInterfaceSizeClass?) -> CGFloat {
            hSize == .regular ? 420 : 320
        }
    }

    /// Standard section card. Same warm tint + hairline border + corner
    /// radius for every section container on the room page so the page
    /// reads as a single visual vocabulary.
    ///
    /// Two variants:
    /// - `.standard`: regular section (Standings, Past, Game packs)
    /// - `.hero`: the active event card; gets a slightly warmer accent wash
    ///   to signal "this is what you're here for right now."
    enum SectionCard {
        case standard
        case hero

        var cornerRadius: CGFloat {
            // Larger cards on iPad read better as "hero" surfaces;
            // iPhone keeps tighter 14pt to match the rest of the chrome.
            #if os(iOS)
            return UIDevice.current.userInterfaceIdiom == .pad ? 18 : 14
            #else
            return 14
            #endif
        }
        var borderWidth: CGFloat { 1 }
        var tintOpacity: Double {
            switch self {
            case .standard: return 0.03
            case .hero: return 0.06
            }
        }
    }
}

/// Convenience modifier: pin a view's content column to a max width
/// and center it inside the parent. Combine with `.padding(.horizontal,
/// Theme.Layout.gutter(for: hSize))` to give the column room on both
/// sides. Replaces per-view `.frame(maxWidth: 720)` / `.frame(maxWidth:
/// 500)` islands.
extension View {
    func contentColumn(maxWidth: CGFloat? = nil, alignment: Alignment = .center) -> some View {
        self.frame(maxWidth: maxWidth, alignment: alignment)
    }
}

extension View {
    /// Apply the standard section card background. Drop-in for the
    /// repeated RoundedRectangle + stroke + warm overlay pattern.
    func sectionCard(_ style: Theme.SectionCard = .standard) -> some View {
        self.background(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .stroke(Theme.hairline, lineWidth: style.borderWidth)
                .background(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .fill(Theme.cardSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: style.cornerRadius)
                        .fill(Theme.accent.opacity(style.tintOpacity))
                )
        )
    }
}
