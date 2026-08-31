//
//  MascotFaceEngine.swift
//  GamesRoom
//
//  V0.94 — Tally mascot face renderer (slice A).
//
//  Face parameters are a PURE function of
//  (MascotPersonality, MascotPoliticalIdeology, RoomState). No hidden
//  state. No randomness. The renderer (`MascotFaceView`) is a thin
//  vector consumer of the `FaceParameters` returned from here.
//
//  Reference implementation: ~/Documents/games-room/tally-face/sketches/
//  007-deep-character/index.html — the JS in that file IS the spec;
//  every numeric parameter below is ported from that file verbatim.
//
//  Hard invariants (V0.94 spec):
//    1. Async surfaces only — never in-play/active-game views.
//    2. Voice and face agree: RoomState is derived from the same
//       resolution `MascotEngine.footerKind(activeEvent:leaderboard:
//       now:…)` uses (see `resolveRoomState(_:)` below — comment
//       names the flavour source).
//    3. 220×220 locked geometry — every numeric parameter below is
//       in that space; `MascotFaceView` scales to render size.
//
//  Six personality mouth families are referenced in the spec table
//  (line / smile / smirk / flat-tilt / open); `flat-tilt` is the
//  fourth family after `smile` and `smirk`. Note that the table also
//  describes a "tiny o" / "squiggle" mouth shape in the prose —
//  those are reserved for future RoomState emotion modifiers and are
//  not emitted by any personality today. The renderer therefore
//  handles only the five families listed in the table.
//
//  `MascotFaceEngine.swift` is Foundation-only so it can be compiled
//  and unit-tested by the no-Xcode Foundation runner
//  (`./build-and-run-tests.sh`). SwiftUI lives in `MascotFaceView.swift`.
//

import Foundation
import CoreGraphics

// MARK: - Room state

/// The resolved room state the face renders against. Mirrors the
/// six flavours `MascotEngine.footerKind(activeEvent:leaderboard:
/// now:…)` distinguishes (idle / playing / blowout / comeback /
/// streak / controversy). Voice and face MUST agree — same
/// resolution, one mapping, in this file (V0.94 spec, item 4).
enum RoomState: String, Codable, CaseIterable, Hashable {
    case idle
    case playing
    case blowout
    case comeback
    case streak
    case controversy
}

// MARK: - RoomState resolution

/// Flat input record the view fills from the live data plane before
/// resolving to a `RoomState`. Each field mirrors one of the nine
/// `MascotEngine.footerKind` resolution branches — see
/// `MascotEngine.footerKind` in `Services/MascotEngine.swift:261`.
/// Keeping the inputs flat + value-typed means the engine stays
/// pure and testable; the view does the bridging.
struct RoomStateInputs {
    /// The currently-active event. `nil` ⇒ no event scheduled.
    let activeEvent: ActiveEventSnapshot?
    /// Whether the active event has settled (post-play window).
    let activeEventSettled: Bool
    /// Whether the host has finalised the live event (settle in progress).
    let hostFinalized: Bool
    /// Caller's withdrawn chip count for the active event.
    let withdrawnAmount: Int
    /// The leader's margin over second place (positive = leader ahead).
    /// Zero or positive only; the engine only reads "is this large?".
    let leaderMargin: Int
    /// Whether the most-recent round flipped the leaderboard leader
    /// (relative to the previous round).
    let lastRoundFlippedLeader: Bool
    /// The number of consecutive wins at the table by the current
    /// leader — `streak` flavour fires at ≥ 3.
    let consecutiveWins: Int
    /// Whether an open dispute / ruling is pending.
    let openDispute: Bool
    /// Days since the last session was played. `nil` ⇒ never played.
    let lastSessionDaysAgo: Int?

    /// Lightweight projection of the active event — just enough to
    /// drive the state machine. The view translates its `Event` /
    /// `LeaderboardEntry` payloads into one of these.
    struct ActiveEventSnapshot {
        let playedAt: Date
        let settledAt: Date?
    }

