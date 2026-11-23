# Changelog

## In development — native design support

The approved iPhone design is now backed by native save-folder selection, full clipboard-history payloads and Copy actions, and a direct Files picker with transfer confirmation, progress, cancellation and retry. File activity and notifications retain their original folder references, so older files remain openable after changing the save folder. Clearing history has a confirmation and leaves documents untouched. Failed access to a chosen save folder falls back to Porthole's local folder with a visible message.

Foreground arrivals use one glass banner and an Activity unread badge, with ordinary iOS notifications in the background. Notification taps can reopen files after a cold launch or a cleared history. The connection layout fills the available height while retaining native Liquid Glass actions and scrolling for smaller layouts. Native provider/UI/device checks remain pending; the portable preference, history, and storage checks pass.

## 0.1.0

Mouse and keyboard settings now include persistent enable/disable and screen-sharing-only options. The matching PC build starts Bluetooth input only for screen sharing or explicit Bluetooth setup by default, and stops it when controls are disabled or the authenticated phone disconnects. File transfers and clipboard sync remain available independently. Control preferences show as applied only after PC acknowledgement.

Connection status rows open feature settings. Photo access supports permission management, selected-photo access and library refresh. Clipboard synchronization can be enabled or disabled for both directions, and the preference persists across launches. Mouse and keyboard setup reports detected devices and links to supported iOS pointer settings. App labels, permission prompts and transfer messages use consistent terminology.

The Connect tab uses the original Porthole logo. The share-screen control and live timer use a thinner porthole rim and a smaller cursor, with matching light and dark artwork.

The iPhone app now shares the PC app's version number. Buttons use Liquid Glass on iOS 26 and keep the frosted look on older iOS. Share › Porthole takes any file, not only photos and videos: PDFs, ZIPs, audio and documents from Files, Mail or any app. The sheet shows which PC gets them, offers Change when there are several, and ticks each file as the PC saves it. Activity lists the files and copies that moved each way today. Settings says where files land on each side. Needs the PC build from the same day.

## 2.16

Copy and paste go both ways while this app is connected. A copy on the PC becomes the iPhone clipboard, and you paste it with Ctrl+V. A copy on the iPhone becomes the PC clipboard when you open Porthole, or when you tap Send clipboard. Text keeps accents and emoji. One picture moves too. Needs the PC build from the same day. Set Settings → Apps → Porthole → Paste from Other Apps to Allow.

## 2.15

Share > Porthole says the items went to the PC's Downloads: the PC now saves shared items there straight away, and Ctrl+drag takes one item at a time. Includes 2.14's faster search.

## 2.14

Drags answer quickly again. 2.11's off-centre cuts scored thousands of photos seven times each on one core, so a drag waited 6 to 8 seconds. Now each photo is scored at the centre and where its quick hash sat, only the closest 40 at every cut, and the work runs on all of the phone's cores. The sharper copies for the closer look are read at the same time instead of one after another, and the video scan runs on all cores too. Each answer carries its timings for the PC's log.

## 2.13

Porthole has an icon: solid purple with the porthole ring. The PC looks for that colour in the Share sheet, so a Ctrl+drag on the PC can tap Share and then Porthole in Photos by itself, and Photos sends the exact originals of everything selected, even items scrolled off screen. The Share sheet closes sooner after sending.

## 2.12

Grid thumbnails are found far more often. The sharper confirmation also tries the picture zoomed in by 2% and 4%: the PC's thumbnail could sit a pixel or two inside the real one, and that small zoom alone cost the right photo most of its lead, so it was refused. Best with the PC build from the same day, which cuts the whole thumbnail and paints out Select mode's checkmark.

## 2.11

Fewer wrong files. A win that is not near-perfect is confirmed on sharper copies of the closest candidates, and refused when that look disagrees: a page of handwriting had been sent for a ticked screenshot. Photos does not always cut a grid thumbnail from the centre, so several cut positions are tried. The match's scores go to the PC with each file, for its log.

## 2.10

Videos are found from their library-grid thumbnails. A thumbnail is a square cut from the middle of the video, and the app used to skip every video of another shape; it now cuts each stored frame the same way. Works with the PC build from the same day, which reads the grid's cells exactly at any zoom.

## 2.9

Send several photos and videos at once. In Photos, tap Select, pick them, tap Share and choose Porthole. The app sends those files themselves, in their original format, to Porthole on the PC, which carries them all on the next Ctrl+drag out of its window. Nothing is matched, so items scrolled off screen, videos and iCloud items all work. Open the Porthole app on the iPhone once first, so the PC knows this phone. Needs the PC build from the same day.

## 2.8

The whole-screen comparison keeps every photo's small fitted copy between drags, so after the first drag it is only a comparison and a screen that is not in the library is refused quickly. Works with the same PC build as 2.6.

## 2.7

Answers sooner when the screen is not a photo or video from the library, such as the home screen: videos are decoded only when one is already close. Works with the same PC build as 2.6.

## 2.6

