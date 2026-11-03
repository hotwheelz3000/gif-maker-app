# GIF Maker

An iPhone app that turns videos into GIFs. Built with [xtool](https://xtool.sh) from the my-ios-app template.

## Features

- Choose a video from Photos, or record one with the camera
- Trim with a thumbnail timeline (clips up to 15 seconds)
- Crop to Original, 1:1, 3:2, 16:9, 4:5 or 9:16; drag to move, pinch to zoom
- Loop style: Normal, Reverse or Boomerang
- Speed: 0.5x, 1x, 1.5x or 2x
- Width 320, 480 or 720 (default 720); 10, 14, 15 or 24 fps (default 14)
- Save to Photos, share, or copy the GIF

Everything runs on the phone. There's no server and no account.

## Download

Every push to `main` builds an unsigned IPA and publishes it on the **Releases** page as `GIFMaker-<date>.ipa`. Sign it when installing (Signulous, Sideloadly, AltStore or `xtool install`).
