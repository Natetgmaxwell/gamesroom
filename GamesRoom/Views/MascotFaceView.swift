//
//  MascotFaceView.swift
//  GamesRoom
//
//  V0.94 — Tally mascot face renderer (slice A, view half).
//
//  A pure-SwiftUI vector renderer for `FaceParameters` produced by
//  `MascotFaceEngine`. No assets. No external state. The renderer
//  scales the locked 220×220 geometry to the host-provided `size`.
//
//  Hard invariants (V0.94 spec):
//    1. Async surfaces only — this view must NEVER appear in any
//       in-play / active-game view. The View never imports a
//       gameplay screen; callers are responsible for placement.
//    2. Default Tally = amber circle, dot eyes, line mouth.
//       "Off" means exactly this — `MascotFaceView(personality:
//       .professional, ideology: .apolitical, state: .idle)` is the
//       off-mask render.
//    3. 220×220 locked geometry — circle c(110,110) r100, eyes
//       (76,96)/(144,96) r9, mouth baseline y=142. The renderer
//       scales `size` into this space and back out via `Canvas`.
//    4. The "ink" colour (eye + brow + mouth stroke) is a single
//       warm-dark on amber: matches the JS reference's `INK` value
//       (`#2A2118`). Pulled out as a `Color` constant on the view
//       so a future dark-amber skin can override it.
//    5. V0.94 B — at avatar sizes (`size < MascotFaceEngine.
//       avatarSizeThreshold`) the brow curve deltas widen by the
//       engine's pinned factor (see `MascotFaceEngine.
//       browCurveScale(forRenderSize:)`). The renderer reads the
//       scale per-call; it does no branching on its own.
//
//  Pairing:
//
//      MascotFaceView(parameters: MascotFaceEngine.compute(
//          personality: room.mascotPersonality,
//          ideology:   room.mascotIdeology,
//          state:      resolvedRoomState
//      ))
//      .frame(width: 96, height: 96)
//

import SwiftUI

struct MascotFaceView: View {
    /// The resolved parameters the renderer draws. Required.
    let parameters: FaceParameters

    /// The render size. Defaults to 96×96 — small enough for an
    /// inline footer chip, large enough to read the brow
    /// calligraphy. Callers that need a bigger render (host config,
    /// mascot deep-dive) pass their own value.
    var size: CGFloat = 96

    init(parameters: FaceParameters, size: CGFloat = 96) {
        self.parameters = parameters
        self.size = size
    }

    // Locked base geometry (220×220 space).
    private static let canvasSize: CGFloat = 220
    private static let circleCentre: CGPoint = .init(x: 110, y: 110)
    private static let circleRadius: CGFloat = 100
    private static let leftEyeCentre: CGPoint = .init(x: 76, y: 96)
    private static let rightEyeCentre: CGPoint = .init(x: 144, y: 96)
    private static let mouthY: CGFloat = 142

    // Skin colours — match the JS reference's palette.
    private static let amberColour = Color(red: 0xF2/255.0, green: 0xA9/255.0, blue: 0x3B/255.0)
    private static let inkColour   = Color(red: 0x2A/255.0, green: 0x21/255.0, blue: 0x18/255.0)
    private static let blushColour = Color(red: 0xE8/255.0, green: 0x60/255.0, blue: 0x4C/255.0)
    private static let sweatColour = Color(red: 0x4A/255.0, green: 0x90/255.0, blue: 0xD3/255.0)