    /// Resolves the inputs to a `RoomState`. Order mirrors
    /// `MascotEngine.footerKind` (first match wins — see
    /// `MascotEngine.swift:261-287` for the canonical resolver):
    ///
    ///   1. `openDispute` → `.controversy`
    ///   2. `lastRoundFlippedLeader` (active event live) → `.comeback`
    ///   3. `activeEvent != nil`, live, `withdrawnAmount > 0` → `.playing`
    ///   4. `activeEvent != nil`, live, `withdrawnAmount == 0` → `.playing`
    ///   5. `leaderMargin >= 30` (heuristic for "blowout") → `.blowout`
    ///   6. `consecutiveWins >= 3` → `.streak`
    ///   7. Otherwise → `.idle`
    ///
    /// Falls back to `.idle` when data is missing — matching the
    /// spec's "where data is missing, fall back to idle" rule.
    ///
    /// The room-state flavour is the SAME one the voice uses (the
    /// five-or-six mascot footer flavours in `MascotEngine.swift`).
    /// The mapping `RoomState → footer flavour` is intentionally
    /// collapsed: voice + face agree on the visible state.
    static func resolve(_ inputs: RoomStateInputs, now: Date = Date()) -> RoomState {
        if inputs.openDispute { return .controversy }
        if inputs.activeEvent != nil, inputs.lastRoundFlippedLeader { return .comeback }
        if inputs.activeEvent != nil,
           inputs.activeEventSettled == false {
            return .playing
        }
        // Pre-active or post-active windows without a comeback:
        // blowout if the leader has run away with it, streak if the
        // leader has won three in a row, otherwise idle.
        if inputs.leaderMargin >= 30 { return .blowout }
        if inputs.consecutiveWins >= 3 { return .streak }
        return .idle
    }
}

// MARK: - Mouth family

/// One of the five personality mouth families. Mirrors the
/// `MouthFamily` strings in the JS reference (`line`, `smile`,
/// `smirk`, `flat-tilt`, `open`). Codable for unit-test fixtures.
enum MouthFamily: String, Codable, Hashable {
    case line
    case smile
    case smirk
    case flatTilt = "flat-tilt"
    case open
}

// MARK: - Face spec — personality

/// Personality-level face spec: mouth family, eye shape, pupil scale,
/// blush intensity, head tilt. Mirrors the PERSONALITY table in the
/// V0.94 spec, ported verbatim from the JS reference. Codable so
/// the unit tests can introspect the resolved `FaceParameters` and
/// confirm personality-pairwise mouth distinctness.
struct PersonalityFaceSpec: Equatable {
    let mouth: MouthSpec
    let eyes: EyeSpec
    let blush: Double
    let headTilt: Double
}

struct MouthSpec: Equatable {
    let family: MouthFamily
    let width: Double
    let tilt: Double
    let amp: Double
}

struct EyeSpec: Equatable {
    let shape: EyeShape
    let lid: Double
    let pupil: Double
}

enum EyeShape: String, Codable, Hashable {
    case dot
    case lid
    case squint
    case ring
}

// MARK: - Face spec — ideology

/// Ideology-level face spec: brow family + curve / inner / outer /
/// opacity / tilt / weight, eye overlay, marks. Mirrors the
/// IDEOLOGY table in the V0.94 spec, ported verbatim from the JS
/// reference.
struct IdeologyFaceSpec: Equatable {
    let brows: BrowSpec
    let eyeOverlay: EyeOverlay?
    let marks: [IdeologyMark]
}

struct BrowSpec: Equatable {
    let family: BrowFamily
    let curve: Double
    let inner: Double
    let outer: Double
    let opacity: Double
    let tilt: Double
    let weight: Double
}

enum BrowFamily: String, Codable, Hashable {
    case crisp
    case soft
    case arch
    case slash
    case flag
}

enum EyeOverlay: String, Codable, Hashable {
    case lidLine = "lid-line"
    case glint
    case monocle
    case lidShadow = "lid-shadow"
    case ringShadow = "ring-shadow"
}

enum IdeologyMark: String, Codable, Hashable {
    case stitch
    case sweat
    case sparkle
}

// MARK: - Emotion modifier

/// Emotion modifier layered on top of (personality, ideology) per
/// the V0.94 spec. Driven by RoomState via `emotionFor(state:)`.
/// Each modifier has a small handful of pixel-level knobs that the
/// renderer applies on top of the base face spec.
struct EmotionModifier: Equatable {
    /// The emotion label.
    let emotion: Emotion
    /// Intensity 0…1 — used to scale mouth amplitude in the renderer.
    let intensity: Double
    /// Vertical shift of the eye row (positive = down). Spec:
    /// focused −2, alert −3, smug −1, delight +1, neutral 0.
    let eyeDy: Double
    /// Horizontal shift of the eyes (positive = right). Spec:
    /// smug +4 (sidelong look), others 0.
    let eyeDx: Double
    /// Brow-raise in points — applied as a vertical shift to the
    /// brow row. Spec: neutral 0, focused 1.5, smug 2, delight 3,
    /// alert 1.
    let browRaise: Double
    /// Mouth-width multiplier (1.0 = base width). Spec: focused 0.9.
    let mouthWidthScale: Double
    /// Mouth family override — used by `.alert` to render a small
    /// "o" mouth (`.open` with low amplitude is the reference
    /// implementation's stand-in; the spec's prose calls this the
    /// "tiny o" mouth). `nil` ⇒ keep the personality mouth family.
    let mouthFamilyOverride: MouthFamily?
}

