import Foundation
import CoreBluetooth
import UIKit
import WebKit

// The Bluetooth side of bridge.js: the page asks for devices, services and characteristics by id and uuid,
// and this does the real work with CoreBluetooth. Replies go back with window.__emberBle.reply(id, ok, payload).
// While the app is in the background, BackgroundTracker owns the link and nothing is sent to the page.
// Never touches the firmware update service (1d14d6ee...): it can turn a Peak off.

let LORAX_SVC = CBUUID(string: "e276967f-ea8a-478a-a92e-d78f5dd15dd5")
let LORAX_CMD = CBUUID(string: "60133d5c-5727-4f2c-9697-d842c5292a3c")
let LORAX_REPLY = CBUUID(string: "8dc5ec05-8f7d-45ad-99db-3fbde65dbd9c")
let PIKACHU_SVC = CBUUID(string: "06caf9c0-74d3-454f-9be9-e30cd999c17a")
let PUP_SVC = CBUUID(string: "420b9b40-457d-4abe-a3bf-71609d79581b")
let OTA_SVC = CBUUID(string: "1d14d6ee-fd63-4fa1-bfa4-8f47b42119f0")
let PUFFCO_COMPANY: UInt16 = 3075

// everything runs on the main queue (the central is created with queue: .main)
final class BLEBridge: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var web: WKWebView?
    weak var host: UIViewController?
    weak var tracker: BackgroundTracker?

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var names: [UUID: String] = [:]

    // page requests waiting on CoreBluetooth
    private var connectWaits: [UUID: [Int]] = [:]
    private var serviceWaits: [UUID: [(id: Int, svc: CBUUID)]] = [:]
    private var charWaits: [String: [(id: Int, ch: CBUUID)]] = [:]
    private var readWaits: [String: [Int]] = [:]
    private var writeWaits: [String: [Int]] = [:]
    private var notifyWaits: [String: [Int]] = [:]
    private var availWaits: [Int] = []
    private var noResponseQueue: [(p: CBPeripheral, c: CBCharacteristic, d: Data, id: Int)] = []

    // device picker / scan
    private var scanRequest: (id: Int, filters: [[String: Any]], all: Bool, auto: Bool)?
    private var scanTimer: Timer?
    private var picker: DevicePicker?

    // the Peak the page is using (the background tracker follows it)
    private(set) var activeId: UUID?
    private var manualClose: Set<UUID> = []
    private(set) var goneWhileAway: Set<UUID> = []
    var away = false // app in the background: page gets nothing, tracker owns the link
    var onAwayConnect: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    // MARK: - page calls

    func handle(_ body: [String: Any]) {
        let id = body["id"] as? Int ?? 0
        let op = body["op"] as? String ?? ""
        switch op {
        case "avail":
            if central.state == .unknown || central.state == .resetting { availWaits.append(id) }
            else { reply(id, true, ["on": central.state == .poweredOn]) }
        case "known": reply(id, true, ["list": knownList()])
        case "request": request(id, body["opts"] as? [String: Any] ?? [:])
        case "connect": connect(id, body["dev"] as? String)
        case "disconnect":
            if let u = uuid(body["dev"]), let p = peripherals[u] { manualClose.insert(u); central.cancelPeripheralConnection(p) }
        case "service": service(id, body)
        case "char": characteristic(id, body)
        case "read": read(id, body)
        case "write": write(id, body)
        case "notify": notify(id, body)
        default: reply(id, false, ["name": "NotSupportedError", "msg": "Unknown op \(op)"])
        }
    }

    private func uuid(_ v: Any?) -> UUID? { (v as? String).flatMap { UUID(uuidString: $0) } }
    private func key(_ p: CBPeripheral, _ c: CBCharacteristic) -> String { "\(p.identifier.uuidString)|\(c.service?.uuid.uuidString.lowercased() ?? "")|\(c.uuid.uuidString.lowercased())" }
    private func key(_ dev: String, _ svc: String, _ ch: String) -> String { "\(dev.uppercased())|\(CBUUID(string: svc).uuidString.lowercased())|\(CBUUID(string: ch).uuidString.lowercased())" }

    // a short uuid ("180a") and the full form both work, like the browser
    private func cbuuid(_ s: Any?) -> CBUUID? {
        if let n = s as? Int { return CBUUID(string: String(format: "%04X", n)) }
        guard let str = s as? String, !str.isEmpty else { return nil }
        return CBUUID(string: str)
    }

    func reply(_ id: Int, _ ok: Bool, _ payload: [String: Any] = [:]) {
        guard id > 0 else { return }
        js("window.__emberBle&&window.__emberBle.reply(\(id),\(ok),\(json(payload)))")
    }
    private func fail(_ id: Int, _ name: String, _ msg: String) { reply(id, false, ["name": name, "msg": msg]) }

    func js(_ s: String) { web?.evaluateJavaScript(s, completionHandler: nil) }
    private func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - remembered devices (getDevices)

    private func knownList() -> [[String: String]] {
        let saved = UserDefaults.standard.array(forKey: "knownDevices") as? [[String: String]] ?? []
        let ids = saved.compactMap { UUID(uuidString: $0["id"] ?? "") }
        for p in central.retrievePeripherals(withIdentifiers: ids) { adopt(p) }
        return saved.filter { UUID(uuidString: $0["id"] ?? "").map { peripherals[$0] != nil } ?? false }
    }
    private func remember(_ p: CBPeripheral) {
        var saved = UserDefaults.standard.array(forKey: "knownDevices") as? [[String: String]] ?? []
        saved.removeAll { $0["id"] == p.identifier.uuidString }
        saved.insert(["id": p.identifier.uuidString, "name": names[p.identifier] ?? p.name ?? "Peak"], at: 0)
        UserDefaults.standard.set(Array(saved.prefix(8)), forKey: "knownDevices")
    }
    private func adopt(_ p: CBPeripheral) {
        if peripherals[p.identifier] == nil { peripherals[p.identifier] = p }
        p.delegate = self
        if names[p.identifier] == nil, let n = p.name { names[p.identifier] = n }
    }

    // MARK: - requestDevice

    private func request(_ id: Int, _ opts: [String: Any]) {
        guard central.state == .poweredOn else { return fail(id, "NotFoundError", "Bluetooth is off.") }
        if scanRequest != nil { finishScan(nil) }
        let filters = opts["filters"] as? [[String: Any]] ?? []
        let all = opts["acceptAllDevices"] as? Bool ?? false
        // only a name and/or id (a reconnect): pick it with no list, like Path does
        let auto = !all && !filters.isEmpty && filters.allSatisfy { f in f.keys.allSatisfy { $0 == "name" || $0 == "deviceId" } }
        if auto {
            for f in filters {
                if let u = uuid(f["deviceId"]), let p = central.retrievePeripherals(withIdentifiers: [u]).first {
                    adopt(p); reply(id, true, ["id": p.identifier.uuidString, "name": names[u] ?? p.name ?? ""]); return
                }
            }
        }
        scanRequest = (id, filters, all, auto)
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        if auto {
            scanTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in self?.finishScan(nil) }
        } else {
            let pk = DevicePicker()
            pk.onPick = { [weak self] u in self?.finishScan(u) }
            pk.onCancel = { [weak self] in self?.finishScan(nil) }
            picker = pk
            host?.present(pk.wrapped(), animated: true)
        }
    }

    private func matches(_ p: CBPeripheral, _ adv: [String: Any]) -> Bool {
        guard let rq = scanRequest else { return false }
        let name = (adv[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if rq.all { return !name.isEmpty }
        let svcs = (adv[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []) + (adv[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        var company: UInt16? = nil
        if let m = adv[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 { company = UInt16(m[m.startIndex]) | UInt16(m[m.startIndex + 1]) << 8 }
        for f in rq.filters {
            var ok = true, any = false
            if let n = f["name"] as? String { any = true; ok = ok && name == n }
            if let n = f["namePrefix"] as? String { any = true; ok = ok && name.hasPrefix(n) }
            if let d = f["deviceId"] as? String { any = true; ok = ok && p.identifier.uuidString.caseInsensitiveCompare(d) == .orderedSame }
            if let ss = f["services"] as? [Any] { any = true; ok = ok && ss.compactMap { cbuuid($0) }.allSatisfy { svcs.contains($0) } }
            if let md = f["manufacturerData"] as? [[String: Any]] { any = true; ok = ok && md.contains { ($0["companyIdentifier"] as? Int).map { UInt16(truncatingIfNeeded: $0) == company } ?? false } }
            if any && ok { return true }
        }
        return false
    }

    private func finishScan(_ picked: UUID?) {
        guard let rq = scanRequest else { return }
        scanRequest = nil
        scanTimer?.invalidate(); scanTimer = nil
        if central.isScanning { central.stopScan() }
        if let pk = picker { picker = nil; pk.dismissSheet() }
        if let u = picked, let p = peripherals[u] {
            reply(rq.id, true, ["id": u.uuidString, "name": names[u] ?? p.name ?? ""])
        } else {
            fail(rq.id, "NotFoundError", "User cancelled the requestDevice() chooser.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData adv: [String: Any], rssi: NSNumber) {
        guard let rq = scanRequest, matches(p, adv) else { return }
        adopt(p)
        if let n = adv[CBAdvertisementDataLocalNameKey] as? String, !n.isEmpty { names[p.identifier] = n }
        if rq.auto { finishScan(p.identifier); return }
        picker?.add(id: p.identifier, name: names[p.identifier] ?? p.name ?? "Unknown", rssi: rssi.intValue)
    }

    // MARK: - connect

    private func connect(_ id: Int, _ dev: String?) {
        guard let u = uuid(dev) else { return fail(id, "NotFoundError", "Unknown device") }
        var p = peripherals[u]
        if p == nil, let r = central.retrievePeripherals(withIdentifiers: [u]).first { adopt(r); p = r }
        guard let per = p else { return fail(id, "NotFoundError", "Device not found") }
        manualClose.remove(u)
        activeId = u
        if per.state == .connected {
            // already up (the app reconnected it in the background): the page still needs the services found
            if per.services?.contains(where: { $0.uuid == LORAX_SVC }) == true { reply(id, true); return }
            connectWaits[u, default: []].append(id); per.discoverServices([LORAX_SVC, PIKACHU_SVC, PUP_SVC]); return
        }
        connectWaits[u, default: []].append(id)
        if per.state != .connecting { central.connect(per, options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        adopt(p); remember(p)
        if away { onAwayConnect?() }
        p.discoverServices([LORAX_SVC, PIKACHU_SVC, PUP_SVC]) // never the firmware update service
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let ids = connectWaits.removeValue(forKey: p.identifier) ?? []
        ids.forEach { fail($0, "NetworkError", error?.localizedDescription ?? "Connection failed") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let u = p.identifier
        (connectWaits.removeValue(forKey: u) ?? []).forEach { fail($0, "NetworkError", "Disconnected") }
        (serviceWaits.removeValue(forKey: u) ?? []).forEach { fail($0.id, "NetworkError", "Disconnected") }
        let pre = u.uuidString + "|"
        for k in charWaits.keys where k.hasPrefix(pre) { (charWaits.removeValue(forKey: k) ?? []).forEach { fail($0.id, "NetworkError", "Disconnected") } }
        for dict in [readWaits, writeWaits, notifyWaits] { for (k, ids) in dict where k.hasPrefix(pre) { ids.forEach { fail($0, "NetworkError", "Disconnected") } } }
        readWaits = readWaits.filter { !$0.key.hasPrefix(pre) }
        writeWaits = writeWaits.filter { !$0.key.hasPrefix(pre) }
        notifyWaits = notifyWaits.filter { !$0.key.hasPrefix(pre) }
        noResponseQueue.removeAll { $0.p.identifier == u }
        tracker?.linkDropped(u)
        let manual = manualClose.remove(u) != nil
        if away {
            goneWhileAway.insert(u)
            // the Peak fell asleep or walked out of range while the app is closed: wait for it to come back.
            // iOS keeps this connect pending and finishes it whenever the Peak shows up again
            if !manual && u == activeId { central.connect(p, options: nil) }
        } else {
            js("window.__emberBle&&window.__emberBle.gone(\(json([u.uuidString]).dropFirst().dropLast()))")
        }
    }

    // MARK: - services and characteristics

    private func service(_ id: Int, _ b: [String: Any]) {
        guard let u = uuid(b["dev"]), let p = peripherals[u], let s = cbuuid(b["svc"]) else { return fail(id, "NotFoundError", "No such service") }
        if s == OTA_SVC { return fail(id, "SecurityError", "Blocked") }
        guard p.state == .connected else { return fail(id, "NetworkError", "GATT Server is disconnected.") }
        if p.services?.contains(where: { $0.uuid == s }) == true { return reply(id, true) }
        serviceWaits[u, default: []].append((id, s))
        p.discoverServices([s])
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let u = p.identifier
        let found = p.services ?? []
        if let ids = connectWaits.removeValue(forKey: u) {
            ids.forEach { reply($0, true) }
        }
        if let waits = serviceWaits.removeValue(forKey: u) {
            for w in waits {
                if found.contains(where: { $0.uuid == w.svc }) { reply(w.id, true) } else { fail(w.id, "NotFoundError", "No such service") }
            }
        }
        tracker?.servicesReady(p)
    }

    private func findService(_ p: CBPeripheral, _ s: CBUUID) -> CBService? { p.services?.first { $0.uuid == s } }
    func findChar(_ p: CBPeripheral, _ s: CBUUID, _ c: CBUUID) -> CBCharacteristic? { findService(p, s)?.characteristics?.first { $0.uuid == c } }

    private func props(_ c: CBCharacteristic) -> [String: Bool] {
        let pr = c.properties
        return ["read": pr.contains(.read), "write": pr.contains(.write), "writeWithoutResponse": pr.contains(.writeWithoutResponse),
                "notify": pr.contains(.notify), "indicate": pr.contains(.indicate)]
    }

    private func characteristic(_ id: Int, _ b: [String: Any]) {
        guard let u = uuid(b["dev"]), let p = peripherals[u], let s = cbuuid(b["svc"]), let c = cbuuid(b["ch"]), let svc = findService(p, s) else {
            return fail(id, "NotFoundError", "No such characteristic")
        }
        if let ch = svc.characteristics?.first(where: { $0.uuid == c }) { return reply(id, true, ["props": props(ch)]) }
        let k = "\(u.uuidString)|\(s.uuidString.lowercased())"
        charWaits[k, default: []].append((id, c))
        p.discoverCharacteristics(nil, for: svc)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor svc: CBService, error: Error?) {
        let k = "\(p.identifier.uuidString)|\(svc.uuid.uuidString.lowercased())"
        if let waits = charWaits.removeValue(forKey: k) {
            for w in waits {
                if let ch = svc.characteristics?.first(where: { $0.uuid == w.ch }) { reply(w.id, true, ["props": props(ch)]) }
                else { fail(w.id, "NotFoundError", "No such characteristic") }
            }
        }
        tracker?.characteristicsReady(p, svc)
    }

    private func charFor(_ id: Int, _ b: [String: Any]) -> (CBPeripheral, CBCharacteristic)? {
        guard let u = uuid(b["dev"]), let p = peripherals[u], p.state == .connected,
              let s = cbuuid(b["svc"]), let c = cbuuid(b["ch"]), let ch = findChar(p, s, c) else {
            fail(id, "NetworkError", "GATT Server is disconnected."); return nil
        }
        return (p, ch)
    }

    private func read(_ id: Int, _ b: [String: Any]) {
        guard let pc = charFor(id, b) else { return }
        let (p, ch) = pc
        readWaits[key(p, ch), default: []].append(id)
        p.readValue(for: ch)
    }

    private func write(_ id: Int, _ b: [String: Any]) {
        guard let pc = charFor(id, b) else { return }
        let (p, ch) = pc
        let data = Data(base64Encoded: b["data"] as? String ?? "") ?? Data()
        let wantResp = b["resp"] as? Bool ?? true
        let canNoResp = ch.properties.contains(.writeWithoutResponse)
        if !wantResp && canNoResp {
            if p.canSendWriteWithoutResponse { p.writeValue(data, for: ch, type: .withoutResponse); reply(id, true) }
            else { noResponseQueue.append((p, ch, data, id)) }
        } else {
            writeWaits[key(p, ch), default: []].append(id)
            p.writeValue(data, for: ch, type: .withResponse)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        while let i = noResponseQueue.firstIndex(where: { $0.p === p }), p.canSendWriteWithoutResponse {
            let w = noResponseQueue.remove(at: i)
            p.writeValue(w.d, for: w.c, type: .withoutResponse)
            reply(w.id, true)
        }
    }

    private func notify(_ id: Int, _ b: [String: Any]) {
        guard let pc = charFor(id, b) else { return }
        let (p, ch) = pc
        let on = b["on"] as? Bool ?? true
        if ch.isNotifying == on { return reply(id, true) }
        notifyWaits[key(p, ch), default: []].append(id)
        p.setNotifyValue(on, for: ch)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let k = key(p, ch)
        guard var ids = notifyWaits[k], !ids.isEmpty else { return }
        let id = ids.removeFirst(); notifyWaits[k] = ids.isEmpty ? nil : ids
        if let e = error { fail(id, "NetworkError", e.localizedDescription) } else { reply(id, true) }
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) {
        let k = key(p, ch)
        guard var ids = writeWaits[k], !ids.isEmpty else { return }
        let id = ids.removeFirst(); writeWaits[k] = ids.isEmpty ? nil : ids
        if let e = error { fail(id, "NetworkError", e.localizedDescription) } else { reply(id, true) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        let k = key(p, ch)
        if var ids = readWaits[k], !ids.isEmpty {
            let id = ids.removeFirst(); readWaits[k] = ids.isEmpty ? nil : ids
            if let e = error { fail(id, "NetworkError", e.localizedDescription) }
            else { reply(id, true, ["data": (ch.value ?? Data()).base64EncodedString()]) }
            return
        }
        guard let v = ch.value else { return }
        // replies to the tracker's own requests (and anything at all while the app is in the background) stay here
        if ch.uuid == LORAX_REPLY, let t = tracker, t.takeReply(v) || away { return }
        if away { return }
        let svc = ch.service?.uuid.uuidString.lowercased() ?? ""
        js("window.__emberBle&&window.__emberBle.notify(\(json([p.identifier.uuidString, svc, ch.uuid.uuidString.lowercased(), v.base64EncodedString()]).dropFirst().dropLast()))")
    }

    // MARK: - Bluetooth on / off

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let on = c.state == .poweredOn
        if c.state != .unknown && c.state != .resetting {
            let ids = availWaits; availWaits = []
            ids.forEach { reply($0, true, ["on": on]) }
        }
        js("window.__emberBle&&window.__emberBle.avail(\(on))")
        if on, away, let u = activeId, let p = peripherals[u], p.state == .disconnected { c.connect(p, options: nil) }
    }

    // MARK: - for the background tracker

    func peripheral(_ u: UUID) -> CBPeripheral? { peripherals[u] }
    func isConnected(_ u: UUID?) -> Bool { u.flatMap { peripherals[$0] }?.state == .connected }

    // back in the app: tell the page about anything that dropped while it was away, so it reconnects cleanly
    func cameBack() {
        let gone = goneWhileAway; goneWhileAway = []
        for u in gone { js("window.__emberBle&&window.__emberBle.gone(\(json([u.uuidString]).dropFirst().dropLast()))") }
    }
}
