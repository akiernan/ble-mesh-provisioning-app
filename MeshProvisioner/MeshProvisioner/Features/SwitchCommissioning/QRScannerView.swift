@preconcurrency import AVFoundation
import SwiftUI

/// Full-screen QR/DataMatrix camera scanner.
///
/// Scans for `.qr` and `.dataMatrix` codes (PTM216B device labels may use either).
/// Calls `onResult` on the main actor with the decoded string when a code is detected.
/// Calls `onCancel` if the user dismisses without scanning.
struct QRScannerView: UIViewControllerRepresentable {
    let onResult: @MainActor (String) -> Void
    let onCancel: @MainActor () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        QRScannerViewController(onResult: onResult, onCancel: onCancel)
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

// MARK: - QRScannerViewController

final class QRScannerViewController: UIViewController {

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var onResult: (@MainActor (String) -> Void)?
    private var onCancel: (@MainActor () -> Void)?
    private var hasDelivered = false

    init(onResult: @escaping @MainActor (String) -> Void,
         onCancel: @escaping @MainActor () -> Void) {
        self.onResult = onResult
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCaptureSession()
        setupOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: - Setup

    private func setupCaptureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else { return }
        captureSession.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { return }
        captureSession.addOutput(output)
        // Delegate on main queue so hasDelivered access is thread-safe
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr, .dataMatrix]

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    private func setupOverlay() {
        // Instruction label
        let label = UILabel()
        label.text = "Point at the QR/DataMatrix code\non the switch label"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.numberOfLines = 2
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)

        // Cancel button
        let button = UIButton(type: .system)
        button.setTitle("Cancel", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 18, weight: .semibold)
        button.setTitleColor(.white, for: .normal)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 32),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
        ])
    }

    @objc private func cancelTapped() {
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
        onCancel?()
        onResult = nil
        onCancel = nil
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {

    // Called on main queue (as set in setMetadataObjectsDelegate(_:queue:))
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let string = object.stringValue else { return }
        Task { @MainActor [weak self, string] in
            guard let self, !self.hasDelivered else { return }
            self.hasDelivered = true
            let session = self.captureSession
            DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
            self.onResult?(string)
            self.onResult = nil
            self.onCancel = nil
        }
    }
}
