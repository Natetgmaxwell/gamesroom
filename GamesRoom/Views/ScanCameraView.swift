//
//  ScanCameraView.swift
//  GamesRoom
//
//  V0.71 — explicit-capture scan camera shared by ChipScanSheet and
//  CAHCardScanSheet. Replaces the V0.50 auto-capture preview.
//
//  Why the replacement (V0.50 defect): the old component grabbed the
//  camera's FIRST delivered frame and gated re-entry with a shared
//  `isScanning` flag that two components wrote — the preview VC set
//  it before invoking the frame callback while `processFrame` also
//  guarded on it. The very first frame was therefore dropped and the
//  flag never cleared: the sheet sat on "Counting chips…" forever
//  with zero detector work run. The CAH scan (V0.34) inherited the
//  flow and the defect. The first-frame grab itself was also wrong:
//  the first frame after session start is cold — unfocused,
//  unexposed — the worst frame to count.
//
//  Design:
//  * The AVCaptureSession is owned by the controller, which outlives
//    SwiftUI body churn and the camera/confirm view swap — re-scans
//    are instant instead of rebuilding the session each time.
//  * Nothing is captured until the member taps the shutter;
//    `capture()` resumes with the NEXT frame after the call, when
//    focus and exposure have settled.
//  * The pool pixel buffer is converted to CGImage on the camera
//    queue before it escapes the delegate callback — recycled pool
//    buffers must never be read asynchronously.
//  * A 5s safety valve resumes `capture()` with nil so the UI can
//    never hang on "Counting…" again.
//

import SwiftUI
import AVFoundation
import CoreImage
import CoreVideo

// MARK: - Controller

/// Explicit-capture camera for the member scan sheets.
///
/// All session work is confined to `sessionQueue`; published state
/// is only ever mutated on the main thread.
final class ScanCameraController: NSObject, ObservableObject {

    enum State {
        case idle        // not started
        case starting    // permission / configuration in flight
        case running     // preview live, ready to capture
        case denied      // camera permission refused
        case unavailable // no camera (e.g. Simulator)
    }

    @Published private(set) var state: State = .idle

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "games-room.scan-camera")
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var configured = false
    private var captureContinuation: CheckedContinuation<CGImage?, Never>?

    /// Idempotent. Requests camera access on first use; re-callable
    /// from `.denied` after the member changes Settings.
    func start() {
        if state == .running || state == .starting { return }
        setState(.starting)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if granted {
                self.sessionQueue.async { self.configureAndStart() }
            } else {
                self.setState(.denied)
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    /// Resumes with the next delivered frame (converted to a
    /// CGImage on the camera queue), or nil if no frame arrives
    /// within 5 seconds.
    func capture() async -> CGImage? {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                captureContinuation = cont
                // Safety valve: a dead session must never wedge the
                // UI on "Counting…" — resume nil after 5s.
                sessionQueue.asyncAfter(deadline: .now() + 5) { [self] in
                    resumePending(with: nil)
                }
            }
        }
    }

    /// precond: sessionQueue.
    private func resumePending(with image: CGImage?) {
        guard let cont = captureContinuation else { return }
        captureContinuation = nil
        cont.resume(returning: image)
    }

    private func setState(_ s: State) {
        if Thread.isMainThread {
            state = s
        } else {
            DispatchQueue.main.async { self.state = s }
        }
    }

    /// precond: sessionQueue.
    private func configureAndStart() {
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                session.commitConfiguration()
                setState(.unavailable)
                return
            }
            session.addInput(input)

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            output.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(output) {
                session.addOutput(output)
            }

            configured = true
            session.commitConfiguration()
        }
        if !session.isRunning {
            session.startRunning()
        }
        setState(.running)
    }
}

// MARK: - Frame delivery

extension ScanCameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Runs on sessionQueue — the same queue that arms
        // `captureContinuation`, so the handshake is race-free and
        // single-frame: the continuation is consumed exactly once.
        guard captureContinuation != nil else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            resumePending(with: nil)
            return
        }
        // Convert here, before the buffer escapes this callback:
        // the output pool recycles pixel buffers once we return.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent)
        resumePending(with: cgImage)
    }
}

// MARK: - SwiftUI bridge

struct ScanCameraView: UIViewControllerRepresentable {
    let controller: ScanCameraController

    func makeUIViewController(context: Context) -> ScanPreviewViewController {
        let vc = ScanPreviewViewController()
        let preview = AVCaptureVideoPreviewLayer(session: controller.session)
        preview.videoGravity = .resizeAspectFill
        vc.previewLayer = preview
        vc.view.layer.addSublayer(preview)
        return vc
    }

    func updateUIViewController(_ uiViewController: ScanPreviewViewController, context: Context) {}
}

final class ScanPreviewViewController: UIViewController {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }
}
