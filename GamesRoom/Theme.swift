import SwiftUI

// ponytail: hardcoded constants, not a Theme EnvironmentValue. Promote when a second view reads the same value.
enum Theme {
    // ── Palette (raw colours) ────────────────────────────────────────────────
    // Three families. Sections read from Role, not from Palette directly,
    // so a 80:20:10 split stays enforced everywhere.
    static let background   = Color(red: 0.039, green: 0.039, blue: 0.043)        // #0A0A0B
    static let primaryText  = Color(red: 0.957, green: 0.937, blue: 0.902)        // #F4EFE6
    static let secondaryText = Color(red: 0.6,   green: 0.6,   blue: 0.6)
    static let accent       = Color(red: 0.690, green: 0.553, blue: 0.341)        // #B08D57 brass
    static let hairline     = Color(red: 0.239, green: 0.239, blue: 0.251)        // #3D3D40 ash
    static let cardSurface  = Color(red: 0.075, green: 0.075, blue: 0.082)        // #131315
    static let successTint  = Color(red: 0.45,  green: 0.65,  blue: 0.45)
    static let heroShadow   = Color.black.opacity(0.6)

    static let displayFont = Font.system(size: 28, weight: .regular, design: .serif)
    static let bodyFont   = Font.system(size: 17, weight: .regular, design: .default)

    /// 80/20/10 colour roles. Sections read from here, not from the raw
    /// palette directly, so a single switch of the dominant action
    /// (Tonight / Standings / Withdraw / Settle) reshuffles the visual
    /// hierarchy in one place.
    ///
    /// Split:
    ///   **80% dominant**  — surface, body, hero text. Never competes.
    ///   **20% secondary** — structure (hairlines, dividers, section
    ///                      labels). Carries the eye without claiming it.
    ///   **10% accent**    — the dominant action for the current room
    ///                      state. Only one section carries the warm wash
    ///                      at a time. This is the "direct the user's
    ///                      attention" lever the user asked for.
    enum Role {
        /// Background, card surface, primary text. Most of the canvas.
        static let dominantSurface = Theme.cardSurface
        static let dominantText    = Theme.primaryText

        /// Hairline, secondary text, section header labels. 20%.
        static let secondarySurface = Theme.hairline
        static let secondaryText    = Theme.secondaryText

        /// The dominant action accent. Dynamic per room state — see
        /// `accent(for: state)`. Always warm brass.
        static let accent       = Theme.accent
        static let accentMuted  = Theme.accent.opacity(0.55)
        static let accentFaint  = Theme.accent.opacity(0.10)
        static let accentBorder = Theme.accent.opacity(0.40)

        /// Cash-flow CTA: success / withdrawal / settle.
        static let positive    = Theme.successTint

        /// What's competing for the warm wash *right now*. The room's
        /// dominant action. View body should ask: "which of these is
        /// currently calling for attention?" and render that section
        /// with the hero treatment, dimming the rest to secondary.
        enum DominantAction: Equatable {
            /// Room is quiet — leaderboard / past games are the read.
            case readStandings
            /// Upcoming or active event — Tonight card takes the stage.
            case tonightEvent
            /// Casino running, member has points to withdraw.
            case withdrawChips
            /// Settle pending — host needs to finalize the round.
            case settleRound
        }

        /// Returns the hero wash opacity (the 10% accent overlay on a
        /// `.sectionCard(.hero)`). Sections outside the dominant action
        /// still render — they just get the cooler standard wash.
        static func heroWash(for action: DominantAction) -> Double {
            switch action {
            case .tonightEvent, .withdrawChips, .settleRound: return 0.10
            case .readStandings: return 0.04
            }
        }
    }

    /// Adaptive layout tokens. Phase-1 deliverable: revert the iPad
    /// gutter / contentMaxWidth / cardInset / gridCellMin widening so
    /// the iPad renders the iPhone view at its native size. The
    /// iPad's content column stays at iPhone proportions (32 gutter,
    /// no max width cap) and is centered on the iPad canvas with the
    /// remaining space as black margin. Adaptive resizing for iPad
    /// belongs in a follow-up that ports components properly, not by
    /// stretching iPhone sizes across the canvas.
    enum Layout {
        /// Horizontal gutter on either side of the main content column.
        /// 32 on both iPhone and iPad — the iPad's larger canvas just
        /// shows more black margin around the iPhone-shaped column.
        static let gutter: CGFloat = 32

        /// Card inner content inset. Same on both form factors.
        static let cardInset: CGFloat = 16

        /// Min width for an adaptive grid cell (rooms, packs).
        static let gridCellMin: CGFloat = 320

        /// Adaptive branching helpers (kept for callers that want
        /// the form-factor check, even though the values are equal
        /// for now).
        static func gutter(for hSize: UserInterfaceSizeClass?) -> CGFloat { 32 }
        static func contentMaxWidth(for hSize: UserInterfaceSizeClass?) -> CGFloat? { nil }
        static func cardInset(for hSize: UserInterfaceSizeClass?) -> CGFloat { 16 }
        static func gridCellMin(for hSize: UserInterfaceSizeClass?) -> CGFloat { 320 }
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
        /// Accent overlay opacity. Standard = quiet surface tint; hero
        /// = the 10% warm wash that draws the eye to the dominant action.
        var tintOpacity: Double {
            switch self {
            case .standard: return 0.03
            case .hero: return 0.10
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

/// Resolves the dominant action for a room based on its live state.
/// Each branch returns a `.hero` treatment for the section that owns
/// the user's attention right now. Sections that aren't dominant
/// still render — they just don't carry the warm wash.
enum RoomHue {
    static func dominantAction(
        activeEvent: ActiveEvent?,
        packs: [RoomPack],
        eventWithdrawals: [CasinoWithdrawal],
        eventTransactions: [EventTransaction],
        currentMemberPoints: Int,
        isHost: Bool,
        hasOpenAttestations: Bool
    ) -> Theme.Role.DominantAction {
        // Host with an active settle-pending event: settle is the work.
        if isHost,
           let event = activeEvent,
           eventTransactions.contains(where: { $0.kind == "casino_withdrawal" }) {
            return .settleRound
        }
        // Active event — upcoming OR live — Tonight card takes the eye.
        if activeEvent != nil {
            return .tonightEvent
        }
        // Casino pack enabled and member has a withdrawable balance.
        let hasCasino = packs.contains(where: { $0.slug == "casino" })
        if hasCasino, currentMemberPoints > 0 {
            return .withdrawChips
        }
        // Default: read-only — Standings is the page.
        return .readStandings
    }
}

