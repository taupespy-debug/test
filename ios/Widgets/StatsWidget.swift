import WidgetKit
import SwiftUI
import AppIntents

// Home screen, lock screen and StandBy widgets: your rank, RP, place, streak, clean meter and progress to Aurum.
// The widget can't see inside the app (that needs a paid Apple account), so it reads your public profile from the
// leaderboard by username. Long-press the widget > Edit Widget to set it.

private let SB_URL = "https://auwzabwikloobzvgcdaa.supabase.co"
private let SB_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImF1d3phYndpa2xvb2J6dmdjZGFhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTA4ODExOTUsImV4cCI6MjEwNjQ1NzE5NX0.dESN5nYqgX087fzd27txEXf6fEKraF4D0RW8MaUuv6w"

struct UsernameConfig: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Your Emberline profile"
    static let description = IntentDescription("Shows your rank and stats.")
    @Parameter(title: "Username") var username: String?
}

struct Stats {
    var username = "", tier = "Ember", rp = 0, place = 0, blinkers = 0, sessions = 0, streak = -1, clean = -1, cleanEvery = 150
    var ok = false
    static let sample = Stats(username: "you", tier: "Blaze", rp: 212, place: 14, blinkers: 37, sessions: 41, streak: 5, clean: 63, ok: true)
}

struct StatsEntry: TimelineEntry { let date: Date; let s: Stats; let set: Bool }

private let tierColors: [String: Color] = ["Ember": Color(red: 1, green: 0.42, blue: 0.24), "Flame": Color(red: 1, green: 0.62, blue: 0.04),
    "Blaze": Color(red: 1, green: 0.84, blue: 0.04), "Inferno": Color(red: 1, green: 0.18, blue: 0.33), "Champion": Color(red: 0.91, green: 0.73, blue: 0.31),
    "Legend": Color(red: 0.71, green: 0.42, blue: 1)]
private func tierColor(_ t: String) -> Color { tierColors[t] ?? Color(red: 0.54, green: 0.17, blue: 1) }

struct StatsProvider: AppIntentTimelineProvider {
    func placeholder(in c: Context) -> StatsEntry { StatsEntry(date: Date(), s: .sample, set: true) }
    func snapshot(for cfg: UsernameConfig, in c: Context) async -> StatsEntry {
        if c.isPreview { return StatsEntry(date: Date(), s: .sample, set: true) }
        return await entry(cfg)
    }
    func timeline(for cfg: UsernameConfig, in c: Context) async -> Timeline<StatsEntry> {
        Timeline(entries: [await entry(cfg)], policy: .after(Date().addingTimeInterval(30 * 60))) // every 30 minutes
    }
    private func entry(_ cfg: UsernameConfig) async -> StatsEntry {
        let name = (cfg.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return StatsEntry(date: Date(), s: Stats(), set: false) }
        return StatsEntry(date: Date(), s: await load(name), set: true)
    }

    private func get(_ path: String, count: Bool = false) async -> (Any?, Int?) {
        guard let url = URL(string: SB_URL + path) else { return (nil, nil) }
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue(SB_KEY, forHTTPHeaderField: "apikey"); r.setValue("Bearer " + SB_KEY, forHTTPHeaderField: "Authorization")
        if count { r.setValue("count=exact", forHTTPHeaderField: "Prefer"); r.setValue("0-0", forHTTPHeaderField: "Range") }
        guard let (d, resp) = try? await URLSession.shared.data(for: r) else { return (nil, nil) }
        var total: Int? = nil
        if let cr = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last { total = Int(t) }
        return (try? JSONSerialization.jsonObject(with: d), total)
    }

