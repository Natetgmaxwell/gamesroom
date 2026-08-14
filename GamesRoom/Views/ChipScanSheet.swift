//
//  ChipScanSheet.swift
//  GamesRoom
//
//  Track F-CAS-02 — member-facing chip scan surface.
//
//  The member points their phone at their own chip stack, the
//  on-device segmentation detector (LOCKED, stress recall 0.975 /
//  precision 1.000 / color 0.974) counts the stacks, and the member
//  confirms or adjusts before the scan is recorded. The photo bytes
//  are hashed (SHA-256) and discarded immediately — F-CAS-03: photos
//  stay on-device, only the hash + vision snapshot travel.
//
//  The count estimate is the detector's known-weak metric (MAE ~6
//  chips on low-contrast stacks), so every stack row is editable
//  before confirm — the user-attestation fallback from the probe
//  decision matrix.
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

    @State private var detectedStacks: [DetectedStack] = []
    @State private var totalValue: Int = 0
    @State private var confidenceAvg: Double = 0
    @State private var photoHash: String?
    @State private var isScanning = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var showConfirm = false
    @State private var lowConfidencePrompt = false

    // T1.2 — opt-in photo retention. Default off: the F-CAS-03
    // discard path stays identical. When on, the confirmed scan's
    // JPEG lands in Documents/ScanPhotos/ and never leaves the
    // device.
    @AppStorage(StorageKeys.keepScanPhotos) private var keepScanPhotos = false
    @State private var lastJpeg: Data?

    private var netDelta: Int { totalValue - withdrawn }

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
            .navigationTitle(showConfirm ? "Your chips" : "Scan your chips")
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
                Text("Settling your Casino hand — you brought \(withdrawn) pts. Scan what's left on the table.")
                    .font(Theme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Point at your chip stack")
                    .font(Theme.Typography.body.weight(.medium))
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("Hold steady. The host doesn't scan for you anymore.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))

                if isScanning {
                    ProgressView()
                        .tint(Theme.Palette.accent)
                    Text("Counting chips…")
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
                Text("Your chips: \(totalValue) pts")
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
                Text("Withdrew: \(withdrawn) pts")
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

            ScrollView {
                LazyVStack(spacing: 0) {
                    // Row identity is the index, not the stack's id:
                    // DetectedStack.id embeds `count`, which changes
                    // when the member edits the stepper — using it
                    // would rebuild the row mid-interaction.
                    ForEach(Array(detectedStacks.enumerated()), id: \.offset) { index, stack in
                        stackRow(stack: stack, index: index)
                    }
                }
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
                    Text(isSubmitting ? "Recording…" : "Looks right — record \(netDelta >= 0 ? "+" : "")\(netDelta) pts")
                        .font(Theme.Typography.body.weight(.medium))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.Palette.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isSubmitting)

                Button {
                    detectedStacks = []
                    totalValue = 0
                    confidenceAvg = 0
                    photoHash = nil
                    lastJpeg = nil
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

    private func stackRow(stack: DetectedStack, index: Int) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(chipColor(stack.chipColor))
                .frame(width: 24, height: 24)
                .overlay(
                    Text("\(stack.count)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(stack.chipColor == .white ? .black : .white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("\(stack.chipColor.displayName) stack")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.primaryText)
                Text("\(stack.count) chips × \(chipValue(stack.chipColor)) pts")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.primaryText.opacity(0.55))
            }

            Spacer()

            // The count estimate is the detector's weak metric —
            // the member adjusts before confirming.
            Stepper("", value: Binding(
                get: { stack.count },
                set: { newCount in
                    detectedStacks[index] = DetectedStack(
                        seatIndex: stack.seatIndex,
                        chipColor: stack.chipColor,
                        count: max(1, newCount),
                        confidence: stack.confidence,
                        boundingBox: stack.boundingBox
                    )
                    recomputeTotals()
                }
            ), in: 1...200)
            .labelsHidden()
        }
        .padding(.horizontal, Theme.Layout.gutter)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func chipColor(_ color: ChipColor) -> Color {
        switch color {
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .black: return .black
        case .white: return .white
        case .custom: return Theme.Palette.accent
        }
    }

    private func chipValue(_ color: ChipColor) -> Int {
        color.defaultValue
    }

    private func recomputeTotals() {
        totalValue = detectedStacks.reduce(0) { $0 + $1.count * chipValue($1.chipColor) }
        confidenceAvg = detectedStacks.isEmpty
            ? 0
            : detectedStacks.map(\.confidence).reduce(0, +) / Double(detectedStacks.count)
    }

    // MARK: - Async

    private func processFrame(pixelBuffer: CVPixelBuffer) async {
        guard !isScanning else { return }
        isScanning = true
        Haptics.light()
        defer { isScanning = false }

        guard let cg = cgImage(from: pixelBuffer) else {
            errorMessage = "Couldn't read the camera frame. Try again."
            return
        }

        // F-CAS-03: hash the photo bytes, then discard them. Only
        // the hash + vision snapshot travel. T1.2: when the opt-in
        // is on, the JPEG is kept for the confirm step instead.
        let jpeg = jpegData(from: pixelBuffer)
        let hash = jpeg.map { PhotoHash.sha256($0) }
        if keepScanPhotos {
            lastJpeg = jpeg
        }

        let stacks = ChipSegmentationDetector().detect(cg: cg)
        guard !stacks.isEmpty else {
            errorMessage = "No chip stacks found. Move closer, improve lighting, and try again."
            return
        }

        detectedStacks = stacks
        photoHash = hash
        recomputeTotals()
        if ScanConfidenceGate.shouldPromptRescan(confidenceAvg: confidenceAvg) {
            lowConfidencePrompt = true
            Haptics.warning()
            return
        }
        showConfirm = true
    }

    private func confirm() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let snapshot = VisionSnapshot(
            stacks: detectedStacks,
            totalValue: totalValue,
            confidenceAvg: confidenceAvg,
            discarded: false,
            photoHash: photoHash
        )

        do {
            _ = try await casinoService.submitMemberScan(
                eventId: eventId,
                visionAmount: Int64(totalValue),
                visionSnapshot: snapshot,
                confidence: confidenceAvg,
                source: .onDevice
            )
            // T1.2 — best-effort local write. A failed photo save
            // never fails the scan; the hash is already recorded.
            if keepScanPhotos, let jpeg = lastJpeg {
                persistScanPhoto(jpeg)
            }
            Haptics.success()
            onDone()
            dismiss()
        } catch {
            errorMessage = "Failed to record scan: \((error as NSError).localizedDescription)"
        }
    }

    /// T1.2 — writes the confirmed scan's JPEG to the app sandbox
    /// (`Documents/ScanPhotos/<eventId>-<memberId>-<timestamp>.jpg`).
    /// Local-only by design; the photo is never uploaded.
    private func persistScanPhoto(_ jpeg: Data) {
        guard let memberId = authService.currentUserId else { return }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents.appendingPathComponent("ScanPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let url = dir.appendingPathComponent("\(eventId.uuidString)-\(memberId.uuidString)-\(stamp).jpg")
        try? jpeg.write(to: url)
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

// MARK: - Camera preview

struct ScanCameraPreview: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    let onFrameCaptured: (CVPixelBuffer) -> Void

    func makeUIViewController(context: Context) -> ScanCameraViewController {
        let vc = ScanCameraViewController()
        vc.onFrameCaptured = onFrameCaptured
        vc.isScanningBinding = $isScanning
        return vc
    }

    func updateUIViewController(_ uiViewController: ScanCameraViewController, context: Context) {}
}

class ScanCameraViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrameCaptured: ((CVPixelBuffer) -> Void)?
    var isScanningBinding: Binding<Bool>

    init() {
        self.isScanningBinding = .constant(false)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureVideoDataOutput()
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "camera"))
        output.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        self.captureSession = session
        self.previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard !isScanningBinding.wrappedValue else { return }

        DispatchQueue.main.async {
            self.isScanningBinding.wrappedValue = true
            self.onFrameCaptured?(pixelBuffer)
        }
    }
}
