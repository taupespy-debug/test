import CoreLocation
import UIKit
import UserNotifications

/// Watches a circle around your gym. iOS wakes the app when you walk in (even if it's closed),
/// and the app posts a notification with your barcode.
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    static let regionID = "gym"

    let manager = CLLocationManager()
    @Published var status: CLAuthorizationStatus
    @Published var lastError: String?

    private var oneShot: ((CLLocation?) -> Void)?
    private var wantsLocation = false

    override init() {
        status = .notDetermined
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Starts (or stops) watching the gym to match the saved card.
    func refresh() {
        guard let c = Store.shared.card, c.notify, let lat = c.latitude, let lon = c.longitude,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
            return  // comes back through locationManagerDidChangeAuthorization
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()  // iOS asks once to upgrade to Always
        case .denied, .restricted:
            return
        default:
            break
        }
        let radius = min(max(c.radius, 100), manager.maximumRegionMonitoringDistance)
        let center = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        // leave an identical region alone, so a pending "you arrived" event isn't lost
        if let r = manager.monitoredRegions.first(where: { $0.identifier == Self.regionID }) as? CLCircularRegion,
           abs(r.center.latitude - lat) < 0.000001, abs(r.center.longitude - lon) < 0.000001, abs(r.radius - radius) < 1 {
            return
        }
        manager.monitoredRegions.forEach { manager.stopMonitoring(for: $0) }
        let region = CLCircularRegion(center: center, radius: radius, identifier: Self.regionID)
        region.notifyOnEntry = true
        region.notifyOnExit = false
        manager.startMonitoring(for: region)
        lastError = nil
    }

    /// Your current location, once (for "I'm at the gym now").
    func currentLocation(_ done: @escaping (CLLocation?) -> Void) {
        oneShot = done
        if manager.authorizationStatus == .notDetermined {
            wantsLocation = true
            manager.requestWhenInUseAuthorization()
        } else {
            manager.requestLocation()
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        status = m.authorizationStatus
        if wantsLocation, status == .authorizedAlways || status == .authorizedWhenInUse {
            wantsLocation = false
            m.requestLocation()
        } else if wantsLocation, status == .denied || status == .restricted {
            wantsLocation = false
            oneShot?(nil)
            oneShot = nil
        }
        refresh()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        oneShot?(locations.last)
        oneShot = nil
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        oneShot?(nil)
        oneShot = nil
    }

    func locationManager(_ m: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == Self.regionID else { return }
        Notifier.arrived()
    }

    func locationManager(_ m: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        lastError = error.localizedDescription
    }
}

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// "You're at the gym" with the barcode attached (press and hold the notification to see it big).
    static func arrived(force: Bool = false) {
        let defaults = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if !force, now - defaults.double(forKey: "lastArrival") < 2 * 3600 { return }  // once per visit
        defaults.set(now, forKey: "lastArrival")
        guard let card = Store.shared.card else { return }

        let content = UNMutableNotificationContent()
        content.title = card.gymName.isEmpty ? "You're at the gym" : "You're at \(card.gymName)"
        content.body = "Tap to show your barcode."
        content.sound = .default
        content.interruptionLevel = .active
        content.relevanceScore = 1
        if let png = Barcode.image(card.value, kind: card.kind)?.pngData() {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("barcode-\(UUID().uuidString).png")
            if (try? png.write(to: url)) != nil,
               let a = try? UNNotificationAttachment(identifier: "barcode", url: url, options: nil) {
                content.attachments = [a]
            }
        }
        let req = UNNotificationRequest(identifier: "arrived", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
