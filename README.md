# Porthole phone

The iPhone side of Porthole. Dragging a fullscreen photo off the Porthole window on the PC takes that photo's original file.

The PC listens on TCP port 47731. F1 help on the PC shows the address and the 8-character code. In the app, enter both and tap Connect. Wait until it says Ready and Connected, then open Photos.

Copy and paste use the same connection. Copy on the PC, then paste on the iPhone with Ctrl+V. Copy on the iPhone, open this app, and paste on the PC. Set Settings → Apps → Porthole → Paste from Other Apps to Allow. The app keeps the link in the background, so the mirror can show the photo while the original is sent. You can let go of the drag; the PC waits for the file. Drop it on a folder. The file keeps the camera's name and format.

Bundle id `local.porthole.pull`. The home screen name is Porthole.

## Build

An iPhone app is built on a Mac, so GitHub builds it: **Actions → iPhone app → Run workflow**. The build is unsigned. A build started by hand replaces the `.ipa` on the `ios-latest` pre-release. Pushing a tag such as `v1.0` makes that version's release.

## Install

Without a paid Apple Developer account, install it with your own Apple ID:

1. On a Windows PC or a Mac, install **Sideloadly** (or AltStore). On Windows, take iTunes from apple.com, not the Microsoft Store.
2. Plug the iPhone in, open the `.ipa` in Sideloadly, and sign in with an Apple ID. A spare one is better than your main one.
3. On the iPhone, turn on Settings → Privacy & Security → **Developer Mode**, and trust the Apple ID under Settings → General → VPN & Device Management.
4. When the app first connects, allow it to find devices on the local network, and allow photo access.

An app signed with a free Apple ID stops opening after 7 days until it is signed again, and one Apple ID can keep 3 such apps.

The PC program is [porthole](https://github.com/Mohammedazif/porthole). This app is GPL-3.0, the same license as that program.
