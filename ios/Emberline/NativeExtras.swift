import UIKit
import ActivityKit
import UserNotifications
import AppIntents

// MARK: - Live Activity (lock screen + Dynamic Island)

// One session at a time. The page sends its state about once a second while the app is open; the background
// tracker sends it while the app is closed. Updates are throttled so iOS doesn't rate-limit them.
final class LiveSession {
    static let shared = LiveSession()
    private var activity: Activity<EmberActivity>?
    private var last: EmberActivity.ContentState?
    private var lastPush = Date.distantPast
    private var name = "", color = "#8a2bff"

    // d: phase, name, color, tempF, targetF, readyAt / endsAt (ms since 1970), hits, lastHit, best, blinker
    func handle(_ d: [String: Any]) {
        let phase = d["phase"] as? String ?? "idle"
        if phase == "idle" { finish(); return }
        let date = { (k: String) -> Date? in (d[k] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil } }
        let st = EmberActivity.ContentState(
            phase: phase, tempF: d["tempF"] as? Int ?? 0, targetF: d["targetF"] as? Int ?? 0,
            readyAt: date("readyAt"), endsAt: date("endsAt"),
            hits: d["hits"] as? Int ?? 0, lastHit: d["lastHit"] as? Double ?? 0, best: d["best"] as? Double ?? 0,
            blinker: d["blinker"] as? Bool ?? false)
        if let n = d["name"] as? String, !n.isEmpty { name = n }
        if let c = d["color"] as? String, c.hasPrefix("#") { color = c }
        if phase == "done" { finish(st); return }
        show(st)
    }

    private func show(_ st: EmberActivity.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if activity == nil || activity?.activityState != .active {
            for a in Activity<EmberActivity>.activities { Task { await a.end(nil, dismissalPolicy: .immediate) } } // anything left over
            activity = try? Activity.request(attributes: EmberActivity(name: name, color: color),
                                             content: ActivityContent(state: st, staleDate: Date().addingTimeInterval(600)), pushType: nil)
            last = st; lastPush = Date()
            return
        }
        guard let prev = last, prev != st else { return }
        // a new phase, a hit or a boost goes right away; the temp creeping up at most every 3s
        let endMoved = abs((st.endsAt ?? .distantPast).timeIntervalSince(prev.endsAt ?? .distantPast)) > 2
        let important = st.phase != prev.phase || st.hits != prev.hits || endMoved || st.blinker != prev.blinker
        if !important && Date().timeIntervalSince(lastPush) < 3 { return }
        last = st; lastPush = Date()
        let a = activity
        Task { await a?.update(ActivityContent(state: st, staleDate: Date().addingTimeInterval(600))) }
    }

    func finish(_ st: EmberActivity.ContentState? = nil) {
        guard let a = activity else { return }
        activity = nil
        var end = st ?? last
        end?.phase = "done"
        last = nil
        let content = end.map { ActivityContent(state: $0, staleDate: nil) }
        Task { await a.end(content, dismissalPolicy: .after(Date().addingTimeInterval(30))) } // the summary stays on the lock screen for a bit
    }
}

// MARK: - Haptics (the real Taptic Engine, instead of the browser switch trick)

enum Haptics {
    static func play(_ kind: String) {
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "heavy": UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        case "medium": UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case "rigid": UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        case "soft": UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case "select": UISelectionFeedbackGenerator().selectionChanged()
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - Notifications (from the app itself, no server needed)

final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()
    func setUp() { UNUserNotificationCenter.current().delegate = self }
    func ask() {
        guard !UserDefaults.standard.bool(forKey: "notifAsked") else { return }
        UserDefaults.standard.set(true, forKey: "notifAsked")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    func send(_ title: String, _ body: String, id: String = UUID().uuidString) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
    // show them even with the app open (the test button), as a banner
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

// MARK: - Siri and Shortcuts (the intents themselves are in Shared/EmberIntents.swift, also used by the controls)

enum AppServices {
    static weak var tracker: BackgroundTracker?
    static func setUp() {
        IntentHook.run = { c, done in
            DispatchQueue.main.async {
                guard let t = tracker else { return done("Open Emberline and connect your Puffco first.") }
                let cmd: BackgroundTracker.Command = c == "start" ? .start : c == "stop" ? .stop : .boost
                t.command(cmd) { r in
                    switch r {
                    case .ok: done(c == "start" ? "Heating up 🔥" : c == "stop" ? "Stopped." : "Boosted ⚡️")
                    case .notConnected: done("Open Emberline and connect your Puffco first.")
                    case .proxyBoost: done("On a Proxy, Boost from the app.")
                    case .failed: done("Your Puffco didn't answer. Try again.")
                    }
                }
            }
        }
    }
}

struct EmberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartHeatIntent(), phrases: ["Start my \(.applicationName)", "Heat up \(.applicationName)", "Start \(.applicationName)"],
                    shortTitle: "Start heating", systemImageName: "flame.fill")
        AppShortcut(intent: StopHeatIntent(), phrases: ["Stop my \(.applicationName)", "Stop \(.applicationName)"],
                    shortTitle: "Stop", systemImageName: "stop.fill")
        AppShortcut(intent: BoostIntent(), phrases: ["Boost my \(.applicationName)", "Boost \(.applicationName)"],
                    shortTitle: "Boost", systemImageName: "bolt.fill")
    }
}
