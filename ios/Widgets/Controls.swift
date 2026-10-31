import WidgetKit
import SwiftUI
import AppIntents

// Control Center, lock screen and Action Button controls (iOS 18)
struct StartHeatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.emberline.app.start") {
            ControlWidgetButton(action: StartHeatIntent()) { Label("Start heat", systemImage: "flame.fill") }
        }
        .displayName("Start heat")
        .description("Starts your Puffco on the profile it's on.")
    }
}

struct StopHeatControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.emberline.app.stop") {
            ControlWidgetButton(action: StopHeatIntent()) { Label("Stop heat", systemImage: "stop.fill") }
        }
        .displayName("Stop heat")
        .description("Stops your Puffco.")
    }
}

struct BoostControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.emberline.app.boost") {
            ControlWidgetButton(action: BoostIntent()) { Label("Boost", systemImage: "bolt.fill") }
        }
        .displayName("Boost")
        .description("Boosts your Peak.")
    }
}