    private func load(_ name: String) async -> Stats {
        var s = Stats(); s.username = name
        // exact name, any case (ilike with the wildcards escaped)
        let safe = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        guard let q = safe.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let rows = (await get("/rest/v1/players?select=username,rp,tier,blinkers,stats,month&username=ilike.\(q)&limit=1")).0 as? [[String: Any]],
              let p = rows.first else { return s }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"; let month = f.string(from: Date())
        let thisMonth = (p["month"] as? String) == month
        s.username = p["username"] as? String ?? name
        s.rp = thisMonth ? (p["rp"] as? Int ?? 0) : 0
        s.tier = thisMonth ? (p["tier"] as? String ?? "Ember") : "Ember"
        s.blinkers = p["blinkers"] as? Int ?? 0
        let st = p["stats"] as? [String: Any] ?? [:]
        s.sessions = thisMonth ? (st["sessions"] as? Int ?? 0) : 0
        s.blinkers = max(s.blinkers, st["blAll"] as? Int ?? 0)
        s.streak = st["streak"] as? Int ?? -1
        s.clean = st["clean"] as? Int ?? -1
        s.cleanEvery = st["cleanEvery"] as? Int ?? 150
        if thisMonth {
            let (_, above) = await get("/rest/v1/players?select=id&month=eq.\(month)&banned=not.is.true&rp=gt.\(s.rp)", count: true)
            s.place = (above ?? 0) + 1
        }
        s.ok = true
        return s
    }
}

private struct Flame: View {
    let c: Color
    var body: some View { Image(systemName: "flame.fill").foregroundStyle(c) }
}

struct StatsView: View {
    @Environment(\.widgetFamily) var family
    let e: StatsEntry
    var body: some View {
        let s = e.s, tc = tierColor(s.tier)
        switch family {
        case .accessoryInline:
            Text(e.set && s.ok ? "🔥 \(s.tier) · \(s.rp) RP · #\(s.place)" : "Emberline: set your username")
        case .accessoryCircular:
            Gauge(value: Double(min(s.blinkers, 100)), in: 0...100) { Flame(c: .white) } currentValueLabel: { Text("\(min(s.blinkers, 100))") }
                .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Label(s.tier, systemImage: "flame.fill").font(.headline)
                Text(e.set && s.ok ? "\(s.rp) RP · #\(s.place)" : "Set your username").font(.caption)
                if s.streak >= 0 { Text("Streak \(s.streak) days").font(.caption2).foregroundStyle(.secondary) }
            }
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                HStack { Flame(c: tc); Text(s.tier).font(.headline).foregroundStyle(tc) }
                Text("\(s.rp)").font(.system(size: 34, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6)
                Text(e.set ? (s.ok ? "RP · #\(s.place) this month" : "Can't find \(s.username)") : "Long-press > Edit Widget to add your username")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if s.ok { ProgressView(value: Double(min(s.blinkers, 100)), total: 100) { Text("Aurum \(min(s.blinkers, 100))/100").font(.caption2) }.tint(.yellow) }
            }
        default: // medium (and StandBy)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Flame(c: tc); Text(s.tier).font(.headline).foregroundStyle(tc) }
                    Text("\(s.rp) RP").font(.system(size: 30, weight: .heavy, design: .rounded)).minimumScaleFactor(0.6)
                    Text(e.set ? (s.ok ? "#\(s.place) this month · \(s.username)" : "Can't find \(s.username)") : "Long-press > Edit Widget to add your username")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 6) {
                    Row(icon: "calendar", text: s.streak >= 0 ? "\(s.streak) day streak" : "\(s.sessions) sessions")
                    Row(icon: "sparkles", text: s.clean >= 0 ? "Clean \(s.clean)/\(s.cleanEvery)" : "\(s.sessions) sessions")
                    ProgressView(value: Double(min(s.blinkers, 100)), total: 100) { Text("Aurum \(min(s.blinkers, 100))/100").font(.caption2) }.tint(.yellow)
                }
                .frame(maxWidth: 150)
            }
        }
    }
}

private struct Row: View {
    let icon: String, text: String
    var body: some View { Label(text, systemImage: icon).font(.caption).lineLimit(1) }
}

struct StatsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.emberline.app.stats", intent: UsernameConfig.self, provider: StatsProvider()) { e in
            StatsView(e: e).containerBackground(for: .widget) {
                LinearGradient(colors: [Color(red: 0.12, green: 0.05, blue: 0.22), Color(red: 0.04, green: 0.03, blue: 0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .configurationDisplayName("Emberline rank")
        .description("Your rank, RP, place, streak and clean meter.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct AurumWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "com.emberline.app.aurum", intent: UsernameConfig.self, provider: StatsProvider()) { e in
            StatsView(e: e).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Aurum progress")
        .description("Blinkers toward the Aurum theme (100).")
        .supportedFamilies([.accessoryCircular])
    }
}
