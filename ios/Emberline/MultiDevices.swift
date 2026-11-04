import Foundation
import CoreBluetooth

// Up to 3 Puffcos at once. The page talks to one of them (the one on screen). The others stay connected here, each
// with its own tracker (BackgroundTracker with devId set), app open or closed: sessions, hits and blinkers count,
// and the blinker Disco and the end-of-session warning play on that device. Switching on the page is instant,
// because the device is already connected and unlocked.
// The page turns this on with the "multi" message (window.EMBER_APP.post('multi', ...)); without it nothing changes.
final class MultiDevices {
    static let limit = 3
    weak var bridge: BLEBridge?
    var deliver: ((String, @escaping (Bool) -> Void) -> Void)? // runs JS on the page; true if the page took it

    struct Dev { let id: UUID; var name: String; var proxy: Bool; var api: Int; var ctx: BackgroundTracker.Ctx }
    private(set) var on = false
    private(set) var devs: [Dev] = []
    private var trackers: [UUID: BackgroundTracker] = [:]
    private var keepNext: UUID?          // the page is switching away from this one: keep it connected
    private var outbox: [[String: Any]] = [] // finished sessions from side devices, until the page has them
    private var timer: Timer?

    init() {
        if let saved = UserDefaults.standard.array(forKey: "multiOutbox") as? [[String: Any]] { outbox = saved }
    }

    // MARK: - from the page

    func configure(_ b: [String: Any]) {
        if let k = b["keep"] as? String { keepNext = UUID(uuidString: k); return }
        let wasOn = on
        on = b["on"] as? Bool ?? false
        var list: [Dev] = []
        let fx = b["fx"] as? [String: [String: Any]] ?? [:]
        for d in (b["devs"] as? [[String: Any]] ?? []).prefix(MultiDevices.limit) {
            guard let s = d["id"] as? String, let u = UUID(uuidString: s) else { continue }
            let proxy = d["proxy"] as? Bool ?? false, api = d["api"] as? Int ?? 3
            var c = BackgroundTracker.Ctx()
            c.proxy = proxy; c.api = api; c.name = d["name"] as? String ?? (proxy ? "Proxy" : "Peak")
            c.blk = b["blk"] as? Double ?? 8
            if let col = d["color"] as? String { c.color = col }
            // light effects for this kind of device (the page made them). None for the original Peak: it takes another format
            if api != 2, let f = fx[proxy ? "proxy" : "peak"] {
                let bytes = { (k: String) -> [UInt8]? in (f[k] as? String).flatMap { Data(base64Encoded: $0) }.map { [UInt8]($0) } }
                c.disco = bytes("disco"); c.warn = bytes("warn"); c.warnSecs = f["warnSecs"] as? Double ?? 15
            }
            list.append(Dev(id: u, name: c.name, proxy: proxy, api: api, ctx: c))
        }
        devs = list
        for (_, t) in trackers { if let d = devs.first(where: { $0.id == t.devId }) { t.ctx.disco = d.ctx.disco; t.ctx.warn = d.ctx.warn; t.ctx.warnSecs = d.ctx.warnSecs; t.ctx.name = d.name; t.ctx.blk = d.ctx.blk } }
        if on && timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sync() }
        }
        if !on && wasOn { stopAll() }
        sync()
    }

    // MARK: - for the bridge

    func wants(_ u: UUID) -> Bool { on && devs.contains { $0.id == u } }
    func tracker(_ u: UUID) -> BackgroundTracker? { trackers[u] }
    var anyConnected: Bool { trackers.keys.contains { bridge?.isConnected($0) == true } }

    // the page let go of a device. True: it's one of yours and stays connected here
    func pageLetGo(_ u: UUID) -> Bool {
        guard keepNext == u, wants(u) else { return false }
        keepNext = nil
        start(u, fromPage: true)
        return true
    }

    // the page wants this device: stop tracking it here and hand over what happened
    func pageTakes(_ u: UUID) {
        guard let t = trackers.removeValue(forKey: u) else { return }
        let out = t.release()
        if let o = out["open"] { send(["type": "open", "dev": u.uuidString, "open": o]) }
    }

    // MARK: - the loop

    private func start(_ u: UUID, fromPage: Bool) {
        guard trackers[u] == nil, let d = devs.first(where: { $0.id == u }), let br = bridge else { return }
        let t = BackgroundTracker()
        t.bridge = br; t.devId = u
        t.onFinished = { [weak self] done in
            var s = done; s["dev"] = u.uuidString
            self?.outbox.append(s); self?.saveOutbox(); self?.flush()
        }
        trackers[u] = t
        t.takeOver(d.ctx, authed: fromPage)
        // already connected (the page just let go of it, or it came back by itself): make sure it's listening
        if let p = br.peripheral(u), p.state == .connected { t.servicesReady(p) }
    }

    func sync() {
        guard on, let br = bridge else { return }
        let active = br.activeId
        for d in devs where d.id != active {
            if trackers[d.id] == nil { start(d.id, fromPage: false) }
            br.standingConnect(d.id)
        }
        // devices that left the list (or became the one on screen) stop here
        for u in Array(trackers.keys) where !devs.contains(where: { $0.id == u }) {
            _ = trackers.removeValue(forKey: u)?.release()
            br.letGo(u)
        }
        if !br.away { send(["type": "status", "devs": trackers.values.map { $0.status }]) }
        flush()
    }

    private func stopAll() {
        timer?.invalidate(); timer = nil
        for (u, t) in trackers { _ = t.release(); bridge?.letGo(u) }
        trackers = [:]
        if bridge?.away == false { send(["type": "status", "devs": []]) }
    }

    // MARK: - to the page

    private func saveOutbox() { UserDefaults.standard.set(outbox.suffix(100).map { $0 }, forKey: "multiOutbox") }

    func flush() {
        guard !outbox.isEmpty, bridge?.away == false else { return }
        let batch = outbox
        send(["type": "sessions", "sessions": batch]) { [weak self] ok in
            guard let self = self, ok else { return }
            self.outbox.removeFirst(min(batch.count, self.outbox.count)); self.saveOutbox()
        }
    }

    private func send(_ o: [String: Any], _ done: ((Bool) -> Void)? = nil) {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8),
              let q = try? JSONSerialization.data(withJSONObject: [s]), let qs = String(data: q, encoding: .utf8) else { done?(false); return }
        let arg = String(qs.dropFirst().dropLast()) // a JSON string inside a JS string
        deliver?("window.emberSide ? (window.emberSide(\(arg)), 1) : 0") { done?($0) }
    }
}
