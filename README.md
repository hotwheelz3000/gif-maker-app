# GIF Maker

An iPhone app that turns videos into GIFs, and edits GIFs. Built with [xtool](https://xtool.sh) from the my-ios-app template, so no Mac or Xcode is needed: GitHub Actions builds the IPA.

## Features

**Choose a Video** or **Choose a GIF** from Photos. Everything runs on the phone. There's no server and no account.

**Editing a GIF** uses the same tools. Its frames are read straight from the file (no video step), so nothing is lost and transparency stays. The whole GIF (up to 15 seconds) starts selected, and Size and Frame rate start on **Original**: the GIF's own size, frames and timing (including frames that last longer than others). Picking something that isn't a GIF says so.

The editor has a big preview on top and four tools along the bottom (Trim, Crop, Loop, Quality). **Next** in the top-right corner makes the GIF.

**Trim**
- Thumbnail strip with yellow start and end handles. A clip can be 0.3 to 15 seconds long; a new video starts with its first 5 seconds selected.
- On videos longer than 30 seconds the strip zooms in to 30 seconds around the selection, with a thin line underneath showing where you are in the whole video.
- Drag a handle, or drag inside the selection to slide it. A bubble above shows the length, or the handle's time while dragging. A light tap of haptics when the clip hits its shortest or longest length.
- **Start** and **End** + / − buttons move a handle by 0.1 seconds; hold one down to keep going.

**Crop**
- Original, 1:1, 3:2, 16:9, 4:5 or 9:16.
- Drag the preview to move the crop and pinch to zoom, or use the **Zoom** (− / + / Reset) and **Move** (arrow) buttons. Arrows grey out when there's nowhere to move.
- Centering guides show while you adjust the crop: an up-and-down and a side-to-side line through the middle, black, turning yellow when the crop is centered that way. Dragging near center snaps onto it with a light haptic tap.

**Loop**
- Loop style: Normal, Reverse or Boomerang. Reverse and Boomerang previews are prepared ahead of time (a "Preparing preview…" label shows for a moment), so they play smoothly and match the GIF.
- Speed: 0.5x, 1x, 1.5x or 2x.

**Quality**
- Width 320, 480 or 720 pixels (default 720) and 10, 14, 15 or 24 frames per second (default 15), each with a short explanation. GIFs also get **Original** for both (the default for GIFs). The output size and frame count are shown underneath.

**Your GIF**
- The GIF plays on a loop, with its loop style, size, frame count and file size.
- Save to Photos, Share, or Copy.
- Every GIF is 5 MB or under: if one comes out bigger, it keeps being made smaller until it fits (first a smaller size, then below 320 wide every other frame is dropped, keeping the speed; with only a couple of frames left it goes below 320 too), and the screen says so.

**Accessibility** (the same standard as Soulection Radio)
- 44-point tap targets, VoiceOver labels everywhere, and VoiceOver hears the current tool's name at the top.
- Trim handles and the selection are adjustable with VoiceOver (swipe up or down).
- A tap alternative for every drag or pinch.
- Reduce Motion turns off the trim bubble's animation.

**Also**
- Swipe-back is off; use the ‹ button at the top left to go back.
- Copied videos and made GIFs are kept in the app's temporary folder and cleared each time the app starts (save or share a GIF to keep it).
- The Home screen shows the version ("Version 1.1").

## Download

Every push to `main` builds an unsigned IPA and publishes it as the **latest** release, titled with the version ("GIF Maker 1.1"), with the IPA named `GIFMaker-<version>.ipa` and the release notes taken from `RELEASE_NOTES.md`. Sign it when installing (Signulous, Sideloadly, AltStore or `xtool install`).

The version is `CFBundleShortVersionString` in `GIFMaker-Info.plist`.

## Project

- `Sources/GIFMaker/`: the app (SwiftUI). `EditorModel.swift` holds the editor's state and playback, `GIFExporter.swift` makes the GIF, `TrimBar.swift` the trim strip, `GIFSource.swift` reads GIFs for editing.
- `.github/workflows/build-ipa.yml`: builds the IPA with xtool and publishes the release.
- `.claude/skills/`: `using-xtool`, plus the `fresh-eyes-review` and `documentation-audit` review skills from Soulection Radio (versions recorded in `skills-lock.json`).
