import SwiftUI

// MARK: - Theme
//
// Games Room design system tokens. Source of truth for palette, type, and
// layout. SectionCard lives here because it is a token (a styled container),
// not a feature component — see the locked "no new components in Theme.swift
// without a deliberate reason" rule.
//
// The 5-color palette is dark-mode-first. iOS semantic hex values chosen for
// an OLED-pleasant near-black background, an off-white primary that reads as
// warm parchment, and a brass-warm single accent. One accent at a time per
// the 80/20/10 rule.
//
// The dominant-action wash now drives a single wash level per slot, not per
// section. `SectionCard.hero` is that single wash level.
enum Theme {

    // MARK: Palette (5 colors, dark-mode-first hex)
    //
    // Hex values are iOS standard sRGB; use `Color(...)` for SwiftUI.
    enum Palette {
        /// Near-black app background (the OLED-friendly canvas).
        static let background = Color(red: 0.039, green: 0.039, blue: 0.043)        // #0A0A0B
        /// One step lifted off the background — the card / sheet surface.
        static let surface = Color(red: 0.075, green: 0.075, blue: 0.082)           // #131315
        /// Off-white primary text — warm parchment, not pure white.
        static let primaryText = Color(red: 0.957, green: 0.937, blue: 0.902)       // #F4EFE6
        /// Mid-gray hairline — divider lines and quiet chrome.
        static let hairline = Color(red: 0.239, green: 0.239, blue: 0.251)         // #3D3D40
        /// Brass-warm single accent. The only chromatic voice in the app.
        static let accent = Color(red: 0.690, green: 0.553, blue: 0.341)            // #B08D57
    }

    // MARK: Typography
    //
    // `Font.system` tokens. Serif is reserved for display only (chapter
    // titles, the ceremonial card headline). Every other voice is the default
    // (rounded SF) family — keeps the app readable in motion and at table
    // distance.
    enum Typography {
        /// Display — Fraunces, ceremonial card chapter title (28pt).
        /// Same face as the website's display serif. Wonky, warm, hand-made.
        static let display = Font.custom("Fraunces", size: 28)
        /// Display italic — Fraunces italic, the "kept." / "compounds." moments.
        static let displayItalic = Font.custom("Fraunces", size: 28).italic()
        /// Title — default family, room / section title (22pt).
        static let title = Font.system(size: 22, weight: .semibold, design: .default)
        /// Body — default family, the regular reading voice (17pt).
        static let body = Font.system(size: 17, weight: .regular, design: .default)
        /// Caption — default family, the mascot footer caption (13pt).
        static let caption = Font.system(size: 13, weight: .regular, design: .default)
        /// Footnote — default family, smallest voice (11pt).
        static let footnote = Font.system(size: 11, weight: .regular, design: .default)
    }

    // MARK: Layout
    //
    // Spacing scale is 4-pt grid: 16 / 24 / 32. `gridCellMin` is the iPad
    // tile minimum (locked in `.designs/room-page/BRIEF.md` Q2).
    enum Layout {
        /// Outer column gutter (the iPad black margin lives outside this).
        static let gutter: CGFloat = 32
        /// Interior card inset — distance from card edge to its content.
        static let cardInset: CGFloat = 16
        /// Minimum width for a grid cell before it wraps.
        static let gridCellMin: CGFloat = 320
        /// Edge padding for screen-aligned content.
        static let edgePadding: CGFloat = 16
        /// Vertical spacing between consecutive sections in a slot.
        static let sectionSpacing: CGFloat = 24
        /// Min width for a host-scoring chip. 160 on iPad (table-distance
        /// tap target), 120 on iPhone.
        static func scoringChipMin(for hSize: UserInterfaceSizeClass?) -> CGFloat {
            hSize == .regular ? 160 : 120
        }
    }

    // MARK: SectionCard
    //
    // Two surface styles: `.standard` for most sections (no wash) and
    // `.hero` for the single section that carries the slot's dominant-action
    // wash (the 10% brass tint, per the 80/20/10 rule).
    //
    // The wash is a single level per slot — exactly one `.hero` per slot.
    enum SectionCard {
        /// No wash. The default for everything except the slot's hero.
        case standard
        /// The 10% brass-warm wash — used by exactly one section per slot.
        case hero

        /// Background color for the card body.
        var background: Color {
            switch self {
            case .standard: return Palette.surface
            case .hero:     return Palette.accent.opacity(0.10)
            }
        }

        /// Hairline color for the card's top/bottom dividers.
        var hairline: Color { Palette.hairline }
    }

    // MARK: Motion (V0.70)
    //
    // Centralises the animation timings already in use across the
    // codebase so new surfaces stop inventing one-offs. Existing
    // call sites stay on their literals (no refactor); new code in
    // the V0.70 microinteractions pass uses these tokens.
    enum Motion {
        /// Press feedback — matches PressScaleModifier.
        static let pressSpring = Animation.spring(response: 0.2, dampingFraction: 0.8)
        /// Element insertion/removal (badge in, row out, CTA in).
        static let popIn = Animation.spring(response: 0.3, dampingFraction: 0.7)
        /// Content cross-fades (CTA label flip, caption change, slot state).
        static let fade = Animation.easeInOut(duration: 0.25)
    }

