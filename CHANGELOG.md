# Changelog

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
