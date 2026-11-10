# Gym Pass (iPhone app)

Your gym membership barcode, ready when you walk in. Scan your gym card once. When you arrive at the gym,
your iPhone shows a notification. Tap it and the barcode opens full screen at full brightness.

## Install with Sideloadly (free)
1. Download **GymPass.ipa**: https://github.com/taupespy-debug/test/releases/download/gym-latest/GymPass.ipa
2. Open Sideloadly on your computer, plug in your iPhone, drag the .ipa in, sign in with your Apple ID, hit Start.
3. On the iPhone: Settings > General > VPN & Device Management > your Apple ID > Trust.
4. If you haven't already: Settings > Privacy & Security > Developer Mode > On.

A free Apple ID signs apps for 7 days. Turn on Sideloadly's auto-refresh, or install it again when it stops opening.
Free Apple IDs can have 3 sideloaded apps at once.

## Set it up
1. Open Gym Pass. Tap **Scan it with the camera**, or **Choose a photo or screenshot** of your barcode.
   Scanning picks the right barcode type automatically.
2. Add the gym's name and pick a card color. Save.
3. Under **Arrival alert**, tap **Search for the gym**, or **I'm at the gym now, use this spot** when you're there.
4. When iOS asks, allow notifications, and set Location to **Always**
   (Settings > Apps > Gym Pass > Location > Always, with Precise Location on).
5. Tap **Send a test notification** to see what it looks like.

Extras: press and hold the arrival notification to see the barcode right in it. Say
"Show my gym barcode in Gym Pass" to Siri, or set the Action button to the Gym Pass shortcut.

## Building
Every push that changes gym/ runs `.github/workflows/gym.yml` on GitHub's Macs and puts a new GymPass.ipa
on the gym-latest release. The build log is on the `gym-log` branch.
