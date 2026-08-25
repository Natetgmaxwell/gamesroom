//
//  ChipScanSheet.swift
//  GamesRoom
//
//  Track F-CAS-02 — member-facing chip scan surface (V0.72 slice 3).
//
//  V0.72 rework: the hosted vision model is the authoritative counter
//  for chip stacks on `minimax_vision` rooms. The member captures a
//  JPEG, the `scan-settle` edge function (slice 2) hashes the bytes,
//  sends them to the MiniMax vision model, and records the count
//  server-side via service role (migration 069 RPCs). The member
//  client never posts a count. The result screen is read-only:
//  total points, per-color rows, withdrawn + net, photo hash tail,
//  attempt position, and the privacy line.
//
//  Re-scan: latest-wins, capped at 5 per event (server-enforced).
//  429 → "Scan limit reached — wait for the next night's event"
//  (the host manual-settle sheet was removed in V0.74; the
//  migration 070 server-side carve-out remains as a safety net).
//
//  Privacy reversal: V0.72 sends the JPEG to the MiniMax vision
//  API. The bytes never persist server-side (edge function hashes
//  + discards); the hash rides in the response so a disputed count
//  can be matched to its capture frame. T1.2's `keepScanPhotos`
//  toggle still writes the JPEG to the device sandbox for the
//  member's own record.
//
//

import SwiftUI
import AVFoundation
import CoreImage

struct ChipScanSheet: View {

    let eventId: UUID
    let roomId: UUID
    let withdrawn: Int
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var casinoService: CasinoService
    @EnvironmentObject private var authService: AuthService

    // V0.72 — scan-settle circuit. The service holds the URLSession
    // and response DTOs; this view drives the capture-and-display
    // loop on top of it.
    @StateObject private var scanSettle = ScanSettleService()

    // V0.71 — owns the AVCaptureSession across the camera ↔ result
    // swap so a re-scan reuses the live session instead of
    // rebuilding it (V0.50 tore the session down with every view
    // swap). @StateObject, not @State: the shutter is disabled
    // until `state == .running`, and @State never re-renders on
    // the controller's @Published changes.
    @StateObject private var camera = ScanCameraController()

    // T1.2 — opt-in photo retention. The F-CAS-03 discard path
    // stays the default; when on, the confirmed scan's JPEG lands
    // in Documents/ScanPhotos/ and never leaves the device.
    @AppStorage(StorageKeys.keepScanPhotos) private var keepScanPhotos = false
    @State private var lastJpeg: Data?

    // Upload-in-flight flag. The shutter is disabled (no second
    // capture can fire while the edge function is in transit) and
    // the camera shows a progress overlay.
    @State private var isUploading: Bool = false

    // Result screen surface. nil ⇒ render the camera view; non-nil
    // ⇒ render the read-only result screen. Re-scan clears this.
    @State private var result: ScanSettleChipsResult?
    @State private var showResult: Bool = false
    // V0.72 microinteraction — the count rolls from 0 to the final
    // total on reveal (numericText + chipSettle-style spring), so the
    // value reads as landing rather than appearing.
    @State private var displayedTotal: Int = 0

    // Inline error surface (camera view). The error's localized
    // description drives the copy; the type drives the icon (none
    // here — caption style only).
    @State private var errorMessage: String?
    @State private var scanError: ScanSettleService.ScanSettleError?

