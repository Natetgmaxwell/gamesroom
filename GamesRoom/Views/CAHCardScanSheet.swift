//
//  CAHCardScanSheet.swift
//  GamesRoom
//
//  V0.34 — member-facing card-counting surface for Cards Against
//  Humanity. V0.72 slice 3 rework: the hosted vision model is the
//  authoritative counter for `minimax_vision` rooms. The member
//  captures a JPEG, the `scan-settle` edge function (slice 2) hashes
//  the bytes, sends them to the MiniMax vision model, and records
//  the count server-side via service role (migration 069 RPCs).
//  The member client never posts a count. The result screen is
//  read-only: count, photo hash tail, attempt position, and the
//  privacy line.
//
//  Re-scan: latest-wins, capped at 5 per event (server-enforced).
//  429 → "Scan limit reached — ask your host to enter the count by
//  hand" (HostManualSettleSheet, migration 070).
//
//  Privacy reversal: V0.72 sends the JPEG to the MiniMax vision
//  API. The bytes never persist server-side (edge function hashes
//  + discards); the hash rides in the response so a disputed count
//  can be matched to its capture frame. The photo is discard-only
//  on our side — no opt-in photo retention (T1.2's
//  `keepScanPhotos` toggle is intentionally not exposed for CAH).
//
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

    // V0.72 — scan-settle circuit. See ChipScanSheet for the same
    // pattern (request timeout 75s; shared SupabaseClientProvider
    // would abort at 15s while the edge fn's 55s call still
    // records).
    @StateObject private var scanSettle = ScanSettleService()

    // V0.71 — owns the AVCaptureSession across the camera ↔ result
    // swap (see ScanCameraView.swift). @StateObject, not @State.
    @StateObject private var camera = ScanCameraController()

    @State private var isUploading: Bool = false
    @State private var result: ScanSettleCardsResult?
    @State private var showResult: Bool = false
    @State private var errorMessage: String?
    @State private var scanError: ScanSettleService.ScanSettleError?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                if showResult, let result {
                    resultView(result: result)
                } else {
                    cameraView
                }
            }
            .navigationTitle(showResult ? "Your cards" : "Scan your cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Palette.primaryText)
                }
            }
        }
        .tint(Theme.Palette.accent)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Camera

    private var cameraView: some View {
        VStack(spacing: 16) {
            ZStack {
                ScanCameraView(controller: camera)
                switch camera.state {
                case .denied, .unavailable:
                    cameraFallbackView
                default:
                    EmptyView()
                }
                if isUploading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.4)
                        Text("Counting cards…")
                            .font(Theme.Typography.body.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, Theme.Layout.gutter)
            .frame(maxHeight: .infinity)

            VStack(spacing: 8) {
                Text("Counting your CAH cards — cards you won this session. Each black card is a point.")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Point at your stack of black cards")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Hold steady, then tap the shutter.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

                if let errorMessage {
                    Text(errorMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(.red.opacity(0.85))
                }

                if !isUploading {
                    Button {
                        capture()
                    } label: {
                        Text("Scan cards")
                            .font(Theme.Typography.body.weight(.medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Theme.Palette.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .disabled(camera.state != .running)
                }
            }
            .padding(.bottom, 24)
        }
    }

    /// V0.71 — permission-refused / no-camera surface.
    @ViewBuilder
    private var cameraFallbackView: some View {
        VStack(spacing: 12) {
            if camera.state == .denied {
                Text("Camera access is off.")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(Theme.Typography.caption)
            } else {
                Text("No camera available on this device.")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background)
    }

    // MARK: - Result

    private func resultView(result: ScanSettleCardsResult) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your cards: \(result.count)")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Counted by the table's vision service · counts are final")
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

            Spacer()

            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("Attempt \(result.attempt) of \(ScanSettleService.maxAttempts)")
                    if result.attemptsRemaining == 0 {
                        Text("· last scan")
                    }
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Text("Photo \(String(result.photoHash.prefix(8)))…")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Text("Your photo is analysed by a cloud vision model and never stored.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

                Button(action: { Task { await done() } }) {
                    Text("Done")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                if result.attemptsRemaining > 0 {
                    Button {
                        resetForRescan()
                    } label: {
                        Text("Re-scan")
                            .font(Theme.Typography.caption.weight(.semibold))
                            .foregroundStyle(Theme.Palette.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.Palette.accent))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.vertical, 16)
        }
    }

    // MARK: - Async

    private func capture() {
        guard !isUploading else { return }
        isUploading = true
        errorMessage = nil
        scanError = nil
        Task { await processFrame() }
    }

    private func processFrame() async {
        defer { isUploading = false }

        guard let cg = await camera.capture() else {
            errorMessage = "Couldn't grab a camera frame. Try again."
            Haptics.warning()
            return
        }

        guard let jpeg = jpegData(from: cg) else {
            errorMessage = "Couldn't encode the photo. Try again."
            Haptics.warning()
            return
        }

        do {
            let result = try await scanSettle.submitCards(eventId: eventId, jpeg: jpeg)
            self.result = result
            self.showResult = true
            self.errorMessage = nil
            self.scanError = nil
            Haptics.success()
        } catch let error as ScanSettleService.ScanSettleError {
            self.scanError = error
            self.errorMessage = error.errorDescription
            Haptics.warning()
        } catch {
            self.errorMessage = (error as NSError).localizedDescription
            Haptics.warning()
        }
    }

    private func resetForRescan() {
        result = nil
        showResult = false
        errorMessage = nil
        scanError = nil
    }

    private func done() {
        onDone()
        dismiss()
    }

    /// precond: main actor. The CGImage is already a private copy.
    private func jpegData(from cg: CGImage) -> Data? {
        let uiImage = UIImage(cgImage: cg)
        return uiImage.jpegData(compressionQuality: 0.8)
    }
}
