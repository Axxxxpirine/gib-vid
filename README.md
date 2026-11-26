# Gib Vid

<img src="GibVid/Resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="96" height="96" alt="Gib Vid icon showing a folded film frame">

Copy a video link and save the video to Photos on your iPhone. Gib Vid downloads the audio and video tracks directly from the source and combines them on your device. You don’t need a Gib Vid account or a separate server.

## Install on your iPhone

You’ll need a Mac with Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and Python 3.10 or later with pip, plus an iPhone running iOS 18 or later. The setup script downloads the Python runtime from GitHub and the Python packages from PyPI.

1. Clone or download the repository and open a terminal in the project directory. If you use Homebrew, you can install XcodeGen with `brew install xcodegen`.
2. Download the dependencies, generate the Xcode project, and open it.

   ```sh
   ./scripts/fetch_deps.sh
   xcodegen generate
   open GibVid.xcodeproj
   ```

3. In Xcode, select the **GibVid** target and open **Signing & Capabilities**. Choose your Apple development team under **Team** and replace `org.example.GibVid` with a unique **Bundle Identifier**. If the team list is empty, add your Apple Account in Xcode settings.
4. Connect your iPhone, select it as the run destination, and press **⌘R**. Enable Developer Mode on your iPhone if Xcode prompts you.

To keep your signing settings when you run `xcodegen generate` again, set your bundle identifier and development team in your local copy of [project.yml](project.yml).

## Save a video

1. Copy the link to a video you have permission to download.
2. Open Gib Vid and tap the large download button. The first time you download a video, allow Gib Vid to add it to Photos.
3. Once the download finishes, open Photos to find your video.

In Shortcuts, use the **Open URLs** action with `gibvid://` to download the link on your clipboard. To pass a link directly, use `gibvid://?url=<percent-encoded URL>`.

Gib Vid also saves GIFs from X (formerly Twitter), including from share links that end in `/video/1`. Each GIF appears in Photos as a short video without sound.

Which videos you can save depends on the sites yt-dlp supports and the media formats Photos can import. Gib Vid doesn’t support live streams, photo-only posts, or videos that require you to sign in.

## Build for the simulator

Install an iOS Simulator runtime in Xcode, then run these commands from the root of a fresh checkout. The simulator build uses local code signing.

```sh
./scripts/fetch_deps.sh
xcodegen generate
xcodebuild -project GibVid.xcodeproj -scheme GibVid -configuration Debug \
  -destination 'generic/platform=iOS Simulator' build
```

## How it works

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) extracts video links using [Python for iOS](https://github.com/beeware/Python-Apple-support). A [C bridge](GibVid/Bridge/GibBridge.c) connects the Swift app to the [Python engine](python/app/gibvid.py).
- The [JavaScript provider for yt-dlp](python/app/gibvid_jsc.py) runs scripts on the iPhone using JavaScriptCore.
- For X share links that point to a GIF, yt-dlp reports that the media isn’t a video. The [Python engine](python/app/gibvid.py) then tries the post again without the media number.
- Gib Vid can [convert fragmented MP4s into regular MP4s](python/app/gibvid_mp4.py) and [combine separate audio and video tracks](GibVid/Media/VideoAssembler.swift) using AVFoundation.
- Each build includes [pinned Python packages](scripts/requirements-ios.txt). On launch, the app checks PyPI for a yt-dlp update if more than 12 hours have passed since the last check. It verifies the SHA-256 hash of each package it downloads. Tap the version number to check for updates manually.

## License

The Gib Vid source code and app icon are available under the [MIT License](LICENSE). Python, yt-dlp, yt-dlp-ejs, certifi, and their components retain their respective licenses.
