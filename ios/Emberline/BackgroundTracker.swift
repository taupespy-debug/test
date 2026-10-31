import Foundation
import CoreBluetooth
import CryptoKit
import QuartzCore

// Tracks sessions while the app is in the background, so they still count for RP and blinkers.
// The page can't run then (iOS freezes it), so this talks to the Peak itself over the same LoRaX link:
// it reads the state, times the hits the same way the page does, and hands finished sessions back to the
// page when the app opens again (window.emberBgResume). It only reads. The one exception is unlocking a link
// it had to reconnect itself, which is the same handshake the page does.
final class BackgroundTracker {
    weak var bridge: BLEBridge?

    // what the page told us before it froze (window.emberBgPause / the heartbeat)
    struct Ctx { var proxy = false; var api = 3; var open: [String: Any]? = nil }
    var ctx = Ctx()

    private(set) var owning = false
    private var timer: Timer?
    private var busy = false
    private var authed = true // the page unlocked the link it made; a link we reconnect ourselves needs unlocking again
    private var seq: UInt16 = 0xC000
    private var pending: [UInt16: (Result<[UInt8], Error>) -> Void] = [:]

    private var lastState = -1
    private var lastStateRead = 0.0
    private var lastTcmd = 0.0
    private var lastDia = 0.0
    private var dia = 1.0
    private var hitOK = true
    private var cur: Sess?
    private var hit = HitCounter()
    private(set) var finished: [[String: Any]] = []

    struct Sess {
        var t: Date
        var p: Int
        var readyAt: Date?
        var setF = 0
        var seed: [String: Any]? // the page's own unfinished session, if it had one
    }

    enum TrackErr: Error { case down, timeout, status(UInt8) }

    // MARK: - taking over and handing back

    func takeOver(_ c: Ctx) {
        guard !owning else { return }
        ctx = c; owning = true; busy = false
        authed = bridge?.isConnected(bridge?.activeId) ?? false // a link the page made is already unlocked
        lastState = -1; lastStateRead = 0; hitOK = c.api != 2 // the original Peak times hits from the heater: sessions still count, hits don't
        finished = []; hit = HitCounter(); cur = nil
        if let o = c.open, let t = o["t"] as? Double {
            // carry on the session the page was in the middle of
            var s = Sess(t: Date(timeIntervalSince1970: t / 1000), p: o["p"] as? Int ?? 0)
            if let r = o["readyAt"] as? Double, r > 0 { s.readyAt = Date(timeIntervalSince1970: r / 1000); lastState = 8 } else { lastState = 7 }
            s.setF = o["setF"] as? Int ?? 0
            s.seed = o
            hit.hits = (o["hits"] as? [Double]) ?? []
            hit.ends = ((o["ends"] as? [Double]) ?? []).map { Date(timeIntervalSince1970: $0 / 1000) }
            hit.lastSt = lastState; hit.armed = true
            cur = s
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in self?.tick() }
    }

    // the app is open again: stop, and give the page what happened
    func release() -> [String: Any] {
        guard owning else { return ["sessions": [Any]()] }
        owning = false
        timer?.invalidate(); timer = nil
        for (_, done) in pending { done(.failure(TrackErr.down)) }
        pending = [:]
        var out: [String: Any] = ["sessions": finished, "owned": true]
        if let c = cur {
            hit.close(at: CACurrentMediaTime(), wall: Date()) // a pull still going when you open the app counts up to now
            out["open"] = sessDict(c, end: nil)
        }
        finished = []; cur = nil
        return out
    }

    // MARK: - link events from the bridge

    func linkDropped(_ u: UUID) {
        guard u == bridge?.activeId else { return }
        authed = false
        for (_, done) in pending { done(.failure(TrackErr.down)) }
        pending = [:]; busy = false
        // a Peak that drops out mid-session (asleep, out of range) has finished it
        if owning { endSession(Date()) ; lastState = -1 }
    }

    // a link we reconnected while the app was closed: find the LoRaX service, then listen for replies
    func servicesReady(_ p: CBPeripheral) {
        guard owning, p.identifier == bridge?.activeId, let svc = p.services?.first(where: { $0.uuid == LORAX_SVC }) else { return }
        if svc.characteristics == nil { p.discoverCharacteristics([LORAX_CMD, LORAX_REPLY], for: svc) }
        else { characteristicsReady(p, svc) }
    }
    func characteristicsReady(_ p: CBPeripheral, _ svc: CBService) {
        guard owning, svc.uuid == LORAX_SVC, p.identifier == bridge?.activeId,
              let rep = svc.characteristics?.first(where: { $0.uuid == LORAX_REPLY }) else { return }
        if !rep.isNotifying { p.setNotifyValue(true, for: rep) }
    }

    // a reply from the Peak: ours if the sequence number is one we're waiting on
    func takeReply(_ v: Data) -> Bool {
        let b = [UInt8](v)
        guard b.count >= 3 else { return false }
        let s = UInt16(b[0]) | UInt16(b[1]) << 8
        guard let done = pending.removeValue(forKey: s) else { return false }
        if b[2] == 0 { done(.success(Array(b[3...]))) } else { done(.failure(TrackErr.status(b[2]))) }
        return true
    }

