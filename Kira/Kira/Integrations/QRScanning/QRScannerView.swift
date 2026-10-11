import SwiftUI
import AVFoundation
import UIKit

/// Camera QR scanner built on AVFoundation (`AVCaptureMetadataOutput`).
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onScan = onScan
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    static var authorizationStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "my.kira.qr.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configure()
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            onError?("The camera isn’t available on this device.")
            return
        }
        session.beginConfiguration()
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            onError?("QR scanning isn’t supported on this device.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasReported = false
        let session = self.session
        sessionQueue.async { if !session.isRunning { session.startRunning() } }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        sessionQueue.async { if session.isRunning { session.stopRunning() } }
    }

    // Delegate queue is `.main` (set above), so hopping onto the main actor is safe.
    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        MainActor.assumeIsolated { self.report(code) }
    }

    private func report(_ code: String) {
        guard !hasReported else { return }
        hasReported = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onScan?(code)
    }
}
