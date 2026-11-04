import UIKit

// New app builds from GitHub: every build has a number (the GitHub run number), and the release also has
// source.json (the feed SideStore and AltStore read). On launch, and when you come back to the app (at most every
// 6 hours), this reads that feed. If GitHub has a newer build, it asks once per build whether to download it.
// iOS doesn't let an app install itself: the download goes to Safari (then Sideloadly) or SideStore updates it.
enum UpdateCheck {
    static let feed = URL(string: "https://github.com/taupespy-debug/test/releases/download/ios-latest/source.json")!
    static let ipa = URL(string: "https://github.com/taupespy-debug/test/releases/download/ios-latest/Emberline.ipa")!

    static var myBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    static func run(from host: UIViewController) {
        let d = UserDefaults.standard
        if Date().timeIntervalSince1970 - d.double(forKey: "updChecked") < 6 * 3600 { return }
        d.set(Date().timeIntervalSince1970, forKey: "updChecked")
        var r = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        r.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: r) { data, _, _ in
            guard let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = (j["apps"] as? [[String: Any]])?.first, let v = (app["versions"] as? [[String: Any]])?.first,
                  let b = Int(v["buildVersion"] as? String ?? ""), b > myBuild else { return }
            DispatchQueue.main.async {
                if d.integer(forKey: "updAsked") == b { return } // asked about this one already
                d.set(b, forKey: "updAsked")
                let notes = (v["localizedDescription"] as? String).map { "\n\n\($0)" } ?? ""
                let a = UIAlertController(title: "Emberline update ready", message: "Version \(v["version"] as? String ?? "") (build \(b)) is on GitHub. You have build \(myBuild).\(notes)\n\nUsing SideStore? Update it there. Using Sideloadly? Download it and install it the same way as before.", preferredStyle: .alert)
                a.addAction(UIAlertAction(title: "Later", style: .cancel))
                a.addAction(UIAlertAction(title: "Download", style: .default) { _ in UIApplication.shared.open(ipa) })
                (host.presentedViewController ?? host).present(a, animated: true)
            }
        }.resume()
    }
}
