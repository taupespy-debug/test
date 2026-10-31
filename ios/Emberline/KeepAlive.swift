import AVFoundation

// Keeps the app running in the background so the tracker can keep reading the Peak.
// It plays silence on a loop, mixed with whatever else is playing (Spotify keeps going, nothing shows on the lock screen).
final class KeepAlive {
    private var player: AVAudioPlayer?
    private(set) var running = false

    init() {
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            // a phone call or another app took the audio: start again once it's over
            guard let self = self, self.running,
                  let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self.running = false
            self.start()
        }
    }

    func start() {
        guard !running else { return }
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try s.setActive(true)
            if player == nil {
                player = try AVAudioPlayer(data: KeepAlive.silence())
                player?.numberOfLoops = -1
                player?.volume = 0.01
            }
            player?.play()
            running = true
        } catch {
            running = false
        }
    }

    func stop() {
        guard running else { return }
        player?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        running = false
    }

    // one second of silence as a WAV file (8 kHz, 16-bit, mono)
    private static func silence() -> Data {
        let rate: UInt32 = 8000, samples: UInt32 = 8000
        let dataBytes = samples * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataBytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }
}
