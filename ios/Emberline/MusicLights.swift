import AVFoundation
import QuartzCore

// Music-reactive lights: listens with the mic and moves the Peak to the next color on each beat.
// It only hears the beat: with the app open the page writes the color (its own Bluetooth queue, so nothing collides
// with its polling), and with the app closed the tracker writes it (nothing else is talking to the Peak then).
// Beats come from the bass (kicks, 808s) with a threshold that follows how loud the song is, never mid-session.
final class MusicLights {
    static let shared = MusicLights()
    weak var tracker: BackgroundTracker?
    var idle: () -> Bool = { true }
    var onChange: ((Bool, String) -> Void)?   // on, and why it stopped
    var onBeat: ((Int) -> Void)?              // the page writes this color (app open)

    private(set) var on = false
    private var engine = AVAudioEngine()
    private var blobs: [[UInt8]] = []
    private var api2 = false
    private var lastBeat = 0.0, idx = 0
    private var mean: Float = 0, dev: Float = 0
    private var low: Float = 0, lowA: Float = 0.02 // one-pole low-pass state (audio thread only)

    func start(blobs: [[UInt8]], api2: Bool) {
        self.blobs = blobs; self.api2 = api2
        guard !on, !blobs.isEmpty else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async { if ok { self.begin() } else { self.onChange?(false, "mic") } }
        }
    }

    private func begin() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try s.setActive(true)
        } catch { onChange?(false, "audio"); return }
        engine = AVAudioEngine() // a fresh one: an engine made before the category change can come up silent
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { onChange?(false, "mic"); return }
        lowA = Float(1 - exp(-2 * Double.pi * 150 / fmt.sampleRate)) // keep below ~150 Hz: the kick and bass
        low = 0; mean = 0; dev = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var y = self.low, sum: Float = 0
            for i in 0..<n { y += self.lowA * (ch[i] - y); sum += y * y }
            self.low = y
            let e = (sum / Float(max(n, 1))).squareRoot()
            DispatchQueue.main.async { self.level(e) }
        }
        do { try engine.start(); on = true; onChange?(true, "") }
        catch { input.removeTap(onBus: 0); onChange?(false, "audio") }
    }

    // a beat: the bass jumps clearly above where it's been for the last second or so
    private func level(_ e: Float) {
        guard on else { return }
        let now = CACurrentMediaTime()
        if mean == 0 { mean = e }
        let beat = e > mean + 1.5 * dev && e > 0.003 && now - lastBeat > 0.25
        mean = mean * 0.96 + e * 0.04
        dev = dev * 0.96 + abs(e - mean) * 0.04
        guard beat else { return }
        lastBeat = now
        guard idle(), !blobs.isEmpty else { return }
        idx = (idx + 1) % blobs.count
        if tracker?.owning == true { tracker?.musicLight(blobs[idx], api2: api2) } // app closed: we have the Peak
        else { onBeat?(idx) }                                                      // app open: the page writes it
    }

    func stop() {
        guard on else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        on = false
        if tracker?.owning == true { tracker?.musicClear(api2: api2) } else { onBeat?(-1) } // -1: put the light back
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        onChange?(false, "")
    }
}
