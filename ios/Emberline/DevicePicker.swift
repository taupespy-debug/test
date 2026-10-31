import UIKit

// The "pick your Peak" list for requestDevice: Peaks and Proxies show up as they're found, tap one to connect.
final class DevicePicker: UITableViewController {
    var onPick: ((UUID) -> Void)?
    var onCancel: (() -> Void)?
    private var rows: [(id: UUID, name: String, rssi: Int)] = []
    private var done = false
    private let spinner = UIActivityIndicatorView(style: .medium)

    func wrapped() -> UIViewController {
        let nav = UINavigationController(rootViewController: self)
        nav.overrideUserInterfaceStyle = .dark
        if #available(iOS 15.0, *), let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        nav.presentationController?.delegate = self
        return nav
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Choose your Puffco"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
    }

    func add(id: UUID, name: String, rssi: Int) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i] = (id, name, rssi) } else { rows.append((id, name, rssi)) }
        rows.sort { $0.rssi > $1.rssi }
        if isViewLoaded { tableView.reloadData() }
    }

    override func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { max(rows.count, 1) }
    override func tableView(_ t: UITableView, titleForFooterInSection s: Int) -> String? {
        "Wake your Peak or Proxy (tap the button) so it shows up here. If it's connected to the Puffco app, close that first."
    }
    override func tableView(_ t: UITableView, cellForRowAt ip: IndexPath) -> UITableViewCell {
        let c = t.dequeueReusableCell(withIdentifier: "c", for: ip)
        var cfg = c.defaultContentConfiguration()
        if rows.isEmpty {
            cfg.text = "Looking for your Puffco…"
            cfg.textProperties.color = .secondaryLabel
            c.selectionStyle = .none
        } else {
            let r = rows[ip.row]
            cfg.text = r.name
            cfg.secondaryText = r.rssi > -60 ? "Right next to you" : r.rssi > -80 ? "Nearby" : "Far away"
            c.selectionStyle = .default
        }
        c.contentConfiguration = cfg
        return c
    }
    override func tableView(_ t: UITableView, didSelectRowAt ip: IndexPath) {
        t.deselectRow(at: ip, animated: true)
        guard !rows.isEmpty, !done else { return }
        done = true
        let id = rows[ip.row].id
        dismiss(animated: true) { [weak self] in self?.onPick?(id) }
    }
    @objc private func cancelTapped() {
        guard !done else { return }
        done = true
        dismiss(animated: true) { [weak self] in self?.onCancel?() }
    }
    func dismissSheet() {
        done = true
        if presentingViewController != nil || navigationController?.presentingViewController != nil { dismiss(animated: true) }
    }
}

extension DevicePicker: UIAdaptivePresentationControllerDelegate {
    // swiped down: same as Cancel
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard !done else { return }
        done = true
        onCancel?()
    }
}
