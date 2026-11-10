import SwiftUI
import AVFoundation

/// Full-screen camera that closes as soon as it reads a barcode.
struct ScanSheet: View {
    var onFound: (String, BarcodeKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                CameraScanner { value, kind in
                    onFound(value, kind)
                    dismiss()
                }
                .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 16)
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 300, height: 180)
                VStack {
                    Spacer()
                    Text("Point the camera at your gym barcode")
                        .font(.callout.weight(.semibold))
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 40)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

struct CameraScanner: UIViewControllerRepresentable {
    var onFound: (String, BarcodeKind) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onFound = onFound
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onFound: ((String, BarcodeKind) -> Void)?
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showMessage("Camera isn't available. Allow it in Settings > Gym Pass > Camera, or choose a photo instead.")
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        let wanted: [AVMetadataObject.ObjectType] = [
            .qr, .code128, .code39, .code39Mod43, .ean13, .ean8, .upce, .pdf417, .aztec,
            .itf14, .interleaved2of5, .dataMatrix, .code93, .codabar, .microQR, .microPDF417,
        ]
        output.metadataObjectTypes = wanted.filter { output.availableMetadataObjectTypes.contains($0) }

        if (try? device.lockForConfiguration()) != nil {
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !done, let code = objects.first as? AVMetadataMachineReadableCodeObject,
              let value = code.stringValue, !value.isEmpty else { return }
        done = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onFound?(value, BarcodeKind.from(metadata: code.type))
    }

    private func showMessage(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])
    }
}
