import WidgetKit
import SwiftUI
import ActivityKit

@main
struct EmberWidgets: WidgetBundle {
    var body: some Widget { EmberLiveActivity() }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        let v = UInt64(s, radix: 16) ?? 0x8A2BFF
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

private func phaseText(_ s: EmberActivity.ContentState) -> String {
    switch s.phase {
    case "heat": return "Heating to \(s.targetF)°"
    case "ready": return s.blinker ? "Blinker! 🔥" : "Ready"
    default: return "Done"
    }
}

// the countdown while Ready, the temp otherwise. The lower bound is never past the end, so the range is always valid
private struct TimerOrTemp: View {
    let s: EmberActivity.ContentState
    var body: some View {
        if s.phase == "ready", let e = s.endsAt, e > Date() {
            Text(timerInterval: min(Date(), e)...e, countsDown: true).monospacedDigit()
        } else {
            Text("\(s.tempF)°").monospacedDigit()
        }
    }
}

private struct HitsLine: View {
    let s: EmberActivity.ContentState
    var body: some View {
        if s.hits == 0 {
            Text(s.phase == "heat" ? "Get ready" : "No hits yet").foregroundStyle(.secondary)
        } else {
            Text("\(s.hits) hit\(s.hits == 1 ? "" : "s") · best \(String(format: "%.1f", s.best))s").foregroundStyle(.secondary)
        }
    }
}

private struct Bar: View {
    let s: EmberActivity.ContentState
    let tint: Color
    var body: some View {
        if s.phase == "ready", let r = s.readyAt, let e = s.endsAt, e > r {
            ProgressView(timerInterval: r...e, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                .tint(tint)
        } else if s.phase == "heat" {
            ProgressView(value: Double(max(0, min(s.tempF, s.targetF))), total: Double(max(1, s.targetF))).tint(tint)
        }
    }
}

private struct LockView: View {
    let a: EmberActivity
    let s: EmberActivity.ContentState
    var body: some View {
        let tint = Color(hex: a.color)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint.opacity(0.25))
                    Image(systemName: "flame.fill").font(.title3).foregroundStyle(tint)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(a.name).font(.headline).foregroundStyle(.white)
                    Text(phaseText(s)).font(.subheadline).foregroundStyle(.white.opacity(0.75))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    TimerOrTemp(s: s).font(.title.bold()).foregroundStyle(.white)
                    HitsLine(s: s).font(.caption)
                }
            }
            Bar(s: s, tint: tint)
        }
        .padding(16)
    }
}

struct EmberLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EmberActivity.self) { ctx in
            LockView(a: ctx.attributes, s: ctx.state)
                .activityBackgroundTint(Color(red: 0.06, green: 0.04, blue: 0.10).opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { ctx in
            let tint = Color(hex: ctx.attributes.color)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill").foregroundStyle(tint)
                        Text(ctx.attributes.name).font(.headline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerOrTemp(s: ctx.state).font(.title2.bold())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        HStack {
                            Text(phaseText(ctx.state)).font(.subheadline)
                            Spacer()
                            HitsLine(s: ctx.state).font(.subheadline)
                        }
                        Bar(s: ctx.state, tint: tint)
                    }
                }
            } compactLeading: {
                Image(systemName: "flame.fill").foregroundStyle(tint)
            } compactTrailing: {
                TimerOrTemp(s: ctx.state).font(.caption.bold()).frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "flame.fill").foregroundStyle(tint)
            }
            .keylineTint(tint)
        }
    }
}