    private var netDelta: Int {
        if let result { return result.totalPoints - withdrawn }
        return 0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.Palette.background.ignoresSafeArea()

                if showResult, let result {
                    resultView(result: result)
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                } else {
                    cameraView
                }
            }
            .navigationTitle(showResult ? "Your chips" : "Scan your chips")
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
                        Text("Counting chips…")
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
                Text("You brought \(withdrawn) pts. Scan what's left on the table.")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Point at your chip stack")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Tap the shutter.")
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
                        Text("Scan chips")
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

    private func resultView(result: ScanSettleChipsResult) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Your chips: \(displayedTotal) pts")
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Palette.primaryText)
                    .contentTransition(.numericText())
                    .animation(Theme.Motion.popIn, value: displayedTotal)
                HStack(spacing: 8) {
                    Text("Counted by the table's vision service · counts are final")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                }
                Text("Withdrew: \(withdrawn) pts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
                Text("Net: \(netDelta >= 0 ? "+" : "")\(netDelta) pts")
                    .font(Theme.Typography.body.weight(.semibold))
                    .foregroundStyle(netDelta >= 0 ? Theme.Palette.accent : Theme.Palette.primaryText.opacity(0.7))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Layout.gutter)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Divider()
                .background(Theme.Palette.hairline)
                .padding(.horizontal, Theme.Layout.gutter)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(result.stacks.enumerated()), id: \.offset) { _, stack in
                        stackRow(stack: stack)
                    }
                }
            }

            Divider()
                .background(Theme.Palette.hairline)
                .padding(.horizontal, Theme.Layout.gutter)

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

    private func stackRow(stack: ScanSettleChipStack) -> some View {
        let chipColor = ChipColor(rawValue: stack.color.lowercased())
        let displayName = chipColor?.displayName ?? stack.color.capitalized
        let value = chipColor?.defaultValue ?? 0
        return HStack(spacing: 12) {
            Circle()
                .fill(swiftUIColor(for: chipColor))
                .frame(width: 24, height: 24)
                .overlay(
                    Text("\(stack.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(chipColor == .white ? .black : .white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(displayName) stack")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("\(stack.count) × \(value) pts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            Spacer()
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.vertical, 12)
    }

    private func swiftUIColor(for chipColor: ChipColor?) -> Color {
        guard let chipColor else { return Theme.Palette.accent }
        switch chipColor {
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .black: return .black
        case .white: return .white
        case .custom: return Theme.Palette.accent
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

        let jpeg = jpegData(from: cg)
        if keepScanPhotos, let jpeg {
            lastJpeg = jpeg
        }

        guard let jpeg else {
            errorMessage = "Couldn't encode the photo. Try again."
            Haptics.warning()
            return
        }

        do {
            let result = try await scanSettle.submitChips(eventId: eventId, jpeg: jpeg)
            self.result = result
            // V0.72 (072) — the scan landed server-side; drop the
            // working-hands cache so the post-dismiss refresh reads
            // has_scanned=true instead of a ≤30s-stale badge.
            casinoService.invalidateEventCaches(eventId: eventId)
            // V0.72 microinteraction — the result view pops in (scale +
            // fade) rather than snapping, so the count reveal reads as a
            // resolution beat. The count itself rolls via numericText.
            withAnimation(Theme.Motion.popIn) {
                self.showResult = true
            }
            // Roll the count up from 0 to the final total.
            withAnimation(Theme.Motion.popIn) {
                self.displayedTotal = result.totalPoints
            }
            self.errorMessage = nil
            self.scanError = nil
            // T1.2 — best-effort local write. A failed photo save
            // never fails the scan; the count is already recorded.
            if keepScanPhotos, let lastJpeg {
                persistScanPhoto(lastJpeg)
            }
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
        displayedTotal = 0
        errorMessage = nil
        scanError = nil
        lastJpeg = nil
    }

    private func done() {
        onDone()
        dismiss()
    }

    /// T1.2 — writes the confirmed scan's JPEG to the app sandbox
    /// (`Documents/ScanPhotos/<eventId>-<memberId>-<timestamp>.jpg`).
    /// Local-only by design; the photo is never uploaded by the app.
    private func persistScanPhoto(_ jpeg: Data) {
        guard let memberId = authService.currentUserId else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("ScanPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(eventId.uuidString)-\(memberId.uuidString)-\(stamp).jpg")
        try? jpeg.write(to: url)
    }

    /// precond: main actor (called from `processFrame`, which runs in
    /// a Task from the view). The CGImage is already a private copy —
    /// safe to encode here.
    private func jpegData(from cg: CGImage) -> Data? {
        let uiImage = UIImage(cgImage: cg)
        return uiImage.jpegData(compressionQuality: 0.8)
    }
}