    // MARK: - LoRaX (same as the page's Lorax class)

    private func linkChars() -> (CBPeripheral, CBCharacteristic)? {
        guard let br = bridge, let u = br.activeId, let p = br.peripheral(u), p.state == .connected,
              let cmd = br.findChar(p, LORAX_SVC, LORAX_CMD), let rep = br.findChar(p, LORAX_SVC, LORAX_REPLY), rep.isNotifying else { return nil }
        return (p, cmd)
    }

    private func run(_ op: UInt8, _ body: [UInt8], timeout: Double = 3, _ done: @escaping (Result<[UInt8], Error>) -> Void) {
        guard let pc = linkChars() else { return done(.failure(TrackErr.down)) }
        let (p, cmd) = pc
        seq = seq >= 0xFFF0 ? 0xC000 : seq + 1
        let s = seq
        pending[s] = done
        let msg = Data([UInt8(s & 0xff), UInt8(s >> 8), op] + body)
        p.writeValue(msg, for: cmd, type: cmd.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            if let d = self?.pending.removeValue(forKey: s) { d(.failure(TrackErr.timeout)) }
        }
    }

    private func read(_ path: String, _ size: Int, _ done: @escaping (Result<[UInt8], Error>) -> Void) {
        let p = Array(path.utf8)
        run(0x10, [0, 0, UInt8(size & 0xff), UInt8(size >> 8)] + p, done)
    }

    private static let master: [UInt8] = [0x64, 0xc6, 0x45, 0x62, 0x56, 0xf2, 0x6f, 0x5b, 0x1c, 0xa1, 0x27, 0x37, 0xa5, 0xdd, 0x71, 0xfb]
    private func unlock(_ done: @escaping (Bool) -> Void) {
        run(0x00, [], timeout: 6) { [weak self] r in
            guard let self = self, case .success(let seed) = r, seed.count >= 16 else { return done(false) }
            let digest = Array(SHA256.hash(data: BackgroundTracker.master + Array(seed[0..<16])))
            self.run(0x01, Array(digest[0..<16])) { r2 in if case .success = r2 { done(true) } else { done(false) } }
        }
    }

    // numbers: a Peak sends 32-bit floats, a Proxy sends some as whole numbers with a scale (see intScale in the page)
    private func number(_ b: [UInt8], scale: Double) -> Double {
        if b.count < 4 { return b.count >= 2 ? Double(UInt16(b[0]) | UInt16(b[1]) << 8) : Double(b.first ?? 0) }
        let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        let f = Float(bitPattern: bits)
        if f.isNaN && (!ctx.proxy || bits & 0x7fffffff == 0x7fc00000) { return .nan }
        if bits != 0 && (!f.isFinite || abs(f) < 1e-20) {
            let i = Int32(bitPattern: bits)
            return i == Int32.min ? 0 : Double(i) / scale
        }
        return Double(f)
    }

    // MARK: - the loop

