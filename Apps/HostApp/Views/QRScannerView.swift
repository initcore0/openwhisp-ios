import SwiftUI
import AVFoundation

/// A camera QR scanner wrapping `AVCaptureMetadataOutput` (iOS-18-safe, simpler
/// than DataScannerViewController and works on more devices). Reports the raw
/// decoded string once; the caller parses it as a pairing payload.
///
/// On the Simulator (or any device with no capture device) the camera is
/// unavailable — this view renders a graceful "camera unavailable" fallback
/// instead of crashing, which is also what the XCUITest asserts.
struct QRScannerView: UIViewControllerRepresentable {
    /// Called with the first decoded payload. The coordinator stops after one hit.
    var onScan: (String) -> Void
    /// Called when the camera can't be used (no device / denied), so the sheet can
    /// show the manual fallback.
    var onUnavailable: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.coordinator = context.coordinator
        vc.onUnavailable = onUnavailable
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScan: (String) -> Void
        private var didScan = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !didScan,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  obj.type == .qr, let value = obj.stringValue else { return }
            didScan = true
            DispatchQueue.main.async { self.onScan(value) }
        }
    }
}

/// The capture-session view controller. Kept UIKit so the preview layer + session
/// lifecycle are explicit; SwiftUI hosts it via the representable above.
final class ScannerController: UIViewController {
    weak var coordinator: QRScannerView.Coordinator?
    var onUnavailable: (() -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            reportUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { reportUnavailable(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.layer.bounds
        view.layer.addSublayer(preview)
        self.previewLayer = preview

        Task.detached { [session] in session.startRunning() }
    }

    private func reportUnavailable() {
        let label = UILabel()
        label.text = "Camera unavailable.\nUse a device with a camera to scan the pairing code."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.accessibilityIdentifier = "sync.qr.unavailable"
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
        ])
        onUnavailable?()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }
}
