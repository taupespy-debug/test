import SwiftUI
import UserNotifications
import AppIntents

@main
struct GymPassApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // set up location right away: when you reach the gym, iOS launches the app in the background
        // and hands the "arrived" event to this delegate
        LocationService.shared.refresh()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async {
            if Store.shared.card != nil { Store.shared.showBarcode = true }
            done()
        }
    }
}

// "Show Gym Barcode" for Siri, Shortcuts, Spotlight and the Action button.
struct ShowGymBarcode: AppIntent {
    static var title: LocalizedStringResource = "Show Gym Barcode"
    static var description = IntentDescription("Opens your gym barcode full screen.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        Store.shared.showBarcode = Store.shared.card != nil
        return .result()
    }
}

struct GymPassShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowGymBarcode(),
            phrases: ["Show my gym barcode in \(.applicationName)", "Open \(.applicationName)"],
            shortTitle: "Gym Barcode",
            systemImageName: "barcode"
        )
    }
}
