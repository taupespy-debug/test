import Foundation
import BackgroundTasks

// 1v1 invites, group sesh invites and new followers on your lock screen, without a push server:
// the app checks the same inbox the page's bell uses. Every minute while the app is running in the background
// (it is while your Peak is connected), and when iOS gives it a background refresh otherwise.
final class NotesWatch {
    static let shared = NotesWatch()
    static let taskId = "com.emberline.app.notes"
    private var timer: Timer?
    private var busy = false
    private let ud = UserDefaults.standard

    // the page's own request for the bell (POST /functions/v1/player, action "notes"), and the notes it already showed
    func configure(_ c: [String: Any]) {
        guard let url = c["url"] as? String, let key = c["key"] as? String, let body = c["body"] as? [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: body) else { return }
        ud.set(url, forKey: "notesURL"); ud.set(key, forKey: "notesKey"); ud.set(d, forKey: "notesBody")
        if let seen = c["seen"] as? [String], !seen.isEmpty {
            var s = Set(ud.stringArray(forKey: "notesSeen") ?? [])
            seen.forEach { s.insert($0) }
            ud.set(Array(s).suffix(300).map { $0 }, forKey: "notesSeen")
            ud.set(true, forKey: "notesPrimed")
        }
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: NotesWatch.taskId, using: .main) { task in
            self.schedule()
            task.expirationHandler = { task.setTaskCompleted(success: false) }
            self.check { task.setTaskCompleted(success: true) }
        }
    }
    func schedule() {
        let r = BGAppRefreshTaskRequest(identifier: NotesWatch.taskId)
        r.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    func startAway() {
        schedule()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.check {} }
    }
    func stopAway() { timer?.invalidate(); timer = nil }

    func check(_ done: @escaping () -> Void) {
        guard !busy, let u = ud.string(forKey: "notesURL"), let url = URL(string: u), let key = ud.string(forKey: "notesKey"),
              let body = ud.data(forKey: "notesBody"), var obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return done() }
        obj["action"] = "notes"
        var r = URLRequest(url: url, timeoutInterval: 20)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "apikey")
        r.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: obj)
        busy = true
        URLSession.shared.dataTask(with: r) { d, _, _ in
            DispatchQueue.main.async {
                self.busy = false
                defer { done() }
                guard let d = d, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let list = o["notes"] as? [[String: Any]] else { return }
                var seen = Set(self.ud.stringArray(forKey: "notesSeen") ?? [])
                let primed = self.ud.bool(forKey: "notesPrimed") // the first check only learns what's already there
                for n in list.reversed() {
                    let id = "\(n["id"] ?? "")"
                    if id.isEmpty || seen.contains(id) { continue }
                    seen.insert(id)
                    if !primed || n["read"] as? Bool == true { continue }
                    self.show(n)
                }
                self.ud.set(Array(seen).suffix(300).map { $0 }, forKey: "notesSeen")
                self.ud.set(true, forKey: "notesPrimed")
            }
        }.resume()
    }

    private func show(_ n: [String: Any]) {
        let who = (n["from_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Someone"
        let data = n["data"] as? [String: Any] ?? [:]
        let sesh = data["sesh"] != nil || ((data["rules"] as? [String: Any])?["sesh"] != nil)
        switch n["kind"] as? String {
        case "invite" where sesh: Notify.shared.send("🔥 \(who) started a group sesh", "Open Emberline to join. Invites last 15 minutes.")
        case "invite":
            let bet = (data["bet"] as? Int).map { " for \($0) RP" } ?? ""
            Notify.shared.send("🔥 \(who) wants to 1v1\(bet)", "Open Emberline to join. Invites last 15 minutes.")
        case "follow": Notify.shared.send("👋 \(who) followed you", "Open Emberline to see their profile.")
        default: break
        }
    }
}
