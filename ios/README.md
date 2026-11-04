# Emberline iPhone app (test)

The Emberline site in a real iPhone app. Bluetooth comes from the app instead of Path, and it keeps
tracking sessions (RP, hits, blinkers) while the app is closed.

## Install with Sideloadly (free)
1. Download **Emberline.ipa**: https://github.com/taupespy-debug/test/releases/download/ios-latest/Emberline.ipa
2. Open Sideloadly on your computer, plug in your iPhone, drag the .ipa in, sign in with your Apple ID, hit Start.
3. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > Trust.
4. iOS 16 or newer: Settings > Privacy & Security > Developer Mode > On (the phone restarts).
5. Open Emberline, allow Bluetooth, tap Connect and pick your Peak.

A free Apple ID signs it for 7 days. Turn on Sideloadly's auto-refresh, or drag the .ipa in again when it
stops opening. Your account and RP are on the server, so nothing is lost.

## Updates from GitHub
- Every build has its own number, and the release also has an update feed:
  https://github.com/taupespy-debug/test/releases/download/ios-latest/source.json
- The app checks it when it opens (at most every 6 hours). When GitHub has a newer build, it asks once if you want to
  download it. iOS doesn't let an app install itself, so you still install it with Sideloadly, or:
- **SideStore** (free, installs on the iPhone, no computer after setup): add the feed URL above as a Source.
  SideStore then shows Emberline updates and installs them on the phone.

## How it works
- The app opens the live site (emberlineapp.github.io/emberline) from GitHub Pages, so site updates show up right away.
  Only changes in this ios/ folder need a new .ipa.
- `bridge.js` gives the page `navigator.bluetooth`, backed by CoreBluetooth in `BLEBridge.swift`.
- When the app goes to the background, `BackgroundTracker.swift` takes over the Peak: it reads the state and
  the inhale sensor, times hits like the page does, and reconnects if the Peak sleeps. When you open the app
  again the page logs those sessions (`emberBgResume`) and they count for ranked.
- `KeepAlive.swift` plays silence (mixed with your music) so iOS doesn't freeze the app while it tracks.
- The firmware update service is never touched.

## Building
Every push that changes ios/ runs `.github/workflows/ios.yml` on GitHub (free for public repos) and puts a
new Emberline.ipa on the ios-latest release. The build log is on the `ios-log` branch.
