# Changelog

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