    // MARK: Icons (M2.5)
    //
    // SF Symbol names that recur across the app — the seat-grid,
    // pack shelf, room settings, and toolbar. Centralising them
    // here means a future redesign can swap symbols in one place
    // instead of grepping across views. Names are iOS 17+
    // SF Symbols (the project targets iOS 26+).
    enum Icon {
        /// The "this seat is yours" affordance on the seat grid.
        static let chairFill = "chair.fill"
        /// The "this seat is open" affordance on the seat grid.
        /// Outline variant so it reads as available, not claimed.
        static let chair = "chair"
        /// The "another member is sitting here" affordance on the
        /// seat grid. Paired with their initial in the same cell.
        static let personFill = "person.fill"
        /// The settings gear in the room toolbar.
        static let gearshape = "gearshape"
        /// The create-room "+" in the Rooms toolbar.
        static let plus = "plus"
        /// The "switch room" chevron inside the rooms dropdown.
        static let chevronDown = "chevron.down"
        /// The chevron historically used on pack-row taps. The
        /// Track E verdict dropped it; kept here so a future
        /// surface can opt back in without re-deriving the name.
        static let chevronRight = "chevron.right"
        /// The checkmark on the current room inside the
        /// RoomSwitcherMenu.
        static let checkmark = "checkmark"
        /// The score-correction amber dot for the F-MVP-11
        /// 60-second "host correcting" indicator on leaderboard
        /// rows.
        static let circleFill = "circle.fill"
        /// The active-event accent dot on the rooms list.
        static let activeSessionDot = "circle.fill"
        /// The "you're in" confirmation on a claimed seat.
        static let checkmarkCircleFill = "checkmark.circle.fill"
        /// The host's "Score a round" CTA on the witness slot.
        static let checkmarkSealFill = "checkmark.seal.fill"
        /// Dismiss on the system banner and other dismiss buttons.
        static let xmark = "xmark"
        /// The "How to play" drill-down on pack rows.
        static let infoCircle = "info.circle"
        /// Mint a fresh join code (no code yet).
        static let plusCircle = "plus.circle"
        /// The filled create-room CTA in the room switcher dropdown.
        static let plusCircleFill = "plus.circle.fill"
        /// Re-mint a fresh join code (code exists).
        static let arrowClockwise = "arrow.clockwise"
        /// The expand/collapse chevron on leaderboard rows.
        static let chevronUp = "chevron.up"
        /// The host payout affordance on pack shelf rows.
        static let sliderHorizontal3 = "slider.horizontal.3"
        /// The "standings below" hint on the witness slot.
        static let arrowDown = "arrow.down"
        /// The witness-slot header mark.
        static let circleHexagongridFill = "circle.hexagongrid.fill"
        /// The Social sub-sheet row in room settings.
        static let bubbleLeftAndBubbleRightFill = "bubble.left.and.bubble.right.fill"
        /// The Members sub-sheet row in room settings.
        static let person2Fill = "person.2.fill"
        /// The destructive "Delete room" affordance in room settings.
        static let trashFill = "trash.fill"
        /// The working-hand badge on the in-play witness slot.
        static let handPointUpFill = "hand.point.up.fill"
        /// V0.79 — the notification opt-in prompt card + settings row.
        static let bellFill = "bell.fill"
        /// V0.79 — the per-event mute row in notification settings.
        static let bellSlashFill = "bell.slash.fill"
        /// V0.80 — the join-room toolbar affordance for existing members.
        static let personCropCircleBadgePlus = "person.crop.circle.badge.plus"
        /// V0.81 — autosave failure status in room settings.
        static let exclamationmarkTriangleFill = "exclamationmark.triangle.fill"
    }
}

// MARK: - sectionCard modifier
//
// Applies a `SectionCard` style to any view. Use to wrap the content of a
// section (typically a `VStack`) — produces the surface fill, the rounded
// corners, and the hairline dividers without owning layout.
//
// Example:
//     VStack(alignment: .leading, spacing: 12) { ... }
//         .sectionCard(.hero)
extension View {
    /// Apply a `SectionCard` style — surface fill, hairline divider, rounded
    /// corners. Use `.hero` for the slot's single dominant section; use
    /// `.standard` for everything else.
    func sectionCard(_ style: Theme.SectionCard) -> some View {
        self
            .padding(Theme.Layout.cardInset)
            .background(style.background)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(style.hairline, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - contentColumn modifier
//
// Centers content on iPad inside a fixed-width iPhone-shaped column with
// black margin. On iPhone, this is a no-op (the column fills the screen).
// Per `.designs/room-page/BRIEF.md` Q2, the iPad renders the iPhone column
// centered with black margin — never a stretched two-pane layout.
//
// Example:
//     ScrollView { ... }
//         .contentColumn()
extension View {
    /// Wrap content in an iPhone-shaped column. On iPhone, fills the screen;
    /// on iPad, centers a fixed-width column with black margin.
    func contentColumn(maxWidth: CGFloat? = nil) -> some View {
        self
            .frame(maxWidth: maxWidth ?? 560)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Layout.edgePadding)
    }
}