    var body: some View {
        Canvas { context, _ in
            context.scaleBy(
                x: size / Self.canvasSize,
                y: size / Self.canvasSize
            )
            drawFace(context: &context)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityLabel))
    }

    // MARK: - Drawing

    private func drawFace(context: inout GraphicsContext) {
        let p = parameters
        let P = p.personalitySpec
        let I = p.ideologySpec

        // ---- head + personality tilt ----
        let headPath = Path(ellipseIn: CGRect(
            x: Self.circleCentre.x - Self.circleRadius,
            y: Self.circleCentre.y - Self.circleRadius,
            width: Self.circleRadius * 2,
            height: Self.circleRadius * 2
        ))
        if P.headTilt != 0 {
            var rotated = context
            rotated.translateBy(x: Self.circleCentre.x, y: Self.circleCentre.y)
            rotated.rotate(by: .degrees(P.headTilt))
            rotated.translateBy(x: -Self.circleCentre.x, y: -Self.circleCentre.y)
            rotated.fill(headPath, with: .color(Self.amberColour))
        } else {
            context.fill(headPath, with: .color(Self.amberColour))
        }

        // ---- ideology marks (drawn behind brows/eyes so they sit on
        //      the skin, not over the brow stroke) ----
        drawMarks(context: &context)

        // ---- brows (ideology) ----
        if I.brows.opacity > 0.01 {
            drawBrows(context: &context)
        }

        // ---- eyes (personality + ideology overlay) ----
        drawEyes(context: &context)

        // ---- ideology eye overlay ----
        if let overlay = I.eyeOverlay {
            drawEyeOverlay(context: &context, overlay: overlay)
        }

        // ---- blush (personality) ----
        if P.blush > 0 {
            drawBlush(context: &context)
        }

        // ---- mouth (personality, with emotion override) ----
        drawMouth(context: &context)
    }

    // MARK: Eyes

    private func drawEyes(context: inout GraphicsContext) {
        let p = parameters
        let P = p.personalitySpec
        let left  = CGPoint(x: Self.leftEyeCentre.x + p.emotion.eyeDx, y: p.eyeY)
        let right = CGPoint(x: Self.rightEyeCentre.x + p.emotion.eyeDx, y: p.eyeY)
        let r = p.pupilRadius
        let ink = Self.inkColour

        switch P.eyes.shape {
        case .dot, .lid:
            // Filled pupil disc.
            context.fill(
                Path(ellipseIn: circleRect(centre: left, radius: r)),
                with: .color(ink)
            )
            context.fill(
                Path(ellipseIn: circleRect(centre: right, radius: r)),
                with: .color(ink)
            )
            if P.eyes.shape == .lid {
                // Composed half-lid — a flat stroke above the pupil.
                // JS: lidY = eyeY - r * (1 - lid)
                let lidY = p.eyeY - r * (1 - P.eyes.lid)
                var lidLeft = Path()
                lidLeft.move(to: CGPoint(x: left.x - 9, y: lidY))
                lidLeft.addLine(to: CGPoint(x: left.x + 9, y: lidY))
                context.stroke(
                    lidLeft,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                var lidRight = Path()
                lidRight.move(to: CGPoint(x: right.x - 9, y: lidY))
                lidRight.addLine(to: CGPoint(x: right.x + 9, y: lidY))
                context.stroke(
                    lidRight,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
            }

        case .squint:
            // Horizontal slits.
            var leftSlit = Path()
            leftSlit.move(to: CGPoint(x: left.x - 8, y: p.eyeY))
            leftSlit.addLine(to: CGPoint(x: left.x + 8, y: p.eyeY))
            context.stroke(
                leftSlit,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )
            var rightSlit = Path()
            rightSlit.move(to: CGPoint(x: right.x - 8, y: p.eyeY))
            rightSlit.addLine(to: CGPoint(x: right.x + 8, y: p.eyeY))
            context.stroke(
                rightSlit,
                with: .color(ink),
                style: StrokeStyle(lineWidth: 6, lineCap: .round)
            )

        case .ring:
            // Wide ring + big pupil.
            context.stroke(
                Path(ellipseIn: circleRect(centre: left, radius: 11)),
                with: .color(ink),
                style: StrokeStyle(lineWidth: 4)
            )
            context.stroke(
                Path(ellipseIn: circleRect(centre: right, radius: 11)),
                with: .color(ink),
                style: StrokeStyle(lineWidth: 4)
            )
            context.fill(
                Path(ellipseIn: circleRect(centre: left, radius: r * 0.75)),
                with: .color(ink)
            )
            context.fill(
                Path(ellipseIn: circleRect(centre: right, radius: r * 0.75)),
                with: .color(ink)
            )
        }
    }

    // MARK: Brows

    private func drawBrows(context: inout GraphicsContext) {
        let p = parameters
        let I = p.ideologySpec
        let ink = Self.inkColour

        // V0.94 B — at avatar sizes (`size < MascotFaceEngine.
        // avatarSizeThreshold`) widen the brow curve deltas by the
        // engine's pinned factor (see `MascotFaceEngine.
        // browCurveAvatarScale`). The renderer asks the engine per
        // call; no branching here. Multiplied against the `curve /
        // inner / outer` deltas — the brow `weight` is unaffected
        // (line thickness reads independently of the curve
        // amplitude at avatar sizes).
        let s = MascotFaceEngine.browCurveScale(forRenderSize: size)

        let oX: CGFloat = 58
        let iX: CGFloat = 90
        let iy = p.browY - I.brows.inner * s
        let oy = p.browY - I.brows.outer * s
        let cY = (iy + oy) / 2 - I.brows.curve * s
        let w = I.brows.weight

        // Left brow (mirror to right by reflecting x around 110).
        let leftPath = browPath(
            family: I.brows.family,
            outerPoint: CGPoint(x: oX, y: oy),
            innerPoint: CGPoint(x: iX, y: iy),
            curveY: cY,
            thickness: w
        )
        let rightPath = browPath(
            family: I.brows.family,
            outerPoint: CGPoint(x: Self.canvasSize - oX, y: oy),
            innerPoint: CGPoint(x: Self.canvasSize - iX, y: iy),
            curveY: cY,
            thickness: w
        )

        // Stroke each side with its own per-brow tilt, then union the
        // two paths so the opacity application (a colour-level alpha)
        // covers both sides uniformly. `GraphicsContext` does not
        // expose a group `opacity` setter, so we build one combined
        // path and stroke it once with the ink at the spec opacity.
        var leftContext = context
        leftContext.translateBy(x: 74, y: p.browY)
        leftContext.rotate(by: .degrees(-I.brows.tilt))
        leftContext.translateBy(x: -74, y: -p.browY)
        leftContext.stroke(
            leftPath,
            with: .color(ink),
            style: StrokeStyle(lineWidth: w, lineCap: .round)
        )

        var rightContext = context
        rightContext.translateBy(x: 146, y: p.browY)
        rightContext.rotate(by: .degrees(I.brows.tilt))
        rightContext.translateBy(x: -146, y: -p.browY)
        rightContext.stroke(
            rightPath,
            with: .color(ink),
            style: StrokeStyle(lineWidth: w, lineCap: .round)
        )

        // If the spec opacity < 1, re-stroke both sides under a
        // faded ink colour. This double-strokes once when opacity is
        // 1.0 (no visible difference) and once when < 1 (overwrites
        // the previous full-opacity stroke with the faded copy).
        if I.brows.opacity < 1 {
            var fadedLeft = context
            fadedLeft.translateBy(x: 74, y: p.browY)
            fadedLeft.rotate(by: .degrees(-I.brows.tilt))
            fadedLeft.translateBy(x: -74, y: -p.browY)
            fadedLeft.stroke(
                leftPath,
                with: .color(ink.opacity(I.brows.opacity)),
                style: StrokeStyle(lineWidth: w, lineCap: .round)
            )

            var fadedRight = context
            fadedRight.translateBy(x: 146, y: p.browY)
            fadedRight.rotate(by: .degrees(I.brows.tilt))
            fadedRight.translateBy(x: -146, y: -p.browY)
            fadedRight.stroke(
                rightPath,
                with: .color(ink.opacity(I.brows.opacity)),
                style: StrokeStyle(lineWidth: w, lineCap: .round)
            )
        }
    }

    /// Build the brow path for one side, honouring the `family` curve style.
    private func browPath(
        family: BrowFamily,
        outerPoint: CGPoint,
        innerPoint: CGPoint,
        curveY: CGFloat,
        thickness: CGFloat
    ) -> Path {
        var path = Path()
        switch family {
        case .soft, .crisp:
            // Quadratic curve from outer → inner through the apex.
            let midX = (outerPoint.x + innerPoint.x) / 2
            path.move(to: outerPoint)
            path.addQuadCurve(to: innerPoint, control: CGPoint(x: midX, y: curveY))
        case .slash:
            // Sharpen: less rounding, higher contrast — straight line.
            path.move(to: CGPoint(x: outerPoint.x, y: outerPoint.y - 2))
            path.addLine(to: innerPoint)
        case .arch:
            // High circus arch — pull the apex up an extra 4pt.
            let midX = (outerPoint.x + innerPoint.x) / 2
            path.move(to: CGPoint(x: outerPoint.x + 2, y: outerPoint.y))
            path.addQuadCurve(
                to: CGPoint(x: innerPoint.x - 2, y: innerPoint.y),
                control: CGPoint(x: midX, y: curveY - 4)
            )
        case .flag:
            // Bold rise, squared start — vertical tick from (oX, oy+2) to
            // (oX, oy), then a quadratic into the inner end.
            path.move(to: CGPoint(x: outerPoint.x, y: outerPoint.y + 2))
            path.addLine(to: outerPoint)
            let midX = (outerPoint.x + innerPoint.x) / 2
            path.addQuadCurve(to: innerPoint, control: CGPoint(x: midX, y: curveY))
        }
        return path
    }

    // MARK: Mouth

    private func drawMouth(context: inout GraphicsContext) {
        let p = parameters
        let P = p.personalitySpec
        let ink = Self.inkColour

        let mY = Self.mouthY
        let amp = min(1.9, p.emotion.intensity * P.mouth.amp)
        let w = P.mouth.width
        let half = p.mouthHalfWidth
        let x0 = 110 - half
        let x1 = 110 + half

        // Apply the optional emotion override (`.alert` → tiny "o").
        let family = p.emotion.mouthFamilyOverride ?? P.mouth.family

        var path = Path()
        switch family {
        case .line:
            path.move(to: CGPoint(x: x0, y: mY))
            path.addLine(to: CGPoint(x: x1, y: mY))
        case .smile:
            // JS: M(x0-2*amp, mY) Q 110 (mY + 11*amp) (x1+2*amp, mY)
            let d = 11 * amp
            path.move(to: CGPoint(x: x0 - 2 * amp, y: mY))
            path.addQuadCurve(
                to: CGPoint(x: x1 + 2 * amp, y: mY),
                control: CGPoint(x: 110, y: mY + d)
            )
        case .smirk:
            // JS: M(x0, mY) Q 110 (mY - lift*0.35) (x1, mY - lift)
            let lift = 15 * amp
            path.move(to: CGPoint(x: x0, y: mY))
            path.addQuadCurve(
                to: CGPoint(x: x1, y: mY - lift),
                control: CGPoint(x: 110, y: mY - lift * 0.35)
            )
        case .flatTilt:
            // JS: line from (x0+2, mY) to (x1-2, mY), thinner (6.5 vs 7).
            path.move(to: CGPoint(x: x0 + 2, y: mY))
            path.addLine(to: CGPoint(x: x1 - 2, y: mY))
        case .open:
            // Filled "o" / shouting shape. JS closes with Z and
            // fills with the ink colour.
            let d = 16 * amp
            path.move(to: CGPoint(x: x0 - 3 * amp, y: mY - 4))
            path.addQuadCurve(
                to: CGPoint(x: x1 + 3 * amp, y: mY - 4),
                control: CGPoint(x: 110, y: mY + d)
            )
            path.closeSubpath()
        }

        // Apply personality mouth tilt by rotating around (110, mY).
        if P.mouth.tilt != 0 {
            var rotated = context
            rotated.translateBy(x: 110, y: mY)
            rotated.rotate(by: .degrees(P.mouth.tilt))
            rotated.translateBy(x: -110, y: -mY)
            switch family {
            case .open:
                rotated.fill(path, with: .color(ink))
                rotated.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 5, lineJoin: .round)
                )
            default:
                rotated.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: family == .flatTilt ? 6.5 : 7, lineCap: .round)
                )
            }
        } else {
            switch family {
            case .open:
                context.fill(path, with: .color(ink))
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 5, lineJoin: .round)
                )
            default:
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: family == .flatTilt ? 6.5 : 7, lineCap: .round)
                )
            }
        }
    }

    // MARK: Blush

    private func drawBlush(context: inout GraphicsContext) {
        let p = parameters
        let P = p.personalitySpec
        let opacity = 0.35 * P.blush + 0.15
        let left  = CGPoint(x: Self.leftEyeCentre.x - 14, y: p.eyeY + 26)
        let right = CGPoint(x: Self.rightEyeCentre.x + 14, y: p.eyeY + 26)
        context.fill(
            Path(ellipseIn: CGRect(x: left.x - 10, y: left.y - 5.5, width: 20, height: 11)),
            with: .color(Self.blushColour.opacity(opacity))
        )
        context.fill(
            Path(ellipseIn: CGRect(x: right.x - 10, y: right.y - 5.5, width: 20, height: 11)),
            with: .color(Self.blushColour.opacity(opacity))
        )
    }

    // MARK: Eye overlays

    private func drawEyeOverlay(context: inout GraphicsContext, overlay: EyeOverlay) {
        let p = parameters
        let left  = CGPoint(x: Self.leftEyeCentre.x + p.emotion.eyeDx, y: p.eyeY)
        let right = CGPoint(x: Self.rightEyeCentre.x + p.emotion.eyeDx, y: p.eyeY)
        let ink = Self.inkColour

        switch overlay {
        case .lidLine:
            // Crisp upper-lid stroke = composure.
            for centre in [left, right] {
                var path = Path()
                path.move(to: CGPoint(x: centre.x - 11, y: centre.y - 10))
                path.addQuadCurve(
                    to: CGPoint(x: centre.x + 11, y: centre.y - 10),
                    control: CGPoint(x: centre.x, y: centre.y - 15)
                )
                context.stroke(
                    path,
                    with: .color(ink),
                    style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                )
            }
        case .glint:
            // Offset glint dot — mischief. JS renders two asymmetric dots.
            context.fill(
                Path(ellipseIn: circleRect(centre: CGPoint(x: left.x + 4, y: left.y - 4), radius: 2)),
                with: .color(ink.opacity(0.85))
            )
            context.fill(
                Path(ellipseIn: circleRect(centre: CGPoint(x: right.x - 4, y: right.y - 5), radius: 1.6)),
                with: .color(ink.opacity(0.6))
            )
        case .monocle:
            // A single crisp ring over the right eye + a stem to (200, mY+22).
            context.stroke(
                Path(ellipseIn: circleRect(centre: right, radius: 16)),
                with: .color(ink),
                style: StrokeStyle(lineWidth: 3.5)
            )
            var stem = Path()
            stem.move(to: CGPoint(x: right.x + 11, y: right.y + 11))
            stem.addLine(to: CGPoint(x: right.x + 20, y: right.y + 22))
            context.stroke(stem, with: .color(ink), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        case .lidShadow:
            // Heavy under-eye shadow = scowl.
            for centre in [left, right] {
                var path = Path()
                path.move(to: CGPoint(x: centre.x - 10, y: centre.y + 7))
                path.addQuadCurve(
                    to: CGPoint(x: centre.x + 10, y: centre.y + 7),
                    control: CGPoint(x: centre.x, y: centre.y + 13)
                )
                context.stroke(
                    path,
                    with: .color(ink.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
            }
        case .ringShadow:
            // Shadowed under-eyes.
            for centre in [left, right] {
                context.stroke(
                    Path(ellipseIn: circleRect(centre: CGPoint(x: centre.x, y: centre.y + 1), radius: 12.5)),
                    with: .color(ink.opacity(0.5)),
                    style: StrokeStyle(lineWidth: 2.5)
                )
            }
        }
    }

    // MARK: Marks

    private func drawMarks(context: inout GraphicsContext) {
        let ink = Self.inkColour
        for mark in parameters.ideologySpec.marks {
            switch mark {
            case .stitch:
                // Diagonal stitch scar on the upper-right of the head.
                var path = Path()
                path.move(to: CGPoint(x: 156, y: 52))
                path.addLine(to: CGPoint(x: 168, y: 44))
                path.move(to: CGPoint(x: 160, y: 54))
                path.addLine(to: CGPoint(x: 172, y: 46))
                context.stroke(
                    path,
                    with: .color(ink.opacity(0.8)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
            case .sweat:
                // Blue tear-drop on the upper-right.
                var path = Path()
                path.move(to: CGPoint(x: 178, y: 46))
                path.addQuadCurve(
                    to: CGPoint(x: 178, y: 59),
                    control: CGPoint(x: 184, y: 55)
                )
                path.addQuadCurve(
                    to: CGPoint(x: 178, y: 46),
                    control: CGPoint(x: 172, y: 51)
                )
                context.fill(path, with: .color(Self.sweatColour.opacity(0.9)))
            case .sparkle:
                // Four-pointed star on the upper-left.
                let cx: CGFloat = 40
                let cy: CGFloat = 46
                var path = Path()
                path.move(to: CGPoint(x: cx, y: cy - 9))
                path.addLine(to: CGPoint(x: cx + 3, y: cy - 3))
                path.addLine(to: CGPoint(x: cx + 9, y: cy))
                path.addLine(to: CGPoint(x: cx + 3, y: cy + 3))
                path.addLine(to: CGPoint(x: cx, y: cy + 9))
                path.addLine(to: CGPoint(x: cx - 3, y: cy + 3))
                path.addLine(to: CGPoint(x: cx - 9, y: cy))
                path.addLine(to: CGPoint(x: cx - 3, y: cy - 3))
                path.closeSubpath()
                context.fill(path, with: .color(ink.opacity(0.5)))
            }
        }
    }

    // MARK: A11y

    private var accessibilityLabel: String {
        let emotionName = parameters.emotion.emotion.rawValue
        return "\(parameters.personality.displayName) mascot, \(parameters.ideology.displayName) ideology, \(emotionName)"
    }

    // MARK: Helpers

    private func circleRect(centre: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(
            x: centre.x - radius,
            y: centre.y - radius,
            width: radius * 2,
            height: radius * 2
        )
    }
}

#if DEBUG
#Preview("Hero combos") {
    HStack(spacing: 16) {
        MascotFaceView(parameters: MascotFaceEngine.compute(
            personality: .unhinged, ideology: .anarchist, state: .controversy
        ))
        MascotFaceView(parameters: MascotFaceEngine.compute(
            personality: .professional, ideology: .apolitical, state: .idle
        ))
        MascotFaceView(parameters: MascotFaceEngine.compute(
            personality: .friendly, ideology: .communist, state: .comeback
        ))
        MascotFaceView(parameters: MascotFaceEngine.compute(
            personality: .snarky, ideology: .trickster, state: .blowout
        ))
        MascotFaceView(parameters: MascotFaceEngine.compute(
            personality: .sarcastic, ideology: .conservative, state: .streak
        ))
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}

#Preview("Avatar size — brow widened x1.3") {
    // V0.94 B — at avatar sizes the brow calligraphy widens. The
    // first preview chip is the 36pt footer size; the renderer
    // applies the engine's pinned factor automatically.
    HStack(spacing: 16) {
        MascotFaceView(
            parameters: MascotFaceEngine.compute(
                personality: .unhinged,
                ideology: .anarchist,
                state: .controversy
            ),
            size: 36
        )
        MascotFaceView(
            parameters: MascotFaceEngine.compute(
                personality: .friendly,
                ideology: .communist,
                state: .comeback
            ),
            size: 40
        )
        MascotFaceView(
            parameters: MascotFaceEngine.compute(
                personality: .snarky,
                ideology: .trickster,
                state: .blowout
            ),
            size: 64
        )
    }
    .padding()
    .background(Theme.Palette.background)
    .preferredColorScheme(.dark)
}
#endif
