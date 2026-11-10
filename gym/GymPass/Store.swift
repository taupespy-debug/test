import SwiftUI
import UIKit

/// Your gym card: the barcode, how it looks, and where the gym is.
struct GymCard: Codable, Equatable {
    var gymName = ""
    var memberName = ""
    var value = ""
    var kind: BarcodeKind = .code128
    var colorHex = "#FF6B1A"
    var latitude: Double?
    var longitude: Double?
    var radius: Double = 150
    var notify = true

    var hasLocation: Bool { latitude != nil && longitude != nil }
}

final class Store: ObservableObject {
    static let shared = Store()

    @Published var card: GymCard? {
        didSet {
            guard card != oldValue else { return }
            save()
            LocationService.shared.refresh()
        }
    }
    /// Shows the barcode full screen (from the arrival notification, Siri or the Action button).
    @Published var showBarcode = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: "card"),
           let c = try? JSONDecoder().decode(GymCard.self, from: data) {
            card = c
        }
    }

    private func save() {
        if let card, let data = try? JSONEncoder().encode(card) {
            UserDefaults.standard.set(data, forKey: "card")
        } else {
            UserDefaults.standard.removeObject(forKey: "card")
        }
    }

    func update(_ change: (inout GymCard) -> Void) {
        guard var c = card else { return }
        change(&c)
        card = c
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let n = UInt64(s, radix: 16) ?? 0xFF6B1A
        self.init(red: Double((n >> 16) & 0xFF) / 255, green: Double((n >> 8) & 0xFF) / 255, blue: Double(n & 0xFF) / 255)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        let c = { (v: CGFloat) in Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }

    /// Black or white, whichever reads better on this color.
    var readableText: Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.65 ? .black : .white
    }
}