    private func tick() {
        guard owning, !busy else { return }
        guard bridge?.isConnected(bridge?.activeId) == true, linkChars() != nil else { return }
        if !authed {
            busy = true
            unlock { [weak self] ok in self?.authed = ok; self?.busy = false }
            return
        }
        let now = CACurrentMediaTime()
        let heating = lastState == 7 || lastState == 8
        // the state twice a second while heating, every 1.5s otherwise
        if now - lastStateRead >= (heating ? 0.5 : 1.5) {
            busy = true; lastStateRead = now
            read("/p/app/stat/id", 1) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                if case .success(let b) = r, let st = b.first { self.step(Int(st)) }
            }
            return
        }
        guard heating else { return }
        // the temp the Peak really heated to (the 450°F rule), about once a second while not pulling
        if !hit.on && now - lastTcmd >= 1 {
            busy = true; lastTcmd = now
            read("/p/app/htr/tcmd", 4) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                if case .success(let b) = r { let t = self.number(b, scale: 10); if t > 100 && t < 400 { self.cur?.setF = max(self.cur?.setF ?? 0, Int((t * 9 / 5 + 32).rounded())) } }
            }
            return
        }
        guard hitOK else { return }
        // Proxy: the inhale reading only counts while dynamic inhale is on (dia > 0), checked once a second
        if ctx.proxy && now - lastDia >= 1 {
            busy = true; lastDia = now
            read("/p/app/led/dia", 4) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                if case .success(let b) = r { self.dia = self.number(b, scale: 4096) } else { self.dia = 1 }
            }
            return
        }
        busy = true
        read("/p/app/led/dif", 4) { [weak self] r in
            guard let self = self else { return }
            self.busy = false
            switch r {
            case .success(let b):
                var v = self.number(b, scale: 4096)
                if !v.isFinite { return }
                if self.ctx.proxy && !(self.dia > 0) { v = 0 }
                self.hit.sample(min(max(v, 0), 1), now: CACurrentMediaTime(), state: self.lastState, wall: Date())
            case .failure(let e):
                if let te = e as? TrackErr, case .status(_) = te { self.hitOK = false } // this firmware has no inhale reading
            }
        }
    }

    // the same steps as trackSession in the page
    private func step(_ st: Int) {
        let prev = lastState; lastState = st
        let now = Date()
        if st == 7 && prev != 7 && cur == nil {
            cur = Sess(t: now, p: 0)
            hit = HitCounter()
            read("/p/app/hcs", 1) { [weak self] r in if case .success(let b) = r, let i = b.first, i <= 3 { self?.cur?.p = Int(i) } }
        }
        if st == 8 && prev != 8 && prev != 7 && prev != 9 && cur?.readyAt == nil { hit = HitCounter() }
        if st == 8 && cur == nil { cur = Sess(t: now, p: 0) } // already Ready when we started watching
        if st == 8 && cur != nil && cur?.readyAt == nil { cur?.readyAt = now }
        if st != 8 { hit.sample(0, now: CACurrentMediaTime(), state: st, wall: now) } // not Ready: close any open hit
        if st == 9 || st <= 6 { endSession(now) }
    }

    private func endSession(_ now: Date) {
        guard let c = cur else { return }
        cur = nil
        hit.close(at: CACurrentMediaTime(), wall: now)
        let ranFor = c.readyAt.map { now.timeIntervalSince($0) } ?? 0
        let gotHit = hit.hits.contains { $0 >= 1 }
        if c.readyAt != nil && (ranFor >= 20 || gotHit) { finished.append(sessDict(c, end: now)) }
        hit = HitCounter()
    }

    private func sessDict(_ c: Sess, end: Date?) -> [String: Any] {
        var d: [String: Any] = ["t": c.t.timeIntervalSince1970 * 1000, "p": c.p, "hits": Array(hit.hits.prefix(20))]
        if let r = c.readyAt {
            d["readyAt"] = r.timeIntervalSince1970 * 1000
            d["hitAt"] = hit.ends.prefix(20).map { (($0.timeIntervalSince(r)) * 10).rounded() / 10 }
            if let e = end { d["run"] = Int(e.timeIntervalSince(r).rounded()) }
        }
        if let e = end { d["end"] = e.timeIntervalSince1970 * 1000 }
        d["ends"] = hit.ends.map { $0.timeIntervalSince1970 * 1000 }
        if c.setF > 0 { d["setF"] = c.setF }
        if c.seed != nil { d["fromPage"] = true }
        return d
    }
}

// Hit timing, the same rules as hitSample in the page (inhale reading 0..1, with hysteresis)
struct HitCounter {
    var base = 0.03, on = false, start = 0.0, peak = 0.0, endAt = 0.0, lastStart = 0.0
    var hits: [Double] = []
    var ends: [Date] = []
    var same = 0, lastV = -1.0, sameAt = 0.0
    var pre: [Double] = []
    var preHigh: Bool? = nil
    var armed = false, readyT = 0.0, lastSt = -1

    mutating func sample(_ v0: Double, now: Double, state: Int, wall: Date) {
        var v = v0
        // a reading that sits on the exact same number for ~3s is frozen, not a pull
        if v > 0 && v < 0.9 && v == lastV { same += 1; if same >= 19 { v = 0 } } else { same = 0; lastV = v; sameAt = now }
        if on && v == 0 && same >= 19 { endAt = 0; close(at: sameAt, wall: wall); return }
        if on && now - start > 120 { endAt = 0; close(at: min(sameAt, start + 120), wall: wall); base = min(0.6, v); return } // stuck reading
        if !on { let b = base; if v < b + 0.05 { base = min(0.08, b * 0.9 + v * 0.1) } }
        let up = max(0.12, base + 0.1), down = max(0.06, base + 0.04)
        if state == 7 { pre.append(v); if pre.count > 6 { pre.removeFirst() } }
        if state == 8 && lastSt != 8 {
            armed = false; readyT = now
            let p = pre.suffix(3); preHigh = p.isEmpty ? nil : (p.max() ?? 0) >= up; pre = []
        }
        lastSt = state
        if state == 8 && !armed {
            if v < down { armed = true } // quiet: nobody's pulling, start timing from here
            else if preHigh == false && v >= up { armed = true; on = true; start = max(readyT - 0.25, now - 0.25); peak = v } // a pull that started right at Ready
            return
        }
        if state != 8 { if on { endAt = now; lastStart = start; close(at: now, wall: wall) }; return }
        if !on && v >= up && endAt > 0 && now - endAt < 0.7 && !hits.isEmpty {
            on = true; hits.removeLast(); if !ends.isEmpty { ends.removeLast() }; start = lastStart // a short dip: same hit
        } else if !on && v >= up {
            on = true; start = now - 0.25; peak = v
        } else if on {
            peak = max(peak, v)
            if v <= max(down, min(peak * 0.3, 0.15)) { endAt = now; lastStart = start; close(at: now, wall: wall) }
        }
    }

    mutating func close(at t: Double, wall: Date) {
        guard on else { return }
        on = false
        let secs = t - start
        if secs >= 0.5 { hits.append((secs * 10).rounded() / 10); ends.append(wall) }
    }
}
