//
//  CAHCardScanSheet.swift
//  GamesRoom
//
//  V0.34 — member-facing card-counting surface for Cards Against
//  Humanity. Models the chip-scan flow from `ChipScanSheet.swift`
//  but simpler: the camera + detector count black cards the member
//  has won, the member confirms / adjusts the total, and the
//  tally is recorded via `ScoringService.recordCAHTally(...)`.
//
//  Trust model
//  -----------
//  The CAH pack is `count_based`: the score is the COUNT of black
//  cards the member holds at session end. The vision detector is
//  reused from the casino surface (`ChipSegmentationDetector` with
//  `pxPerUnit: 2` — cards are thinner than chips). The detector's
//  count is a rough estimate (MAE on chips is ~6 — cards will be
//  similar); the editable total stepper is the user-attestation
//  fallback, identical to the casino scan flow. The vision scan
//  is assistant, not authority.
//
//  Privacy posture
//  ---------------
//  CAH scan is discard-only: the JPEG is hashed (SHA-256) and
//  the bytes are dropped. No opt-in photo retention (T1.2's
//  `keepScanPhotos` toggle is intentionally not exposed for CAH).
//  The hash + a `VisionSnapshot` summary travel to the server so
//  a disputed tally can be matched to its capture frame.
//

import SwiftUI
import AVFoundation
import CoreImage

struct CAHCardScanSheet: View {

    let eventId: UUID
    let roomId: UUID
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var scoringService: ScoringService
    @EnvironmentObject private var authService: AuthService

    @State private var totalCards: Int = 0
    @State private var confidenceAvg: Double = 0
    @State private var photoHash: String?
    @State private var isScanning: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var showConfirm: Bool = false
    @State private var lowConfidencePrompt: Bool = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                if showConfirm {
                    confirmView
                } else {
                    cameraView
                }
            }
            .navigationTitle(showConfirm ? "Your cards" : "Scan your cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
            }
        }
        .tint(Theme.Palette.accent)
    }

    // MARK: - Camera

    private var cameraView: some View {
        VStack(spacing: 16) {
            ScanCameraPreview(isScanning: $isScanning) { pixelBuffer in
                Task { await processFrame(pixelBuffer: pixelBuffer) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, Theme.Layout.gutter)
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Text("Point at your stack of black cards")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Hold steady. The vision count is a starting point — confirm before recording.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

                if isScanning {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Counting cards…")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                } else if lowConfidencePrompt {
                    Text("Low confidence — move closer, improve lighting, and try again.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    Button {
                        lowConfidencePrompt = false
                        showConfirm = true
                    } label: {
                        Text("Review result anyway")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                } else {
                    Text("Tap shutter to scan")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Confirm

    private var confirmView: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your cards: \(totalCards)")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.primaryText)
                HStack(spacing: 8) {
                    Text("Confidence: \(Int(confidenceAvg * 100))%")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    Text("·")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                    Text("On-device")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                Text("Adjust the count if it doesn't look right. The tally replaces any per-round entries for this event.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()
                .background(Theme.Palette.hairline)
                .padding(.horizontal, Theme.Layout.gutter)

            VStack(spacing: 12) {
                Stepper(value: $totalCards, in: 1...100) {
                    HStack {
                        Text("Total cards")
                            .font(Theme.Typography.body.weight(.medium))
                            .foregroundStyle(Theme.Palette.primaryText)
                        Spacer()
                        Text("\(totalCards)")
                            .font(Theme.Typography.title.monospacedDigit())
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                .padding(.horizontal, Theme.Layout.gutter)
                .padding(.vertical, 16)
            }

            Divider()
                .background(Theme.Palette.hairline)
                .padding(.horizontal, Theme.Layout.gutter)

            VStack(spacing: 8) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }

                Button(action: { Task { await confirm() } }) {
                    Text(isSubmitting ? "Recording…" : "Looks right — record \(totalCards) cards")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isSubmitting)

                Button {
                    totalCards = 0
                    confidenceAvg = 0
                    photoHash = nil
                    showConfirm = false
                    errorMessage = nil
                    lowConfidencePrompt = false
                } label: {
                    Text("Re-scan")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Async

    private func processFrame(pixelBuffer: CVPixelBuffer) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        guard let cg = cgImage(from: pixelBuffer) else {
            errorMessage = "Couldn't read the camera frame. Try again."
            return
        }

        // Discard-only: hash the JPEG and drop the bytes. No
        // opt-in photo retention for CAH (per privacy posture).
        let jpeg = jpegData(from: pixelBuffer)
        let hash = jpeg.map { PhotoHash.sha256($0) }

        // Cards are thinner than chips — `pxPerUnit: 2` so the
        // height-based count estimate lands in the right range.
        // The detector's known-weak count metric is the editable
        // stepper's value below; this is the user-attestation
        // fallback.
        let stacks = ChipSegmentationDetector(pxPerUnit: 2).detect(cg: cg)
        let total = stacks.reduce(0) { $0 + $1.count }
        let avg = stacks.isEmpty
            ? 0
            : stacks.map(\.confidence).reduce(0, +) / Double(stacks.count)
        guard !stacks.isEmpty else {
            errorMessage = "No card stacks found. Move closer, improve lighting, and try again."
            return
        }

        totalCards = total
        confidenceAvg = avg
        photoHash = hash
        if ScanConfidenceGate.shouldPromptRescan(confidenceAvg: confidenceAvg) {
            lowConfidencePrompt = true
            return
        }
        showConfirm = true
    }

    private func confirm() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        // No chip-color / points math here — the total IS the
        // card count. The `VisionSnapshot` is shipped with
        // `discarded: false` and the SHA-256 hash so the
        // server-side ledger can match a disputed tally back to
        // its capture frame.
        let snapshot = VisionSnapshot(
            stacks: [],
            totalValue: totalCards,
            confidenceAvg: confidenceAvg,
            discarded: false,
            photoHash: photoHash
        )

        do {
            _ = try await scoringService.recordCAHTally(
                eventId: eventId,
                cardCount: Int64(totalCards),
                visionSnapshot: snapshot
            )
            onDone()
            dismiss()
        } catch {
            errorMessage = "Failed to record tally: \((error as NSError).localizedDescription)"
        }
    }

    // MARK: - Pixel conversion

    private func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        return context.createCGImage(ciImage, from: ciImage.extent)
    }

    private func jpegData(from pixelBuffer: CVPixelBuffer) -> Data? {
        guard let cg = cgImage(from: pixelBuffer) else { return nil }
        let uiImage = UIImage(cgImage: cg)
        return uiImage.jpegData(compressionQuality: 0.8)
    }
}