enum Emotion: String, Codable, Hashable {
    case neutral
    case focused
    case smug
    case delight
    case alert
}

// MARK: - Resolved face parameters

/// The renderer input — what `MascotFaceView` consumes. Built by
/// `MascotFaceEngine.compute(personality:ideology:state:)` from the
/// personality + ideology specs and the RoomState-driven emotion
/// modifier.
struct FaceParameters: Equatable {
    let personality: MascotPersonality
    let ideology: MascotPoliticalIdeology
    let state: RoomState
    let personalitySpec: PersonalityFaceSpec
    let ideologySpec: IdeologyFaceSpec
    let emotion: EmotionModifier

    /// Eye-row Y coordinate (220×220 space). Spec: base 96,
    /// shifted by emotion eyeDy.
    var eyeY: Double { 96 + emotion.eyeDy }

    /// Brow-row Y coordinate (220×220 space). Spec: base 72,
    /// shifted upward by emotion browRaise.
    var browY: Double { 72 - emotion.browRaise }

    /// Mouth baseline Y coordinate (220×220 space). Locked.
    var mouthY: Double { 142 }

    /// Effective pupil radius (220×220 space). Base r=9, scaled by
    /// personality pupil spec.
    var pupilRadius: Double { 9 * personalitySpec.eyes.pupil }

    /// Effective mouth width — base 44 (110 ± 22), scaled by
    /// personality width × emotion width scale.
    var mouthHalfWidth: Double {
        22 * personalitySpec.mouth.width * emotion.mouthWidthScale
    }

    /// Effective mouth amplitude — clamped per the JS reference
    /// (`Math.min(1.9, intensity * amp)`).
    var mouthAmplitude: Double {
        min(1.9, emotion.intensity * personalitySpec.mouth.amp)
    }
}

// MARK: - Engine

/// Pure spec function — the single source of truth for face
/// parameters. The renderer is a thin vector consumer of the
/// returned `FaceParameters`; the unit tests assert against the
/// same struct.
///
/// `compute(personality:ideology:state:)` is total over the input
/// domain (every combination returns a valid value). It does no
/// I/O, holds no state, and never throws.
enum MascotFaceEngine {

    /// Resolve `(personality, ideology, state)` to a `FaceParameters`.
    /// Pure, total, deterministic. The entry point the unit tests
    /// hit for the 5 × 11 × 6 = 330-cell matrix sweep.
    static func compute(
        personality: MascotPersonality,
        ideology: MascotPoliticalIdeology,
        state: RoomState
    ) -> FaceParameters {
        let personalitySpec = personalitySpec(for: personality)
        let ideologySpec = ideologySpec(for: ideology)
        let emotion = emotionModifier(for: state)
        return FaceParameters(
            personality: personality,
            ideology: ideology,
            state: state,
            personalitySpec: personalitySpec,
            ideologySpec: ideologySpec,
            emotion: emotion
        )
    }

    // MARK: Personality table (V0.94 spec)

    /// Mirrors the PERSONALITY table in the spec / JS reference.
    /// Values ported verbatim.
    static func personalitySpec(for p: MascotPersonality) -> PersonalityFaceSpec {
        switch p {
        case .professional:
            return PersonalityFaceSpec(
                mouth: MouthSpec(family: .line, width: 0.92, tilt: 0, amp: 0.35),
                eyes: EyeSpec(shape: .lid, lid: 0.35, pupil: 0.85),
                blush: 0,
                headTilt: 0
            )
        case .friendly:
            return PersonalityFaceSpec(
                mouth: MouthSpec(family: .smile, width: 1.1, tilt: 0, amp: 1.15),
                eyes: EyeSpec(shape: .dot, lid: 0, pupil: 1.1),
                blush: 0.5,
                headTilt: 0
            )
        case .snarky:
            return PersonalityFaceSpec(
                mouth: MouthSpec(family: .smirk, width: 1.0, tilt: -5, amp: 0.9),
                eyes: EyeSpec(shape: .dot, lid: 0.2, pupil: 0.95),
                blush: 0,
                headTilt: -3
            )
        case .sarcastic:
            return PersonalityFaceSpec(
                mouth: MouthSpec(family: .flatTilt, width: 0.98, tilt: -8, amp: 0.5),
                eyes: EyeSpec(shape: .squint, lid: 0.55, pupil: 0.8),
                blush: 0,
                headTilt: -5
            )
        case .unhinged:
            return PersonalityFaceSpec(
                mouth: MouthSpec(family: .open, width: 1.22, tilt: -3, amp: 1.6),
                eyes: EyeSpec(shape: .ring, lid: 0, pupil: 1.3),
                blush: 0.35,
                headTilt: 4
            )
        }
    }

