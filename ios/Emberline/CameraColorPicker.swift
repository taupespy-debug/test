import UIKit
import AVFoundation

// Point the camera at something and the Peak copies that color: the middle of the picture is sampled ~10 times a
// second, the Peak previews it live, and "Use color" saves it as the profile light.
final class CameraColorPicker: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onLive: ((String) -> Void)?
    var onDone: ((String?) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.color")
    private var preview: AVCaptureVideoPreviewLayer?
    private let ring = UIView(), swatch = UIView(), hexLabel = UILabel()
    private var hex = "#ffffff"
    private var lastSample = 0.0, lastLive = 0.0
    private var finished = false

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let pv = AVCaptureVideoPreviewLayer(session: session)
        pv.videoGravity = .resizeAspectFill
        view.layer.addSublayer(pv)
        preview = pv

        ring.layer.borderColor = UIColor.white.cgColor
        ring.layer.borderWidth = 3
        ring.layer.cornerRadius = 36
        ring.isUserInteractionEnabled = false
        view.addSubview(ring)

        let bar = UIView()
        bar.backgroundColor = UIColor(white: 0.06, alpha: 0.92)
        bar.layer.cornerRadius = 24
        view.addSubview(bar)
        swatch.layer.cornerRadius = 14
        swatch.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
        swatch.layer.borderWidth = 1
        hexLabel.textColor = .white
        hexLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        hexLabel.text = "Aim at a color"
        let use = UIButton(type: .system), cancel = UIButton(type: .system)
        var u = UIButton.Configuration.filled(); u.title = "Use color"; u.cornerStyle = .capsule; u.baseBackgroundColor = UIColor(red: 0.45, green: 0, blue: 1, alpha: 1)
        use.configuration = u
        var c = UIButton.Configuration.plain(); c.title = "Cancel"; c.baseForegroundColor = .white
        cancel.configuration = c
        use.addTarget(self, action: #selector(useTapped), for: .touchUpInside)
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        [swatch, hexLabel, use, cancel].forEach { bar.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        [ring, bar].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            ring.centerXAnchor.constraint(equalTo: view.centerXAnchor), ring.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 72), ring.heightAnchor.constraint(equalToConstant: 72),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12), bar.heightAnchor.constraint(equalToConstant: 76),
            swatch.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14), swatch.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 48), swatch.heightAnchor.constraint(equalToConstant: 48),
            hexLabel.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 12), hexLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            use.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12), use.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            cancel.trailingAnchor.constraint(equalTo: use.leadingAnchor, constant: -4), cancel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        AVCaptureDevice.requestAccess(for: .video) { ok in
            DispatchQueue.main.async { ok ? self.startCamera() : self.denied() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    private func startCamera() {
        queue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .vga640x480
            guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: dev), self.session.canAddInput(input) else { self.session.commitConfiguration(); return }
            self.session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: self.queue)
            if self.session.canAddOutput(out) { self.session.addOutput(out) }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }

    private func denied() {
        hexLabel.text = "Camera is off for Emberline"
        let a = UIAlertController(title: "Camera access", message: "Turn on the camera for Emberline in Settings to pick colors.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in self.cancelTapped() })
        present(a, animated: true)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastSample > 0.1, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        lastSample = now
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var r = 0, g = 0, b = 0, n = 0
        for y in stride(from: h / 2 - 12, to: h / 2 + 12, by: 2) {
            for x in stride(from: w / 2 - 12, to: w / 2 + 12, by: 2) {
                let o = y * row + x * 4
                b += Int(p[o]); g += Int(p[o + 1]); r += Int(p[o + 2]); n += 1
            }
        }
        guard n > 0 else { return }
        // LEDs look washed out with camera colors: push saturation and brightness up a little
        let c = UIColor(red: CGFloat(r / n) / 255, green: CGFloat(g / n) / 255, blue: CGFloat(b / n) / 255, alpha: 1)
        var hu: CGFloat = 0, sa: CGFloat = 0, br: CGFloat = 0, al: CGFloat = 0
        c.getHue(&hu, saturation: &sa, brightness: &br, alpha: &al)
        let led = UIColor(hue: hu, saturation: min(1, sa * 1.3), brightness: max(br, 0.85), alpha: 1)
        var rr: CGFloat = 0, gg: CGFloat = 0, bb: CGFloat = 0
        led.getRed(&rr, green: &gg, blue: &bb, alpha: &al)
        let hx = String(format: "#%02x%02x%02x", Int(rr * 255), Int(gg * 255), Int(bb * 255))
        DispatchQueue.main.async {
            guard !self.finished else { return }
            self.hex = hx
            self.swatch.backgroundColor = led
            self.ring.backgroundColor = led.withAlphaComponent(0.35)
            self.hexLabel.text = hx.uppercased()
            if now - self.lastLive > 0.45 { self.lastLive = now; self.onLive?(hx) } // the Peak follows as you aim
        }
    }

    @objc private func useTapped() { finish(hex) }
    @objc private func cancelTapped() { finish(nil) }
    private func finish(_ h: String?) {
        guard !finished else { return }
        finished = true
        queue.async { self.session.stopRunning() }
        dismiss(animated: true) { self.onDone?(h) }
    }
}
