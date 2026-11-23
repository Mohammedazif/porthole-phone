import AVFoundation
import SwiftUI
import UIKit

/// Capture configuration, start, stop, and metadata delivery share one serial queue.
/// The representable owns the driver's lifetime and stops it whenever it goes away.
private final class QRSessionDriver: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "porthole.qr.capture", qos: .userInitiated)
    private var configured = false
    private var delivering = false
    private var codeHandler: ((String) -> Void)?

    func start(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
        queue.async {
            if !self.configured {
                guard self.configure() else {
                    DispatchQueue.main.async { onFailure() }
                    return
                }
                self.configured = true
            }
            self.codeHandler = onCode
            self.delivering = false
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    func stop() {
        queue.async {
            self.codeHandler = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func resumeScan() {
        queue.asyncAfter(deadline: .now() + 0.8) {
            self.delivering = false
        }
    }

    private func configure() -> Bool {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return false }
        let output = AVCaptureMetadataOutput()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            return false
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            return false
        }
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = [.qr]
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivering, let codeHandler,
              let code = objects.lazy.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first
        else { return }
        delivering = true
        DispatchQueue.main.async { codeHandler(code) }
    }
}

final class QRScannerController: UIViewController {
    var onCode: ((String) -> Bool)?
    var onCameraError: ((String) -> Void)?
    private let driver = QRSessionDriver()
    private let preview = AVCaptureVideoPreviewLayer()
    private var visibility = UUID()
    private var visible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = driver.session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        visibility = UUID()
        let token = visibility
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            start(token)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async {
                    guard let self, self.visible, self.visibility == token else { return }
                    if allowed { self.start(token) }
                    else { self.onCameraError?("Camera access is off. Enable it in Settings or enter the connection details manually.") }
                }
            }
        case .restricted:
            onCameraError?("Camera access is restricted on this iPhone. Enter the connection details manually.")
        default:
            onCameraError?("Camera access is off. Enable it in Settings or enter the connection details manually.")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stop()
    }

    func stop() {
        visible = false
        visibility = UUID()
        driver.stop()
    }

    private func start(_ token: UUID) {
        guard visible, visibility == token else { return }
        driver.start(onCode: { [weak self] code in
            guard let self, self.visible, self.visibility == token else { return }
            if self.onCode?(code) == true { self.stop() }
            else { self.driver.resumeScan() }
        }, onFailure: { [weak self] in
            guard let self, self.visible, self.visibility == token else { return }
            self.onCameraError?("A compatible camera is unavailable. Enter the connection details manually.")
        })
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Bool
    let onCameraError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerController {
        let controller = QRScannerController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: QRScannerController, context: Context) {
        controller.onCode = onCode
        controller.onCameraError = onCameraError
    }

    static func dismantleUIViewController(_ controller: QRScannerController, coordinator: ()) {
        controller.stop()
    }
}
