import AVFoundation
import QuartzCore

// Music-reactive lights: listens with the mic and moves the Peak's light with the music.
// - Beats come from the bass (kicks, 808s) with a threshold that follows the song's loudness.
// - It learns the tempo, and fires each color a little early (by how long the Peak takes to show a light, measured
//   by the page) so it lands on the beat, and keeps the rhythm through quiet bits.
// It only listens and keeps time: the page writes one animated mood at the song's tempo (at most every 10 s), never a
// light per beat. With the app closed the Peak keeps playing the last one. Never mid-session.
final class MusicLights {
    static let shared = MusicLights()
    weak var tracker: BackgroundTracker?
    var idle: () -> Bool = { true }
    var onChange: ((Bool, String) -> Void)?        // on, and why it stopped
    var onBeat: ((Int, Int) -> Void)?              // color index, kind (0 dim, 1 beat, 2 drop) for the page; index -1 = stop
    var onMeter: ((Double, Int, Bool) -> Void)?    // level 0...1, bpm (0 = still learning), beat right now

    private(set) var on = false
    private var engine = AVAudioEngine()
    // light data: bright, dim and the white flash (the page made them, so they're the same lights it would write)
    private var blobs: [[UInt8]] = [], dims: [[UInt8]] = [], flash: [UInt8] = []
    private var api2 = false
    var style = "beat"        // beat (every beat), bars (every 4th), drops (big hits only)
    var sens = 1.0            // 0.5 (only strong beats) ... 2 (everything)
    var latency = 0.18        // seconds from sending a light to the Peak showing it (the page measures it)

    private var mean: Float = 0, dev: Float = 0, slow: Float = 0
    private var low: Float = 0, lowA: Float = 0.02  // one-pole low-pass (audio thread only)
    private var lastHit = 0.0, lastFire = 0.0, idx = 0, count = 0
    private var ibis: [Double] = []                 // recent beat-to-beat times
    private var period = 0.0                        // the beat, once it's steady
    private var nextAt = 0.0                        // the next predicted beat
    private var ticker: Timer?
    private var lastMeter = 0.0, level: Float = 0, beatNow = false

    func start(blobs: [[UInt8]], dims: [[UInt8]], flash: [UInt8], api2: Bool) {
        self.blobs = blobs; self.dims = dims.count == blobs.count ? dims : blobs; self.flash = flash.isEmpty ? (blobs.first ?? []) : flash; self.api2 = api2
        guard !on, !blobs.isEmpty else { return }
        AVAudioApplication.requestRecordPermission { ok in
            DispatchQueue.main.async { if ok { self.begin() } else { self.onChange?(false, "mic") } }
        }
    }

    private func begin() {
        let s = AVAudioSession.sharedInstance()
        do {
            try s.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]) // measurement: no voice processing squashing the bass
            try s.setActive(true)
        } catch { onChange?(false, "audio"); return }
        engine = AVAudioEngine() // a fresh one: an engine made before the category change can come up silent
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { onChange?(false, "mic"); return }
        lowA = Float(1 - exp(-2 * Double.pi * 150 / fmt.sampleRate)) // below ~150 Hz: the kick and the bass
        low = 0; mean = 0; dev = 0; slow = 0; ibis = []; period = 0; nextAt = 0; count = 0
        input.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buf, _ in // ~11 ms buffers: quick to react
            guard let self = self, let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var y = self.low, sum: Float = 0
            for i in 0..<n { y += self.lowA * (ch[i] - y); sum += y * y }
            self.low = y
            let e = (sum / Float(max(n, 1))).squareRoot()
            DispatchQueue.main.async { self.hear(e) }
        }
        do { try engine.start() } catch { input.removeTap(onBus: 0); onChange?(false, "audio"); return }
        on = true
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(ticker!, forMode: .common)
        onChange?(true, "")
    }

    // a beat: the bass jumps clearly above where it's been for the last second or so
    private func hear(_ e: Float) {
        guard on else { return }
        let now = CACurrentMediaTime()
        if mean == 0 { mean = e; slow = e }
        let k = Float(2.2 - 0.7 * min(2, max(0.5, sens))) // sensitivity 0.5 -> 1.85, 1 -> 1.5, 2 -> 0.8
        let hit = e > mean + k * dev && e > 0.0025 && now - lastHit > 0.24
        mean = mean * 0.97 + e * 0.03
        dev = dev * 0.97 + abs(e - mean) * 0.03
        slow = slow * 0.998 + e * 0.002 // the song's overall level (for dim / drop)
        level = min(1, e / max(0.004, slow * 3))
        if hit { heardBeat(now, e) }
        meter(now)
    }

    private func heardBeat(_ now: Double, _ e: Float) {
        // learn the tempo from the gaps between beats (a gap of 2 beats counts as 2 of them)
        if lastHit > 0 {
            var gap = now - lastHit
            if period > 0 { let r = (gap / period).rounded(); if r >= 2 && r <= 4 && abs(gap - r * period) < 0.08 { gap /= r } }
            if gap > 0.27 && gap < 1.2 { ibis.append(gap); if ibis.count > 12 { ibis.removeFirst() } }
            if ibis.count >= 4 {
                let s = ibis.sorted(), med = s[s.count / 2]
                let close = ibis.filter { abs($0 - med) < med * 0.12 }.count
                period = close >= ibis.count * 2 / 3 ? med : 0 // only trust a steady beat
            }
        }
        lastHit = now
        let kind = e > mean + 3.5 * dev && e > slow * 2.2 ? 2 : (e < slow * 1.2 ? 0 : 1)
        if period > 0 {
            nextAt = now + period // the predictor fires from here on, on time
            if now - lastFire > period * 0.6 { fire(now, kind) } // first beat after a gap: show it now
        } else {
            fire(now, kind)
        }
    }

    // the predictor: fires each beat early by the Peak's own delay, so the light lands on it
    private func tick() {
        guard on, period > 0, nextAt > 0 else { return }
        let now = CACurrentMediaTime()
        if now - lastHit > period * 8 { period = 0; nextAt = 0; return } // the beat stopped (break, song change)
        if now >= nextAt - latency {
            fire(now, level < 0.25 ? 0 : 1)
            nextAt += period
        }
    }

    private func fire(_ now: Double, _ kind: Int) {
        guard now - lastFire > 0.2 else { return }
        lastFire = now
        count += 1
        beatNow = true
        if style == "drops" && kind < 2 { return }
        if style == "bars" && count % 4 != 1 && kind < 2 { return }
        guard idle(), !blobs.isEmpty else { return }
        if kind != 2 { idx = (idx + 1) % blobs.count }
        // never a light per beat: rewriting the light file several times a second made Peaks flash white and reboot.
        // The page writes one tempo-matched mood (rarely); with the app closed the Peak keeps playing the last one
        if tracker?.owning == true { return }
        onBeat?(idx, kind)
    }

    private func meter(_ now: Double) {
        guard now - lastMeter > 0.066 else { return } // ~15 a second for the visualizer
        lastMeter = now
        onMeter?(Double(level), period > 0 ? Int((60 / period).rounded()) : 0, beatNow)
        beatNow = false
    }

    func stop() {
        guard on else { return }
        ticker?.invalidate(); ticker = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        on = false
        if tracker?.owning == true { tracker?.musicClear(api2: api2) } else { onBeat?(-1, 0) } // put the light back
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        onChange?(false, "")
    }
}