A photo or video whose edges cannot be seen is found too, such as a black screenshot on Photos' black page, or a white one in light mode. The PC also sends the whole phone screen, and the app places each library item on it the way Photos shows one item, fitted to the screen, so no edges are needed. Photos' bars and side buttons count less. Needs the PC build from the same day.

## 2.5

More photos and videos drag across. Needs the PC build from the same day, which also sends the picture at 64 x 64.

- Copies of one picture, such as a duplicate or a saved copy, no longer block each other. The largest file, the camera original, is sent.
- A near-perfect match is sent even when another photo is fairly close (0.962 against 0.894 used to be refused).
- Close calls, such as two shots of a burst, are decided on a sharper copy of each candidate.
- Photos' bars and a paused video's controls drawn over the picture count less.
- A video paused between the frames the app stored is found by decoding real frames around the closest moments of the best candidate videos.
- Choose original picks the exact item when nothing else can tell. The library is read again shortly after it changes.

## 2.4

Share screen stays tappable with Screen Mirroring off. iOS disables that system button while the app is playing the silence that keeps the photo link alive, and mirroring had been the thing that stopped the silence. The silence now plays only after you leave the app.

## 2.3

Share screen works with Screen Mirroring off. The broadcast was dropping the PC while Wi-Fi was still coming up, and that path is already up only when mirroring is on.

## 2.2

The shared screen stays closer to now. The encoder sends each frame immediately instead of holding pictures to smooth the bitrate, and the picture's long side is 1080, the same size AirPlay already uses, so the PC is not drawing a much larger window. Turn Screen Mirroring off while sharing.

## 2.1

Less lag while sharing the screen. Porthole on the PC now answers each frame, and the app skips a frame instead of queueing it while two are still unanswered, so a slow moment on Wi-Fi drops frames rather than building up delay. The stream is 5 Mbit/s instead of 8. Needs the PC build from the same day.

## 2.0

Share screen. A broadcast extension sends what the iPhone actually shows to Porthole over Wi-Fi, so Photos keeps its bars and share sheets, alerts and the info panel appear on the PC. Start it with the Share screen button in this app, or from Control Center (long-press Screen Recording, choose Porthole). Keep Screen Mirroring off while sharing, and keep the photo link connected: Porthole only accepts the screen from the phone it knows. Picture only for now; sound stays on the phone. The Xcode project is now generated from project.yml.

## 1.15

A refused drag tells the PC how many videos have been read so far, and how many were skipped because they are only in iCloud. A video the app could not read only matches near its start.

## 1.14

A playing video is accepted at a lower score when it still leads every other video by a clear margin. Frames are only 24 per video, so the right video can score well below a photo; two close videos are still refused.

## 1.13

A video can be dragged at any point while it plays. After the photos, the app reads up to 24 small frames from across each video stored on the phone, newest first, and keeps them in a file so each video is read only once. The status line shows how many videos are done; a video not yet read still matches near its start.

## 1.12

Videos can be dragged off the mirror too. They are matched by their preview frame, so drag a video near its start, and the original movie file is sent. Every file is streamed from disk, so a large video does not need to fit in memory. Screenshots already worked here; the PC no longer mistakes them for the live phone screen.

## 1.11

The app stays connected in the background after the audio route changes, such as when mirroring starts or Porthole on the PC restarts. iOS stopped the silent audio that keeps the app running, and suspended it a few seconds later.

## 1.10

The app reconnects by itself after Porthole on the PC restarts. A connect that was refused while the PC was down used to wait until the app was opened again.

## 1.9

Photos are indexed the right way up. Every photo had been stored upside down, so the picture on screen never matched its camera file and earlier near matches were other photos with a similar sky.

## 1.8

A refused drag sends back the app's small copy of its closest photo. The PC saves it beside its own copy, so a mismatch between the two can be seen.

## 1.7

Each library photo is indexed whole. A photo whose stored shape is sideways was cropped to its centre, so its detail never lined up with the picture on screen. A refused drag also reports the size the app compared, for the PC log.

## 1.6

Photos from a burst are told apart. The PC sends a small copy of the picture with each drag, and the app picks the library photo whose detail follows it, not only the one with the closest outline. Two shots that still look the same send nothing. This needs the Porthole PC build from the same day; an older PC is matched as in 1.5.

## 1.5

The closest camera photo is sent when it is near the picture on screen. A second photo that is only a little further away no longer blocks it.

## 1.4

Dragging a thumbnail, or a photo that fills the screen, asks for that camera file. Each library photo is compared in the shape it has on screen. A drag still does nothing until this app says Ready and Connected.

## 1.3

A photo that fills the mirror was still refused. The comparison now follows the picture from the top, allows the small shape difference of a photo fitted on screen, and accepts a near match.

## 1.2

The link stays up after you leave this app and open Photos, which is the screen the PC is mirroring. The address and code are remembered. Photos are indexed as they appear on screen, including ones stored sideways in the camera roll.

## 1.1

The app asks for Local Network as soon as it opens. Connect no longer waits for the photo index. An address copied from F1 help, including the port and the code, is accepted.

## 1.0

Open the app, load photos, enter the PC address and the code from Porthole's F1 help, and leave the app open. Dragging a fullscreen photo off the Porthole window then takes that original file.
