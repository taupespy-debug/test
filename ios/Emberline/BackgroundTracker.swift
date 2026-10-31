import Foundation
import CoreBluetooth
import CryptoKit
import QuartzCore

// Tracks sessions while the app is in the background, so they still count for RP and blinkers.
// The page can't run then (iOS freezes it), so this talks to the Peak itself over the same LoRaX link:
// it reads the state, times the hits the same way the page does, and hands finished sessions back to the
// page when the app opens again (window.emberBgResume). It also plays the page's light effects on the Peak
// (preheat light, blinker Disco, the end-of-session warning flash) and the Torch dab taper, with the exact light
// data the page gave it (Ctx.fx), so the Peak acts the same with the app closed.
final class BackgroundTracker {
    weak var bridge: BLEBridge?

    // what the page told us before it froze (window.emberBgPause / the heartbeat)
    struct Ctx {
        var proxy = false; var api = 3; var open: [String: Any]? = nil
        var name = "Session"; var color = "#8a2bff"; var targetF = 0; var blk = 8.0 // for the Live Activity and the blinker ping
        var p = 0                       // active profile
        var preheat: [UInt8]? = nil     // light while heating (page's preheat color or mood)
        var disco: [UInt8]? = nil       // light for 10s after a blinker
        var warn: [UInt8]? = nil        // warning flash color near the end
        var warnSecs = 15.0
        var back: [UInt8]? = nil        // original Peak: the profile color to flash back to
        var torch: (s: Double, e: Double, profC: Double, te: Double)? = nil // Torch dab: start / end °F, profile temp °C, how far along the curve
    }
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
    private var endsAt: Date?          // when Ready ends, from the Peak's own timer
    private var lastTimerRead = 0.0
    private var timerStep = 0          // 0: read elapsed next, 1: read total
    private var elapRead = 0.0
    private var shownHits = 0
    // light effects and Torch dab
    private var ledJobs: [() async -> Void] = []
    private var ledRunning = false
    private var discoOn = false
    private var preheatSaved: [UInt8]?
    private var warnDone = false
    private var tempC = 0.0, tcmdC = 0.0, lastTemp = 0.0
    private var torchTe = 0.0, torchLast = 0.0, torchSent = -1.0, torchAt = 0.0

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
        finished = []; hit = HitCounter(); cur = nil; shownHits = 0; endsAt = nil
        ledJobs = []; discoOn = false; preheatSaved = nil; warnDone = false; torchTe = c.torch?.te ?? 0; torchSent = -1; torchAt = 0; torchLast = 0
        if let o = c.open, let t = o["t"] as? Double {
            // carry on the session the page was in the middle of
            var s = Sess(t: Date(timeIntervalSince1970: t / 1000), p: o["p"] as? Int ?? 0)
            if let r = o["readyAt"] as? Double, r > 0 { s.readyAt = Date(timeIntervalSince1970: r / 1000); lastState = 8 } else { lastState = 7 }
            s.setF = o["setF"] as? Int ?? 0
            s.seed = o
            hit.hits = (o["hits"] as? [Double]) ?? []
            hit.ends = ((o["ends"] as? [Double]) ?? []).map { Date(timeIntervalSince1970: $0 / 1000) }
            hit.lastSt = lastState; hit.armed = true
            cur = s; shownHits = hit.hits.count
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.16, repeats: true) { [weak self] _ in self?.tick() }
    }

    // the app is open again: stop, and give the page what happened
    func release() -> [String: Any] {
        guard owning else { return ["sessions": [Any]()] }
        owning = false
        timer?.invalidate(); timer = nil
        preheatRestore() // the page takes over from here: don't leave the preheat light on
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

    // MARK: - commands (Siri and Shortcuts)

    enum Command { case start, stop, boost }
    enum CommandResult { case ok, notConnected, proxyBoost, failed }

    // the same writes the page's Start / Stop / Boost buttons do (/p/app/mc)
    func command(_ c: Command, _ done: @escaping (CommandResult) -> Void) {
        guard linkChars() != nil else { return done(.notConnected) }
        if c == .boost && ctx.proxy { return done(.proxyBoost) } // a Proxy boosts by raising the temp offset, which needs the profile: the app does that
        let code: UInt8 = c == .start ? 7 : c == .stop ? 8 : 9
        let go = { [weak self] in
            guard let self = self else { return done(.failed) }
            self.write("/p/app/mc", [code]) { r in
                guard case .success = r else { return done(.failed) }
                if c == .stop && self.ctx.proxy { // a Proxy also wants 2 after stop, like the page does
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.write("/p/app/mc", [2]) { _ in done(.ok) } }
                } else { done(.ok) }
            }
        }
        if authed { go() } else { unlock { [weak self] ok in self?.authed = ok; ok ? go() : done(.failed) } }
    }

    private func write(_ path: String, _ bytes: [UInt8], _ done: @escaping (Result<[UInt8], Error>) -> Void) {
        run(0x11, [0, 0, 0] + Array(path.utf8) + [0] + bytes, done)
    }

    // MARK: - light effects (same steps as the page's phStart / bigHit / flashHeatCycle)

    // one light job at a time, with the state polling paused while it writes (the page queues them the same way)
    private func led(_ job: @escaping () async -> Void) {
        ledJobs.append(job); pumpLed()
    }
    private func pumpLed() {
        guard !ledRunning, !ledJobs.isEmpty else { return }
        ledRunning = true
        let job = ledJobs.removeFirst()
        Task { @MainActor [weak self] in
            var waited = 0
            while self?.busy == true && waited < 100 { try? await Task.sleep(nanoseconds: 20_000_000); waited += 1 }
            self?.busy = true
            await job()
            self?.busy = false
            self?.ledRunning = false
            self?.pumpLed()
        }
    }
    private func pause(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    // the light the Peak is showing for this session, so it can be put back
    private func savedLight() async -> [UInt8]? {
        if let r = try? await readAll("/p/app/thc/colr"), r.count > 8 { return r }
        if let r = try? await readAll("/u/app/hc/\(ctx.p)/colr"), r.count > 8 { return r }
        return nil
    }
    private func showLight(_ blob: [UInt8]) async throws {
        if ctx.proxy, (try? await writeA("/p/app/thc/colr", blob, flags: 4)) != nil { return } // a Proxy takes it in one go
        try await writeBlob("/p/app/thc/colr", blob)
    }

    private func preheatStart() {
        guard let ph = ctx.preheat, ctx.api != 2, preheatSaved == nil else { return } // the original Peak does its own preheat light
        led { [weak self] in
            guard let self = self, let saved = await self.savedLight(), self.lastState == 7 else { return }
            if (try? await self.showLight(ph)) != nil { self.preheatSaved = saved }
        }
    }
    private func preheatRestore() {
        guard let saved = preheatSaved else { return }
        preheatSaved = nil
        led { [weak self] in _ = try? await self?.showLight(saved) }
    }

    private func discoBlinker() {
        guard let blob = ctx.disco, !discoOn, lastState >= 7 && lastState <= 9 else { return }
        discoOn = true
        led { [weak self] in
            guard let self = self else { return }
            if self.ctx.api == 2 {
                for p in ["colr", "phcl", "accl"] { _ = try? await self.writeA("/p/app/thc/\(p)", blob) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    self?.led { [weak self] in
                        guard let self = self else { return }
                        if let back = self.ctx.back { for p in ["colr", "phcl", "accl"] { _ = try? await self.writeA("/p/app/thc/\(p)", back) } }
                        self.discoOn = false
                    }
                }
                return
            }
            guard let saved = await self.savedLight(), (try? await self.showLight(blob)) != nil else { self.discoOn = false; return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                self?.led { [weak self] in _ = try? await self?.showLight(saved); self?.discoOn = false }
            }
        }
    }

    private func warnFlash() {
        guard let on = ctx.warn, !discoOn else { return }
        led { [weak self] in
            guard let self = self else { return }
            if self.ctx.api == 2 {
                guard let back = self.ctx.back else { return }
                for _ in 0..<2 { _ = try? await self.writeA("/p/app/thc/colr", on); await self.pause(380); _ = try? await self.writeA("/p/app/thc/colr", back); await self.pause(260) }
                return
            }
            guard let saved = await self.savedLight() else { return }
            for _ in 0..<2 { _ = try? await self.showLight(on); await self.pause(420); _ = try? await self.showLight(saved); await self.pause(300) }
        }
    }

    // Torch dab: hot start, then cools like quartz; pulling cools it faster. The same curve as torchTargetF in the page
    private func torchStep(_ now: Double) -> Bool {
        guard let t = ctx.torch, lastState == 7 || lastState == 8, now - torchAt >= 1 else { return false }
        torchAt = now
        var want = t.s
        if lastState == 8 {
            if torchLast == 0 { torchLast = now }
            torchTe += (now - torchLast) * (hit.on ? 1.8 : 1); torchLast = now
            let total = endsAt.map { max(10, $0.timeIntervalSince(cur?.readyAt ?? Date())) } ?? 45
            let span = max(10, total - 4)
            want = torchTe <= 4 ? t.s : t.e + (t.s - t.e) * exp(-3 * (torchTe - 4) / span)
        } else { torchLast = 0 }
        want = want.rounded()
        if torchSent >= 0 && (abs(torchSent - want) < 3 && want != t.e || torchSent == want) { return false }
        let off = (want - 32) * 5 / 9 - t.profC
        guard off.isFinite, abs(off) <= 150 else { return false }
        torchSent = want
        // the live temp offset: a Peak takes a float, a Proxy tenths of a degree as a whole number
        let bytes: [UInt8]
        if ctx.proxy { let i = Int32((off * 10).rounded()); bytes = withUnsafeBytes(of: i.littleEndian) { Array($0) } }
        else { let f = Float(off); bytes = withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) } }
        led { [weak self] in _ = try? await self?.writeA("/p/app/tmpo", bytes) }
        return true
    }

    // MARK: - LoRaX, async (for the light jobs)

    private func runA(_ op: UInt8, _ body: [UInt8], timeout: Double = 3) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { cont in run(op, body, timeout: timeout) { cont.resume(with: $0) } }
    }
    private func writeA(_ path: String, _ bytes: [UInt8], flags: UInt8 = 0) async throws -> [UInt8] {
        try await runA(0x11, [0, 0, flags] + Array(path.utf8) + [0] + bytes)
    }
    private func readAll(_ path: String) async throws -> [UInt8] {
        var out: [UInt8] = []
        while out.count < 4096 {
            let off = out.count
            let chunk = try await runA(0x10, [UInt8(off & 0xff), UInt8(off >> 8), 125, 0] + Array(path.utf8))
            out += chunk
            if chunk.count < 125 { break }
        }
        return out
    }
    // a light file: fits in one message, or open / write the pieces / close (the Peak applies it on close)
    private func writeBlob(_ path: String, _ blob: [UInt8]) async throws {
        let pl = Array(path.utf8), room = 128 - (6 + pl.count + 1)
        if blob.count <= room, (try? await writeA(path, blob, flags: 4)) != nil { return }
        var handle: Int? = nil
        for fl: UInt8 in [4, 5, 0] {
            if let r = try? await runA(0x20, [fl] + pl), r.count >= 2 { handle = Int(r[0]) | Int(r[1]) << 8; break }
        }
        guard let h = handle else { throw TrackErr.status(0xff) }
        let step = 128 - 3 - 4
        var off = 0
        var failed: Error? = nil
        while off < blob.count {
            let piece = Array(blob[off..<min(off + step, blob.count)])
            do { _ = try await runA(0x22, [UInt8(h & 0xff), UInt8(h >> 8), UInt8(off & 0xff), UInt8(off >> 8)] + piece) } catch { failed = error; break }
            off += step
        }
        _ = try? await runA(0x26, [UInt8(h & 0xff), UInt8(h >> 8)])
        if let e = failed { throw e }
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
        // the Peak's own countdown while Ready (for the Live Activity), every 5s, while not pulling
        if lastState == 8 && !hit.on && now - lastTimerRead >= 5 {
            busy = true
            let path = timerStep == 0 ? "/p/app/stat/elap" : "/p/app/stat/tott"
            read(path, 4) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                guard case .success(let b) = r else { self.lastTimerRead = CACurrentMediaTime(); self.timerStep = 0; return }
                let v = self.number(b, scale: 200)
                if self.timerStep == 0 { self.elapRead = v; self.timerStep = 1 }
                else {
                    self.timerStep = 0; self.lastTimerRead = CACurrentMediaTime()
                    if v > 0 && v < 600 && self.elapRead >= 0 { self.endsAt = Date().addingTimeInterval(max(0, v - self.elapRead)); self.emitLive() }
                }
            }
            return
        }
        // preheat light: put the profile light back a few degrees before Ready (like the page), so it's done when Ready lands
        if lastState == 7 && preheatSaved != nil && now - lastTemp >= 1 {
            busy = true; lastTemp = now
            read("/p/app/htr/temp", 4) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                if case .success(let b) = r { let t = self.number(b, scale: 10); if t.isFinite { self.tempC = t } }
                if self.tcmdC > 100 && self.tempC >= self.tcmdC - 6 { self.preheatRestore() }
            }
            return
        }
        // the end-of-session warning: flash once when the time left drops under the warning time (boost re-arms it)
        if lastState == 8, let e = endsAt {
            let left = e.timeIntervalSinceNow
            if left > ctx.warnSecs + 1.5 { warnDone = false }
            else if !warnDone && left > 0 {
                warnDone = true
                warnFlash()
                if owning { Notify.shared.send("\(Int(ctx.warnSecs.rounded())) seconds left", "Finish your hit 🔥", id: "warn") }
            }
        }
        if torchStep(now) { return }
        // the temp the Peak really heated to (the 450°F rule), about once a second while not pulling
        if !hit.on && now - lastTcmd >= 1 {
            busy = true; lastTcmd = now
            read("/p/app/htr/tcmd", 4) { [weak self] r in
                guard let self = self else { return }
                self.busy = false
                if case .success(let b) = r { let t = self.number(b, scale: 10); if t > 100 && t < 400 { self.tcmdC = t; if var c = self.cur { c.setF = max(c.setF, Int((t * 9 / 5 + 32).rounded())); self.cur = c } } }
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
                self.hitsChanged()
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
            preheatStart()
            torchTe = 0; torchSent = -1; torchAt = 0
            cur = Sess(t: now, p: 0)
            hit = HitCounter()
            read("/p/app/hcs", 1) { [weak self] r in if case .success(let b) = r, let i = b.first, i <= 3 { self?.cur?.p = Int(i) } }
        }
        if st == 8 && prev != 8 && prev != 7 && prev != 9 && cur?.readyAt == nil { hit = HitCounter() }
        if st == 8 && cur == nil { cur = Sess(t: now, p: 0) } // already Ready when we started watching
        if st == 8 && cur != nil && cur?.readyAt == nil { cur?.readyAt = now }
        if st != 8 { hit.sample(0, now: CACurrentMediaTime(), state: st, wall: now) } // not Ready: close any open hit
        if prev == 7 && st != 7 { preheatRestore() }
        if st == 8 && prev != 8 {
            endsAt = nil; lastTimerRead = 0; timerStep = 0; warnDone = false
            if owning { Notify.shared.send("Ready to dab", "\(ctx.name)\(ctx.targetF > 0 ? " at \(ctx.targetF)°F" : "") is ready.", id: "ready") }
        }
        if st == 9 || st <= 6 { endSession(now) }
        if st != prev { emitLive() }
    }

    // a hit just ended: update the Live Activity, and ping for a blinker
    private func hitsChanged() {
        guard hit.hits.count != shownHits else { return }
        if hit.hits.count > shownHits, let h = hit.hits.last, h >= ctx.blk, owning {
            discoBlinker()
            Notify.shared.send("Blinker! 🔥", String(format: "%.1f second hit. It counts when you open Emberline.", h), id: "blinker")
        }
        shownHits = hit.hits.count
        emitLive()
    }

    // the session on the lock screen and in the Dynamic Island while the app is closed
    private func emitLive() {
        guard owning else { return }
        let st = lastState
        let phase = st == 7 ? "heat" : st == 8 ? "ready" : (cur == nil && st >= 0 ? "done" : "idle")
        var d: [String: Any] = ["phase": phase, "name": ctx.name, "color": ctx.color, "tempF": cur?.setF ?? ctx.targetF, "targetF": max(ctx.targetF, cur?.setF ?? 0),
                                "hits": hit.hits.count, "lastHit": hit.hits.last ?? 0, "best": hit.hits.max() ?? 0, "blinker": (hit.hits.last ?? 0) >= ctx.blk]
        if let r = cur?.readyAt { d["readyAt"] = r.timeIntervalSince1970 * 1000 }
        if let e = endsAt { d["endsAt"] = e.timeIntervalSince1970 * 1000 }
        if phase == "done", let f = finished.last { d["hits"] = (f["hits"] as? [Double])?.count ?? 0; d["best"] = (f["hits"] as? [Double])?.max() ?? 0 }
        LiveSession.shared.handle(d)
    }

    private func endSession(_ now: Date) {
        guard let c = cur else { return }
        cur = nil
        hit.close(at: CACurrentMediaTime(), wall: now)
        let ranFor = c.readyAt.map { now.timeIntervalSince($0) } ?? 0
        let gotHit = hit.hits.contains { $0 >= 1 }
        if c.readyAt != nil && (ranFor >= 20 || gotHit) {
            finished.append(sessDict(c, end: now))
            if owning {
                let n = hit.hits.count, best = hit.hits.max() ?? 0
                Notify.shared.send("Session tracked", n == 0 ? "No hits this time. It counts when you open Emberline." : "\(n) hit\(n == 1 ? "" : "s"), best \(String(format: "%.1f", best))s. It counts when you open Emberline.", id: "sess-\(Int(c.t.timeIntervalSince1970))")
            }
        }
        hit = HitCounter(); shownHits = 0; endsAt = nil
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
