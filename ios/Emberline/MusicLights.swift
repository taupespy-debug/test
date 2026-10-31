import AVFoundation
import QuartzCore

// Music-reactive lights: listens with the mic and moves the Peak to the next color on each beat.
// The page hands over the light data for each color (so it's the same light the page would show); writes go
// through the tracker's light queue to the preview channel, only while the Peak isn't in a session.
// Keeps going with the app in the background (the mic stays on, the orange dot shows).
final class MusicLights {
    static let shared = MusicLights()
    weak var tracker: BackgroundTracker?
    var idle: () -> Bool = { true }
    var onChange: ((Bool) -> Void)?

    private(set) var on = false
    private let engine = AVAudioEngine()
    private var blobs: [[UInt8]] = []
    private var api2 = false
    private var avg: Float = 0, lastBeat = 0.0, idx = 0

    func start(blobs: [[UInt8]], api2: Bool) {
        self.blobs = blobs; self.api2 = api2
        guard !on, !blobs.isEmpty else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async { if ok { self.begin() } else { self.onChange?(false) } }
        }
    }

    private func begin() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { onChange?(false); return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { onChange?(false); return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { sum += ch[i] * ch[i] }
            let rms = (sum / Float(max(n, 1))).squareRoot()
            DispatchQueue.main.async { self?.level(rms) }
        }
        do { try engine.start(); on = true; onChange?(true) } catch { input.removeTap(onBus: 0); onChange?(false) }
    }

    // a beat: clearly louder than the last second or so, and not right after the last one
    private func level(_ rms: Float) {
        let now = CACurrentMediaTime()
        avg = avg == 0 ? rms : avg * 0.95 + rms * 0.05
        guard rms > max(0.008, avg * 1.45), now - lastBeat > 0.22 else { return }
        lastBeat = now
        guard idle(), !blobs.isEmpty else { return }
        idx = (idx + 1) % blobs.count
        tracker?.musicLight(blobs[idx], api2: api2)
    }

    func stop() {
        guard on else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        on = false
        tracker?.musicClear(api2: api2)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        onChange?(false)
    }
}
