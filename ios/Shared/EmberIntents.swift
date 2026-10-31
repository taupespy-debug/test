import AppIntents

// Start / Stop / Boost, used by Siri, Shortcuts, the Action Button, the Control Center and lock screen controls,
// and the buttons on the Live Activity. They're Live Activity intents so iOS runs them inside the app (which holds
// the Bluetooth link to the Peak), even when the button is pressed in Control Center.
enum IntentHook {
    // set by the app (AppServices.setUp); empty if this ever runs somewhere without the Bluetooth link
    static var run: ((String, @escaping (String) -> Void) -> Void)?
    static func perform(_ c: String) async -> String {
        guard let r = run else { return "Open Emberline and connect your Puffco first." }
        return await withCheckedContinuation { cont in r(c) { cont.resume(returning: $0) } }
    }
}

struct StartHeatIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Start heating"
    static let description = IntentDescription("Starts a heat cycle on your Puffco with the profile it's on.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await IntentHook.perform("start")))
    }
}

struct StopHeatIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop heating"
    static let description = IntentDescription("Stops the heat cycle on your Puffco.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await IntentHook.perform("stop")))
    }
}

struct BoostIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Boost"
    static let description = IntentDescription("Boosts the heat cycle on your Peak.")
    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: await IntentHook.perform("boost")))
    }
}
