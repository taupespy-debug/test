import UIKit
import WebKit

// The app is the Emberline site in a full-screen web view, with Bluetooth from the app (BLEBridge) instead of Path's.
// Updates still come from GitHub Pages: push to the site and the app has it on the next open.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    // the test build for now; switch to https://emberlineapp.github.io/emberline/ for live
    static let startURL = URL(string: "https://taupespy-debug.github.io/test/emberlinetest.html")!
    static let hosts: Set<String> = ["taupespy-debug.github.io", "emberlineapp.github.io"]

    private var web: WKWebView!
    private let ble = BLEBridge()
    private let tracker = BackgroundTracker()
    private let keepAlive = KeepAlive()
    private let bg = UIColor(red: 11 / 255, green: 10 / 255, blue: 16 / 255, alpha: 1)

    private var lastCtx = BackgroundTracker.Ctx()
    private var hadDevice = false
    private var awayTimer: Timer?
    private var awaySince: Date?
    private var idleTimer: Timer?
    private var lastSeenAway = Date()
    private var needsReload = false // iOS dropped the page while the app was closed
    private var pendingResume: String? // sessions waiting for the page to load

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func loadView() {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.websiteDataStore = .default() // your settings, sessions and sign-in stay between opens
        cfg.applicationNameForUserAgent = "Mobile/15E148 EmberlineApp/1"
        let uc = WKUserContentController()
        if let url = Bundle.main.url(forResource: "bridge", withExtension: "js"), let src = try? String(contentsOf: url, encoding: .utf8) {
            uc.addUserScript(WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        uc.add(WeakHandler(self), name: "ble")
        uc.add(WeakHandler(self), name: "app")
        cfg.userContentController = uc

        web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = bg
        web.scrollView.backgroundColor = bg
        web.scrollView.contentInsetAdjustmentBehavior = .never // the page handles the notch itself (viewport-fit=cover)
        web.scrollView.bounces = false
        web.allowsBackForwardNavigationGestures = false
        web.navigationDelegate = self
        web.uiDelegate = self
        if #available(iOS 16.4, *) { web.isInspectable = true } // Safari > Develop works for debugging
        view = web
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ble.web = web
        ble.host = self
        ble.tracker = tracker
        ble.onAwayConnect = { [weak self] in self?.keepAlive.start() } // the Peak came back while the app was closed
        tracker.bridge = ble
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(wentAway), name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(cameBack), name: UIApplication.willEnterForegroundNotification, object: nil)
        load()
    }

    private func load() { web.load(URLRequest(url: WebViewController.startURL)) }

    // MARK: - page messages

    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        if m.name == "ble" { ble.handle(body); return }
        // "app" messages: the page's state every couple of seconds, so the tracker knows where things stand
        if body["op"] as? String == "ctx" {
            lastCtx = ctx(from: body)
            if body["connected"] as? Bool == true { hadDevice = true }
        }
    }

    private func ctx(from b: [String: Any]) -> BackgroundTracker.Ctx {
        var c = BackgroundTracker.Ctx()
        c.proxy = b["proxy"] as? Bool ?? false
        c.api = b["api"] as? Int ?? 3
        c.open = b["open"] as? [String: Any]
        return c
    }

    // MARK: - background

    @objc private func wentAway() {
        guard hadDevice || ble.isConnected(ble.activeId) else { return }
        keepAlive.start()
        awaySince = Date(); lastSeenAway = Date()
        // give it a few seconds: pulling down Control Center shouldn't hand over the link
        awayTimer?.invalidate()
        awayTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in self?.handOver() }
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.ble.isConnected(self.ble.activeId) { self.lastSeenAway = Date() }
            else if Date().timeIntervalSince(self.lastSeenAway) > 7200 { self.keepAlive.stop() } // 2 hours with no Peak: let the phone rest
        }
    }

    private func handOver() {
        guard UIApplication.shared.applicationState == .background, !tracker.owning else { return }
        // ask the page to stop polling and tell us its unfinished session; if it's already frozen, use the last state it sent
        web.evaluateJavaScript("window.emberBgPause ? window.emberBgPause() : null") { [weak self] r, _ in
            guard let self = self, UIApplication.shared.applicationState == .background, !self.tracker.owning else { return }
            if let s = r as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { self.lastCtx = self.ctx(from: o) }
            self.ble.away = true
            self.tracker.takeOver(self.lastCtx)
        }
        // a frozen page never answers: take over anyway
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, UIApplication.shared.applicationState == .background, !self.tracker.owning else { return }
            self.ble.away = true
            self.tracker.takeOver(self.lastCtx)
        }
    }

    @objc private func cameBack() {
        awayTimer?.invalidate(); awayTimer = nil
        idleTimer?.invalidate(); idleTimer = nil
        keepAlive.stop()
        let wasOwning = tracker.owning
        let out = tracker.release()
        ble.away = false
        ble.cameBack()
        var arg = "'{}'"
        if wasOwning, let d = try? JSONSerialization.data(withJSONObject: out), let s = String(data: d, encoding: .utf8),
           let q = try? JSONSerialization.data(withJSONObject: [s]), let qs = String(data: q, encoding: .utf8) {
            arg = String(qs.dropFirst().dropLast()) // a JSON string inside a JS string: no quote or line break can break out of it
        }
        if needsReload { needsReload = false; pendingResume = arg; load(); return }
        resume(arg)
    }

    // hand the sessions to the page; if it isn't ready yet, try again shortly (they're never dropped)
    private func resume(_ arg: String, tries: Int = 0) {
        web.evaluateJavaScript("window.emberBgResume ? (window.emberBgResume(\(arg)), 1) : 0") { [weak self] r, _ in
            if (r as? Int) == 1 || tries >= 20 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self?.resume(arg, tries: tries + 1) }
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if let a = pendingResume { pendingResume = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.resume(a) } }
    }

    // MARK: - navigation

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = a.request.url else { return decisionHandler(.allow) }
        if url.scheme == "emberline" { load(); return decisionHandler(.cancel) } // "Try again" on the offline page
        let ours = url.host.map { WebViewController.hosts.contains($0) } ?? true
        if ["http", "https"].contains(url.scheme ?? "") && !ours && a.targetFrame?.isMainFrame != false {
            UIApplication.shared.open(url) // Discord, Puffco and other links open in Safari or their app
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { offline(e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        if (e as NSError).code != NSURLErrorCancelled { offline(e) }
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        // iOS dropped the page to save memory. In the background, wait until the app is open (the tracker keeps going meanwhile)
        if UIApplication.shared.applicationState == .background { needsReload = true } else { load() }
    }

    private func offline(_ e: Error) {
        if (e as NSError).code == NSURLErrorCancelled { return }
        let html = """
        <meta name=viewport content="width=device-width,initial-scale=1"><body style="margin:0;height:100vh;display:grid;place-items:center;background:#0b0a10;color:#fff;font:16px -apple-system,system-ui;text-align:center">
        <div style="padding:24px"><h2 style="margin:0 0 8px">Can't reach Emberline</h2><p style="color:#a1a1a6;margin:0 0 20px">Check your internet connection and try again.</p>
        <a href="emberline://retry" style="display:inline-block;padding:12px 22px;border-radius:99px;background:#7300ff;color:#fff;text-decoration:none;font-weight:600">Try again</a></div></body>
        """
        web.loadHTMLString(html, baseURL: nil)
    }

    // window.open and target=_blank: open outside the app
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        if let url = a.request.url { UIApplication.shared.open(url) }
        return nil
    }

    // alert / confirm / prompt (Path has no confirm(), the app gets real ones)
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done() })
        present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(true) })
        present(a, animated: true)
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText t: String?, initiatedByFrame f: WKFrameInfo, completionHandler done: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: p, preferredStyle: .alert)
        a.addTextField { $0.text = t }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in done(a.textFields?.first?.text) })
        present(a, animated: true)
    }

    // the mic for 1v1 voice chat: iOS asks once (Info.plist explains why), no second prompt from the page
    @available(iOS 15.0, *)
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor o: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(WebViewController.hosts.contains(o.host) ? .grant : .prompt)
    }
}

// WKUserContentController keeps a strong reference to its handlers; this breaks the cycle
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ uc: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(uc, didReceive: m) }
}