    // MARK: Ideology table (V0.94 spec)

    /// Mirrors the IDEOLOGY table in the spec / JS reference.
    /// Values ported verbatim.
    static func ideologySpec(for i: MascotPoliticalIdeology) -> IdeologyFaceSpec {
        switch i {
        case .order:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .crisp, curve: 1.2, inner: -2, outer: 3, opacity: 1.0, tilt: -2, weight: 6.5),
                eyeOverlay: .lidLine,
                marks: []
            )
        case .centrist:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .soft, curve: 0.8, inner: 1, outer: 1, opacity: 0.8, tilt: 0, weight: 5),
                eyeOverlay: nil,
                marks: []
            )
        case .trickster:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .arch, curve: 4.5, inner: 4, outer: 10, opacity: 0.95, tilt: 7, weight: 5.5),
                eyeOverlay: .glint,
                marks: []
            )
        case .anarchist:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .slash, curve: -5, inner: -10, outer: 3, opacity: 1.0, tilt: -8, weight: 7),
                eyeOverlay: nil,
                marks: [.stitch]
            )
        case .apocalypse:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .slash, curve: -8, inner: -13, outer: 6, opacity: 1.0, tilt: -12, weight: 7.5),
                eyeOverlay: .ringShadow,
                marks: [.sweat]
            )
        case .communist:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .flag, curve: 3, inner: 3, outer: 9, opacity: 1.0, tilt: 3, weight: 6),
                eyeOverlay: nil,
                marks: []
            )
        case .conservative:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .crisp, curve: -1, inner: -4, outer: 1, opacity: 1.0, tilt: -4, weight: 6),
                eyeOverlay: .monocle,
                marks: []
            )
        case .liberal:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .soft, curve: 2.6, inner: 2, outer: 7, opacity: 0.85, tilt: 4, weight: 5),
                eyeOverlay: nil,
                marks: [.sparkle]
            )
        case .apolitical:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .soft, curve: 0.4, inner: 0, outer: 0, opacity: 0.4, tilt: 0, weight: 4.5),
                eyeOverlay: nil,
                marks: []
            )
        case .farRight:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .slash, curve: -6, inner: -11, outer: 4, opacity: 1.0, tilt: -10, weight: 7.5),
                eyeOverlay: .lidShadow,
                marks: []
            )
        case .altRight:
            return IdeologyFaceSpec(
                brows: BrowSpec(family: .slash, curve: -7, inner: -12, outer: 5, opacity: 1.0, tilt: -13, weight: 7),
                eyeOverlay: .ringShadow,
                marks: [.sweat]
            )
        }
    }

    // MARK: RoomState → emotion modifier

    /// Maps `RoomState` → `(emotion, intensity)` plus the pixel-level
    /// knobs the renderer applies on top. Ported verbatim from the
    /// STATES table + `emotionBy` / `raiseBy` maps in the JS ref.
    static func emotionModifier(for state: RoomState) -> EmotionModifier {
        switch state {
        case .idle:
            return EmotionModifier(
                emotion: .neutral, intensity: 0.2,
                eyeDy: 0, eyeDx: 0, browRaise: 0,
                mouthWidthScale: 1.0, mouthFamilyOverride: nil
            )
        case .playing:
            return EmotionModifier(
                emotion: .focused, intensity: 0.6,
                eyeDy: -2, eyeDx: 0, browRaise: 1.5,
                mouthWidthScale: 0.9, mouthFamilyOverride: nil
            )
        case .blowout:
            return EmotionModifier(
                emotion: .smug, intensity: 0.8,
                eyeDy: -1, eyeDx: 4, browRaise: 2,
                mouthWidthScale: 1.0, mouthFamilyOverride: nil
            )
        case .comeback:
            return EmotionModifier(
                emotion: .delight, intensity: 1.0,
                eyeDy: 1, eyeDx: 0, browRaise: 3,
                mouthWidthScale: 1.0, mouthFamilyOverride: nil
            )
        case .streak:
            return EmotionModifier(
                emotion: .smug, intensity: 0.6,
                eyeDy: -1, eyeDx: 4, browRaise: 2,
                mouthWidthScale: 1.0, mouthFamilyOverride: nil
            )
        case .controversy:
            return EmotionModifier(
                // Spec calls `.alert` a small "o" mouth — the JS
                // ref uses `.open` with low intensity to approximate
                // it. The renderer applies the override below.
                emotion: .alert, intensity: 0.9,
                eyeDy: -3, eyeDx: 0, browRaise: 1,
                mouthWidthScale: 1.0, mouthFamilyOverride: .open
            )
        }
    }
}
