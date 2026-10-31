import Foundation
import ActivityKit

// The Live Activity for a session (lock screen and Dynamic Island). The app starts and updates it,
// the widget extension (Widgets/) draws it.
struct EmberActivity: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var phase: String      // "heat", "ready" or "done"
        var tempF: Int         // what the chamber reads now
        var targetF: Int       // what it's heating to
        var readyAt: Date?     // when it went Ready (for the progress bar)
        var endsAt: Date?      // when the session ends (the countdown)
        var hits: Int
        var lastHit: Double
        var best: Double
        var blinker: Bool      // the last hit was a blinker
    }
    var name: String           // profile name
    var color: String          // profile color, "#rrggbb"
}
