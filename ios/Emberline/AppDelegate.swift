import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = UIWindow(frame: UIScreen.main.bounds)
        w.backgroundColor = UIColor(red: 11 / 255, green: 10 / 255, blue: 16 / 255, alpha: 1)
        w.rootViewController = WebViewController()
        w.makeKeyAndVisible()
        window = w
        return true
    }
}
