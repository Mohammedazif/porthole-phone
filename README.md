# Porthole phone

Porthole connects an iPhone to one verified PC for screen sharing, clipboard sync, and file transfers. On iOS 26, it uses native Liquid Glass controls and tabs. Earlier supported versions use the frosted controls. The minimum version is iOS 17.

## Connect and share

1. Open a matching Porthole build on your PC and connect both devices to the same Wi-Fi network.
2. On the iPhone, scan the secure QR from Porthole on the PC. You can also choose **Connect manually** and enter the PC address, eight-character code, and SHA-256 certificate fingerprint shown on the PC. **Find nearby PCs** helps locate addresses when Local Network access is available.
3. Once the PC is verified, use the broadcast button in **Share screen** and select **Start Broadcast** in the iOS picker. The PC can see the screen and visible notifications while sharing. Audio stays on the iPhone. Use **Stop delivery** to stop sending the screen to the PC. End the broadcast using the active Screen Recording control in Control Center.

Pairing and transport use the pinned PC certificate over TLS 1.3. The companion, screen, and file inbox ports are 47731, 47732, and 47733. The screen and inbox channels require tickets from the currently authenticated companion session. Use the desktop build that implements the [secure companion contract](SECURE-COMPANION.md).

The optional name in **Settings → Phone name** appears on the paired PC. The default is `iPhone`. Pair the PC in iPhone Bluetooth settings, then open **Settings → Mouse and keyboard → Verify Bluetooth** in Porthole. Keep the verification screen open until it confirms the connection. Mouse and keyboard are limited to screen sharing by default. You can change when controls activate or disable them in **Mouse and keyboard**. If the PC or Bluetooth connection changes, verify again.

## Files and photos

- **Receive files.** Connect shows the current file, progress, and any interruption. Porthole saves incoming files of up to 512 MiB in its local folder by default. To choose a Files provider or another folder, open **Settings → File storage → Choose another folder**. Porthole reports any fallback to its local folder. Each received item keeps its own folder reference so older files can still be opened after a destination change. Clearing Received or Sent history removes the selected activity records. Received documents stay in their saved folders.
- **Open or save a copy.** Open an item from Activity or its arrival banner to view the available Quick Look preview, export a copy to Files, or share it. Supported photo and video items can also be saved to Photos.
- **Send files.** Use **Send files** in the app or Share → Porthole from another app. Review the verified PC and outgoing filenames before sending. A batch can include up to 500 non-empty files, at most 512 MiB per file and 32 GiB in total, subject to free space. A file counts as sent after the PC confirms its durable save. Retry from **Pending file transfer** in Connect, or select the same unchanged file again for the same PC while the pending transfer is still available. Porthole reuses the transfer identity and can recover a save that completed before the connection dropped.
- **Transfer a Photos original.** Grant access in **Settings → Photo access**, then use the PC's drag-from-Photos feature or choose **Select original** for the next request. Porthole asks you to confirm a matched original before sending it. The transfer sends the unedited original, including its metadata, up to 512 MiB. Share → Porthole also lets you review the files supplied by another app.

With Porthole open, received files show an in-app banner and an Activity badge. Use **Settings → Notifications → Enable file notifications** to request iOS permission for background alerts. When iOS delivers an alert, tapping it can reopen the saved file after a relaunch or a cleared Activity history. Companion operations depend on iOS scheduling in the background. Open Porthole to reconnect or continue a waiting transfer.

## Clipboard

Manage clipboard sync in **Settings → Clipboard sync**. The paired PC must acknowledge the current setting before transfers start. Clipboard updates run while the iPhone companion is in the foreground. **Send clipboard** and the system **Paste** button let you send content explicitly. iOS may ask for paste permission. Porthole writes received or copied clipboard content to the local iPhone pasteboard using `localOnly`.

**Keep clipboard history** is a separate opt-in, available in **Activity → Clipboard** and **Settings → Clipboard sync**. Shared text and images can stay on the iPhone for up to seven days, with a limit of 16 MiB and 100 items. Turning the setting off removes saved clipboard content. While items are available, use **Copy** to place an item on the iPhone pasteboard, including while disconnected. Sending a saved item is a separate **Send to PC** action. Older summary-only records may lack a full payload.

## Home Screen and Lock Screen widgets

Add **Porthole** from the iPhone widget gallery. The small Home Screen widget shows your unread received files or the next action. The medium widget adds **Share screen**, **Send files**, and **Clipboard**. The Lock Screen supports inline, circular, and rectangular widgets.

Unread counts increase after the phone saves an incoming file. Opening **Received** marks all received items as read. Opening a file from its alert or arrival banner marks that file as read. Clearing Received activity updates the count and keeps the saved documents. The widgets display the most recent snapshot iOS has refreshed. Tap to see transfer progress in Porthole. Share screen opens the usual system confirmation, and Send files opens the picker after a PC is verified. [WidgetKit refresh behavior](https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date/)

Use **Settings → Widgets → Hide Lock Screen details** to hide widget counts and pairing status on the Lock Screen and keep new file notification previews generic. Widget state contains aggregate counts and status. File names, clipboard content, and pairing credentials stay in their existing stores.

## Build and install

The **iPhone app** GitHub workflow uses macOS 26 and Xcode 26.5 to build the app and all three extensions. Pull requests, branch pushes, and manual runs with the default options produce an unsigned `.ipa` in the run's **Artifacts** for seven days. A pushed `v` tag can publish the built IPA to that release after the workflow verifies the tag's commit. To publish a preview explicitly, select **Publish an unsigned preview release for this build** when starting the workflow. Each preview uses its own tag at the exact built commit. Existing release assets are kept. [GitHub macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md)

On a Mac, install XcodeGen, run `xcodegen generate`, and open `PortholePull.xcodeproj`. The base app identifier is `local.porthole.pull`. The embedded extensions use the app's identifier followed by `.broadcast`, `.share`, and `.widgets`.

For a device install, enable signing for all four targets and use the same team. Register two distinct App Groups. Set `PORTHOLE_APP_GROUP` to the companion group on the app, Broadcast, and Share. Set `PORTHOLE_WIDGET_APP_GROUP` to the widget group on the app and Widgets. Include the corresponding groups in each provisioning profile. Use a signing method that preserves these entitlements and the embedded extensions. Development installs may also require Developer Mode on the iPhone. [Apple App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups), [Apple Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

Run `bash scripts/test-settings.sh` with Swift for the portable checks. A signed device install and end-to-end checks against the matching PC build are required before distribution. See the [native validation checklist](NATIVE-VALIDATION.md).

The desktop project is [Porthole](https://github.com/Mohammedazif/porthole). This app is GPL-3.0.
